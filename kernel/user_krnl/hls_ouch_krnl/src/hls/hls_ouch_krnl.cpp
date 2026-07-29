/************************************************
OUCH gateway kernel.

СТРОИТСЯ ПОЭТАПНО. Сейчас реализован ШАГ 1 и только он:

    ШАГ 1: открыть listen-порт для входящих подключений.

Всё остальное — приём данных, upstream-соединение к бирже,
реассемблер SoupBinTCP, разбор OUCH — будет добавляться отдельными
шагами. Пока эти интерфейсы объявлены (иначе сборка hw не пройдёт:
стек требует, чтобы все его порты были подключены), но заглушены
через tie_off_*.

ПОЧЕМУ ВСЕ ПОРТЫ СРАЗУ. Набор портов ядра и файл config_sp жёстко
связаны: config_sp перечисляет соединения ядра со network_krnl. Если
объявлять порты по мере надобности, то каждый шаг требовал бы правки
и config_sp, и Makefile. Объявив полный набор один раз, дальше
меняется только логика внутри ядра.

Идиомы взяты из hls_gateway_krnl.cpp, где они уже проверены синтезом
(II=1 на всех стадиях, Fmax ~250 МГц):
  - топ-функция вызывает ouch_core, помеченный DATAFLOW;
  - каждая стадия — отдельная функция с PIPELINE II=1 и INLINE off;
  - состояние в static-переменных, RESET на переменных состояния;
  - в каждый выходной AXI-Stream порт пишет РОВНО ОДНА функция.

DATAFLOW, а не PIPELINE на топе: обратные связи между стадиями в
одном конвейере становятся carried dependence и растягивают II.

ПРОВЕРЯЕТСЯ csim + csynth. Co-simulation здесь СОЗНАТЕЛЬНО НЕ
используется, и обёртки под неё нет: этот дизайн для cosim непригоден
по построению. Cosim подаёт входы, ждёт ЗАВЕРШЕНИЯ транзакции и
сравнивает выходы, а ap_ctrl_none-ядро из бесконечных стадий не
завершается никогда. Сам Vitis это и сообщает:
  [HLS 200-656] Deadlocks can occur since process ... is instantiated
  in a dataflow region with ap_ctrl_none ... and contains an
  auto-rewind pipeline
Плюс тестбенч устроен как «вызов ядра на один такт» — в RTL такого
понятия нет вообще.

СЛЕДСТВИЕ, О КОТОРОМ НАДО ПОМНИТЬ: в csim hls::stream неограничен,
блокирующая запись никогда не блокируется, а прагмы depth игнорируются,
поэтому проверки full() в csim НЕ проявляются (UG1448, Data FIFO
Sizing). Когда появятся FIFO между стадиями, достаточность их глубин
надо проверять либо ограниченными потоками в тестбенче, либо
телеметрией на плате — но не cosim'ом.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

/*
 * ШАГ 1: открывает listen-порт для входящих подключений клиента.
 *
 * Пишет номер порта в m_axis_tcp_listen_port и ждёт подтверждения в
 * s_axis_tcp_port_status. Если стек ответил неуспехом — пробует снова.
 *
 * Порт остаётся открытым и после отключения клиента, поэтому повторное
 * подключение принимается стеком автоматически, без участия ядра.
 *
 * Состояние держится в static-переменных, потому что ядро объявлено с
 * ap_ctrl_none: оно вызывается заново на каждом такте, и «прогресс»
 * между вызовами хранить больше негде.
 *
 * ПРО enable. Из-за ap_ctrl_none у ядра нет ap_start — оно исполняет
 * своё тело каждый такт. С какого момента, зависит от того, держит ли
 * XRT ядро в reset до enqueueTask; из кода это не видно, и НА ПЛАТЕ НЕ
 * ПРОВЕРЕНО. Если работа начинается сразу с загрузки битстрима, то
 * возникает гонка:
 *   1) битстрим загружен, listenPort в регистре ещё 0;
 *   2) ядро запрашивает порт 0 и ставит portRequested = true;
 *   3) хост пишет настоящий порт (миллионы тактов позже) — но запрос
 *      уже отправлен, и повторного не будет.
 * Слушался бы порт 0, а клиент не смог бы подключиться. enqueueTask от
 * этого не спасает: при ap_ctrl_none он лишь фиксирует аргументы.
 *
 * Вместо того чтобы выяснять, есть гонка или нет, ядро просто не делает
 * НИЧЕГО, пока хост не выставит enable=1 — это верно при любом ответе.
 * Порядок записи на хосте: сначала все параметры, потом enable.
 *
 * Побочная польза: enable даёт управляемый старт и остановку без
 * перепрошивки карты.
 *
 * Почему отдельный аргумент, а не проверка listenPort != 0: для порта
 * ноль действительно невозможен, но у будущих параметров (адреса,
 * флаги, счётчики) ноль — вполне легальное значение. Один явный «пуск»
 * надёжнее, чем выдумывать невозможное значение для каждого.
 */
