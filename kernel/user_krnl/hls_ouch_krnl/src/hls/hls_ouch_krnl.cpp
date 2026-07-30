/************************************************
OUCH gateway kernel.

СТРОИТСЯ ПОЭТАПНО. Сейчас реализованы шаги 1 и 2:

    ШАГ 1: открыть listen-порт для входящих подключений.
    ШАГ 2: принимать данные от клиента и ВЫБРАСЫВАТЬ их, считая
           байты и порции (ouch_rx_notify + ouch_rx_drain).

Шаг 2 ничего не разбирает — он только надёжно поглощает поток, не
теряя границ порций. Это основа будущего реассемблера SoupBinTCP, и
первый шаг, который можно проверить на плате: клиент подключается,
отправляет данные, счётчики через AXI-lite растут.

Всё остальное — upstream-соединение к бирже, реассемблер SoupBinTCP,
разбор OUCH, передача — будет добавляться отдельными шагами. Пока эти
интерфейсы объявлены (иначе сборка hw не пройдёт: стек требует, чтобы
все его порты были подключены), но заглушены через tie_off_*.

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
 * ШАГ 2а: приём уведомлений от стека.
 *
 * Стек сообщает о событиях в сессиях через s_axis_tcp_notification:
 *   - length != 0  -> пришли данные, надо запросить их read-request'ом;
 *   - closed == 1  -> сессия закрыта.
 * Одно уведомление может нести и то и другое сразу (rx_engine.cpp
 * формирует appNotification(..., length, ..., true) при FIN с данными),
 * поэтому это не else-if.
 *
 * Выставив read request, стадия сообщает следующей (sessionID, length)
 * через FIFO — та вычитает сами слова.
 *
 * ПОЧЕМУ ДВЕ СТАДИИ, А НЕ ОДНА. Пока идёт длинная передача, уведомления
 * копятся: шина rx_data одна, и следующая порция не начнётся, пока не
 * вычитаны все слова текущей. Если совместить приём уведомлений с
 * чтением данных в одной стадии, то на время передачи она перестанет
 * обслуживать notification, и стек упрётся в backpressure.
 *
 * ПРО full(). Запись в FIFO блокирующая: если он полон, стадия встанет
 * на write, перестанет читать notification — и приедет дедлок. Поэтому
 * уведомление ЗАБИРАЕТСЯ из входного потока только когда оба выходных
 * FIFO готовы принять запись. Иначе оно остаётся в потоке до следующего
 * такта: стек применит backpressure, но ядро не встанет.
 *
 * ВНИМАНИЕ: в csim этот guard бесполезен — там hls::stream неограничен
 * и full() всегда false (UG1448, Data FIFO Sizing). Проверить его можно
 * только ограниченными потоками в тестбенче или на плате.
 */
void ouch_rx_notify(hls::stream<pkt128>& s_axis_tcp_notification,
                    hls::stream<pkt32>& m_axis_tcp_read_pkg,
                    hls::stream<ap_uint<16> >& rxSessionFifo,
                    hls::stream<ap_uint<16> >& rxLengthFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     if (s_axis_tcp_notification.empty())
          return;

     // Не забираем уведомление, пока не ясно, что его можно обработать
     // без блокировки.
     if (rxSessionFifo.full() || rxLengthFifo.full())
          return;

     pkt128 notification_pkt = s_axis_tcp_notification.read();
     ap_uint<16> sessionID = notification_pkt.data(15, 0);
     ap_uint<16> length    = notification_pkt.data(31, 16);

     // closed (бит 80) на этом шаге не обрабатывается: пока сессия
     // никак не запоминается, реагировать на её закрытие нечем.
     // Появится вместе с таблицей сессий.

     if (length != 0)
     {
          pkt32 readRequest_pkt;
          readRequest_pkt.data = 0;
          readRequest_pkt.data(15, 0)  = sessionID;
          readRequest_pkt.data(31, 16) = length;
          m_axis_tcp_read_pkg.write(readRequest_pkt);

          rxSessionFifo.write(sessionID);
          rxLengthFifo.write(length);
     }
}

/*
 * ШАГ 2б: вычитывает пришедшие данные и ВЫБРАСЫВАЕТ их, считая байты.
 *
 * На этом шаге ядро ещё ничего не разбирает — задача только в том,
 * чтобы надёжно поглощать поток, не теряя границ порций. Это основа
 * будущего реассемблера SoupBinTCP.
 *
 * ВЫБРАСЫВАТЬ ОБЯЗАТЕЛЬНО, а не игнорировать: если запросить данные
 * read-request'ом и не вычитать их из rx_data, шина заполнится и стек
 * встанет. Поэтому «слив» — это не заглушка, а полноценная работа.
 *
 * Машина состояний из двух состояний, и выйти из FORWARD на полпути
 * НЕЛЬЗЯ: слова одной порции идут непрерывно до last, и если начать
 * читать следующую порцию, границы сместятся.
 */
void ouch_rx_drain(hls::stream<pkt16>& s_axis_tcp_rx_meta,
                   hls::stream<pkt512>& s_axis_tcp_rx_data,
                   hls::stream<ap_uint<16> >& rxSessionFifo,
                   hls::stream<ap_uint<16> >& rxLengthFifo,
                   ap_uint<64>& rxByteCount,
                   ap_uint<32>& rxPacketCount)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum drainStateType {IDLE, FORWARD};
     static drainStateType drainState = IDLE;
#pragma HLS RESET variable=drainState

     // Счётчики — наблюдаемость на плате. Без них шаг невозможно
     // проверить иначе как «не зависло».
     static ap_uint<64> byteCount = 0;
#pragma HLS RESET variable=byteCount
     static ap_uint<32> packetCount = 0;
#pragma HLS RESET variable=packetCount

     // Длина текущей порции, обещанная уведомлением
     static ap_uint<16> currentLength = 0;

     switch (drainState)
     {
     case IDLE:
          // Ждём и уведомление (через FIFO), и метаданные от стека.
          // rx_meta приходит на каждую порцию и содержит sessionID; на
          // этом шаге он не нужен, но вычитать его обязательно, иначе
          // поток забьётся.
          if (!rxSessionFifo.empty() && !rxLengthFifo.empty()
              && !s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               rxSessionFifo.read();
               currentLength = rxLengthFifo.read();
               drainState = FORWARD;
          }
          break;

     case FORWARD:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();

               // HOOK: здесь появится реассемблер SoupBinTCP —
               // rx_word.data надо будет накапливать и разбирать на
               // сообщения. Пока слово просто отбрасывается.

               if (rx_word.last)
               {
                    // Считаем по длине из уведомления, а не по числу
                    // слов: последнее слово почти всегда неполное, и
                    // wordCount * 64 дал бы завышенный результат.
                    byteCount += currentLength;
                    packetCount++;
                    drainState = IDLE;
               }
          }
          break;
     }

     // Публикуем наружу (AXI-lite, хост читает)
     rxByteCount = byteCount;
     rxPacketCount = packetCount;
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
               ap_uint<64>& rxByteCount,
               ap_uint<32>& rxPacketCount,
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

     // ---- Внутренние FIFO между стадиями ----
     //
     // ouch_rx_notify -> ouch_rx_drain: что за порцию ждать.
     //
     // Глубина с запасом: notify обслуживает уведомления каждый такт, а
     // drain занят приёмом слов текущей порции и вычитывает следующую
     // запись только между порциями. То есть при потоке коротких
     // сообщений уведомления копятся. Переполнение не приводит к
     // дедлоку (notify проверяет full() перед чтением уведомления), но
     // лишний backpressure на стек нежелателен.
     //
     // Два отдельных FIFO, а не один со структурой: так проще, и это
     // ровно та же идиома, что в gateway. Пишутся и читаются они всегда
     // парой, поэтому рассинхрона быть не может.
     static hls::stream<ap_uint<16> > rxSessionFifo("rxSessionFifo");
     #pragma HLS STREAM variable=rxSessionFifo depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo("rxLengthFifo");
     #pragma HLS STREAM variable=rxLengthFifo depth=512

     // ---- Стадии ----

     // ШАГ 1: слушаем порт
     ouch_listen(enable, listenPort,
                 m_axis_tcp_listen_port, s_axis_tcp_port_status);

     // ШАГ 2а: принимаем уведомления, запрашиваем данные
     ouch_rx_notify(s_axis_tcp_notification, m_axis_tcp_read_pkg,
                    rxSessionFifo, rxLengthFifo);

     // ШАГ 2б: вычитываем данные и выбрасываем, считая байты
     ouch_rx_drain(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                   rxSessionFifo, rxLengthFifo,
                   rxByteCount, rxPacketCount);

     // ---- Пока не реализованные интерфейсы ----
     // Заглушки обязательны: неподключённый порт стека ломает сборку hw.
     // По мере добавления шагов соответствующие tie_off_* будут
     // заменяться на настоящие стадии.
     //
     // tie_off_tcp_rx больше НЕ нужен: notification/read_pkg/rx_meta/
     // rx_data обслуживают стадии выше.
     tie_off_udp(s_axis_udp_rx, m_axis_udp_tx,
                 s_axis_udp_rx_meta, m_axis_udp_tx_meta);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection,
                                 s_axis_tcp_open_status);
     tie_off_tcp_close_con(m_axis_tcp_close_connection);
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

               // Счётчики принятого — ВЫХОДНЫЕ, хост их читает.
               // Единственная наблюдаемость на этом шаге: ядро данные
               // выбрасывает, и без счётчиков «работает» не отличить от
               // «молчит».
               ap_uint<64>& rxByteCount,
               ap_uint<32>& rxPacketCount,

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
#pragma HLS INTERFACE s_axilite port=rxByteCount bundle = control
#pragma HLS INTERFACE s_axilite port=rxPacketCount bundle = control
#pragma HLS INTERFACE s_axilite port=enable bundle = control
#pragma HLS INTERFACE ap_ctrl_none port = return

// Вся логика — в ouch_core. Здесь только интерфейс.
     ouch_core(enable, listenPort,
               rxByteCount, rxPacketCount,
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