void ouch_listen(int enable,
                 int listenPort,
                 hls::stream<pkt16>& m_axis_tcp_listen_port,
                 hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portRequested = false;
#pragma HLS RESET variable=portRequested
     static bool portOpened = false;
#pragma HLS RESET variable=portOpened

     // До разрешения хоста не трогаем ни один порт: параметры в
     // регистрах ещё могут быть не записаны.
     if (!enable)
          return;

     if (!portRequested)
     {
          pkt16 listen_port_pkt;
          listen_port_pkt.data = 0;
          listen_port_pkt.data(15, 0) = listenPort;
          m_axis_tcp_listen_port.write(listen_port_pkt);
          portRequested = true;
     }
     else if (!portOpened && !s_axis_tcp_port_status.empty())
     {
          pkt8 status_pkt = s_axis_tcp_port_status.read();
          bool success = status_pkt.data(0, 0);
          if (success)
          {
               portOpened = true;
          }
          else
          {
               // не открылось — просим снова на следующем такте
               portRequested = false;
          }
     }
}

/*
 * Тело ядра: стадии и внутренние FIFO.
 *
 * Отделено от топ-функции, потому что DATAFLOW и объявление интерфейса
 * не сочетаются в одной функции: топ описывает порты, ouch_core —
 * структуру вычисления.
 */
void ouch_core(int enable,
               int listenPort,
               hls::stream<pkt512>& s_axis_udp_rx,
               hls::stream<pkt512>& m_axis_udp_tx,
               hls::stream<pkt256>& s_axis_udp_rx_meta,
               hls::stream<pkt256>& m_axis_udp_tx_meta,
               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status,
               hls::stream<pkt64>& m_axis_tcp_open_connection,
               hls::stream<pkt128>& s_axis_tcp_open_status,
               hls::stream<pkt16>& m_axis_tcp_close_connection,
               hls::stream<pkt128>& s_axis_tcp_notification,
               hls::stream<pkt32>& m_axis_tcp_read_pkg,
               hls::stream<pkt16>& s_axis_tcp_rx_meta,
               hls::stream<pkt512>& s_axis_tcp_rx_data,
               hls::stream<pkt32>& m_axis_tcp_tx_meta,
               hls::stream<pkt512>& m_axis_tcp_tx_data,
               hls::stream<pkt64>& s_axis_tcp_tx_status)
{
// INLINE здесь ставить НЕЛЬЗЯ — HLS 214-272: "INLINE and DATAFLOW on
// same function is allowed only for inlining into an outer dataflow
// function". Топ-функции сами не dataflow-регионы, они лишь вызывают
// ouch_core, поэтому ouch_core остаётся отдельной dataflow-функцией.
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     // ---- Стадии ----

     // ШАГ 1: слушаем порт
     ouch_listen(enable, listenPort,
                 m_axis_tcp_listen_port, s_axis_tcp_port_status);

     // ---- Пока не реализованные интерфейсы ----
     // Заглушки обязательны: неподключённый порт стека ломает сборку hw.
     // По мере добавления шагов соответствующие tie_off_* будут
     // заменяться на настоящие стадии.
     tie_off_udp(s_axis_udp_rx, m_axis_udp_tx,
                 s_axis_udp_rx_meta, m_axis_udp_tx_meta);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection,
                                 s_axis_tcp_open_status);
     tie_off_tcp_close_con(m_axis_tcp_close_connection);
     tie_off_tcp_rx(s_axis_tcp_notification, m_axis_tcp_read_pkg,
                    s_axis_tcp_rx_meta, s_axis_tcp_rx_data);
     tie_off_tcp_tx(m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                    s_axis_tcp_tx_status);
}

extern "C" {
void hls_ouch_krnl(
               // UDP (не используется, но интерфейс обязателен)
               hls::stream<pkt512>& s_axis_udp_rx,
               hls::stream<pkt512>& m_axis_udp_tx,
               hls::stream<pkt256>& s_axis_udp_rx_meta,
               hls::stream<pkt256>& m_axis_udp_tx_meta,

               // TCP control
               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status,
               hls::stream<pkt64>& m_axis_tcp_open_connection,
               hls::stream<pkt128>& s_axis_tcp_open_status,
               hls::stream<pkt16>& m_axis_tcp_close_connection,

               // TCP rx
               hls::stream<pkt128>& s_axis_tcp_notification,
               hls::stream<pkt32>& m_axis_tcp_read_pkg,
               hls::stream<pkt16>& s_axis_tcp_rx_meta,
               hls::stream<pkt512>& s_axis_tcp_rx_data,

               // TCP tx
               hls::stream<pkt32>& m_axis_tcp_tx_meta,
               hls::stream<pkt512>& m_axis_tcp_tx_data,
               hls::stream<pkt64>& s_axis_tcp_tx_status,

               // ---- Скалярные аргументы (задаются с хоста) ----
               //
               // ПОРЯДОК ВАЖЕН. Хост задаёт их через setArg(<индекс>, ...),
               // где индекс — позиция аргумента в ЭТОЙ сигнатуре, считая
               // с нуля и включая все 16 потоков. То есть listenPort —
               // это индекс 16, enable — 17.
               //
               // Отсюда правило: новые параметры добавлять ТОЛЬКО между
               // listenPort и enable, никогда в середину потоков и никогда
               // после enable. Тогда сдвигается лишь индекс enable,
               // который на хосте считается автоматически (см. host.cpp:
               // ARG_ENABLE вычисляется от числа параметров).
               // Вставка в середину молча сместит все последующие индексы,
               // и ядро получит значения не в те регистры.
               int listenPort,         // порт, который слушаем

               // enable ВСЕГДА ПОСЛЕДНИЙ. Хост пишет его после всех
               // остальных параметров, и это разрешение начать работу
               // (см. пояснение у ouch_listen про гонку с ap_ctrl_none).
               int enable
                      ) {

#pragma HLS INTERFACE axis port = s_axis_udp_rx
#pragma HLS INTERFACE axis port = m_axis_udp_tx
#pragma HLS INTERFACE axis port = s_axis_udp_rx_meta
#pragma HLS INTERFACE axis port = m_axis_udp_tx_meta
#pragma HLS INTERFACE axis port = m_axis_tcp_listen_port
#pragma HLS INTERFACE axis port = s_axis_tcp_port_status
#pragma HLS INTERFACE axis port = m_axis_tcp_open_connection
#pragma HLS INTERFACE axis port = s_axis_tcp_open_status
#pragma HLS INTERFACE axis port = m_axis_tcp_close_connection
#pragma HLS INTERFACE axis port = s_axis_tcp_notification
#pragma HLS INTERFACE axis port = m_axis_tcp_read_pkg
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_meta
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_data
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_meta
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_data
#pragma HLS INTERFACE axis port = s_axis_tcp_tx_status
#pragma HLS INTERFACE s_axilite port=listenPort bundle = control
#pragma HLS INTERFACE s_axilite port=enable bundle = control
#pragma HLS INTERFACE ap_ctrl_none port = return

// Вся логика — в ouch_core. Здесь только интерфейс.
     ouch_core(enable, listenPort,
               s_axis_udp_rx, m_axis_udp_tx,
               s_axis_udp_rx_meta, m_axis_udp_tx_meta,
               m_axis_tcp_listen_port, s_axis_tcp_port_status,
               m_axis_tcp_open_connection, s_axis_tcp_open_status,
               m_axis_tcp_close_connection,
               s_axis_tcp_notification, m_axis_tcp_read_pkg,
               s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
               m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
               s_axis_tcp_tx_status);
}
}
