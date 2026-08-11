/************************************************
Отладка механики "один HLS-инстанс, два физических QSFP-порта" на
максимально простой логике — той же, что уже проверена в hls_echo_krnl.

ЗАЧЕМ ЭТО ОТДЕЛЬНОЕ ЯДРО. hls_echo_krnl при NUM_QSFP=2 собирается ДВУМЯ
экземплярами одного и того же IP (hls_echo_krnl_1 -> network_krnl_1,
hls_echo_krnl_2 -> network_krnl_2, см. build_bd.tcl) — экземпляры
RTL-идентичны и ничего не знают друг о друге. Для тестового эха этого
достаточно. Но настоящий гейтвей (см. заметку в памяти
dual-qsfp-gateway-architecture) должен быть ОДНИМ инстансом, видящим порты
ОБОИХ network_krnl одновременно — иначе логике перекладки данных между
портами буквально не за что зацепиться. Это ядро проверяет именно эту
механику подключения (32 AXI-Stream порта на один инстанс, config_sp и
build_bd.tcl под него), НЕ добавляя relay-логику: каждая половина (a и b)
делает то же самое, что и hls_echo_krnl — слушает свой порт и глушит
данные. Как только эта механика подтверждена на живом железе, боевой
hls_ouch_krnl получает такую же форму интерфейса и настоящую логику
перекладки внутри.

КРИТЕРИЙ УСПЕХА — снаружи, после настройки по JTAG:

    nc <ip_qsfp0> <listenPortA>    подключается и не отваливается
    nc <ip_qsfp1> <listenPortB>    подключается и не отваливается, НЕЗАВИСИМО от a

Обе половины работают одновременно и не влияют друг на друга: разные
статические переменные состояния, разные AXI-Stream порты, никакого
общего состояния между ними в этом ядре нет.

ОТЛИЧИЯ ОТ hls_echo_krnl: вместо одного набора из 16 портов network_krnl
здесь два набора (суффиксы _a и _b), подключаемые в build_bd.tcl к
network_krnl_1 и network_krnl_2 соответственно.

ПОРТЫ СЛУШАНИЯ ЗАДАЮТСЯ ПО ОТДЕЛЬНОСТИ — listenPortA для половины a и
listenPortB для половины b. Один и тот же номер на обеих половинах тоже
допустим: они сидят на РАЗНЫХ network_krnl, у каждого своя
listeningPortTable, так что конфликта внутри TCP-стека не возникает.
Раздельные порты нужны по двум причинам:

  * ОТЛАДКА. При одинаковом номере неудачное подключение не говорит,
    какая половина виновата: попал ли ты не на тот IP или не открылся
    порт. С разными номерами это два разных теста.
  * НЕЗАВИСИМОСТЬ ОТ АДРЕСОВ. Если по какой-то причине оба стека
    отвечают на один IP (ошибка в bringup, недозащёлкнутый адрес),
    одинаковый порт делает половины неразличимыми снаружи. Разные
    номера дают однозначный ответ, кто ответил.

────────────────────────────────────────────────────────────────────────
ПРО enable И ГОНКУ СО СТЕКОМ. Ядро объявлено ap_ctrl_none, то есть
"течёт" с первого такта после снятия сброса — а это происходит сразу
после загрузки битстрима, задолго до того, как хост придёт по JTAG.
Раньше порт слушания запрашивался безусловно, и получалось так:

    сброс снят -> ядро пишет listen -> ... десятки секунд ...
    -> хост пишет IP/MAC -> network_start (только здесь TOE получает IP)

TOE сбрасывается только по net_aresetn (см. network_stack.sv:656), а НЕ
по ap_start_pulse, которым защёлкивается IP. Значит к моменту появления
адреса TOE уже проработал с нулевым, и состояние listen-порта, открытого
до этого, ничего не гарантирует.

Поэтому теперь порт слушания НЕ запрашивается, пока хост не разрешил.
Порядок на хосте (см. jtag_ctrl.tcl):

    echo_bringup_dual ...            IP/MAC + network_start  (стек поднят)
    dual_echo_configure <pA> <pB>    номера портов в регистры
    dual_echo_enable 1               только теперь идёт listen

enable ОБЯЗАТЕЛЬНО последним: до него не тронут ни один порт стека,
потому что listenPortA/listenPortB могут быть ещё не записаны.

ПОВТОР ПО ТАЙМАУТУ, а не только по отказу. Прежняя версия сбрасывала
portRequested лишь когда стек ответил success=0. Если стек промолчал
(не готов, ответ потерян, backpressure) — автомат залипал в
"запрос отправлен, ответа ждём" НАВСЕГДА, без единого признака снаружи.
Теперь молчание дольше LISTEN_TIMEOUT тоже приводит к повтору.
────────────────────────────────────────────────────────────────────────
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Сколько ждать ответа стека на запрос listen, прежде чем повторить.
// 170 МГц * ~6 мс. Число некритично: важно лишь, чтобы повтор вообще
// случался, а не был заметно чаще, чем стек успевает отвечать.
#define LISTEN_TIMEOUT 1000000

/*
 * Открывает listen-порт и держит его.
 *
 * Продублирована (а не переиспользована из hls_echo_krnl.cpp), потому что
 * вызывается дважды с независимым состоянием — static-переменные внутри
 * принадлежат КОНКРЕТНОМУ вызову в дизайне, а не функции как таковой, так
 * что общий код тут ничего бы не сэкономил по железу, только по числу
 * строк.
 *
 * portState отдаётся наружу в s_axilite, чтобы по JTAG было видно, на чём
 * именно встало: 0=ждём enable, 1=запрос отправлен, 2=порт открыт.
 * Без этого "соединение не устанавливается" не отличить от "порт не
 * открылся", а на плате это единственный способ понять разницу.
 */
void dual_echo_listen(int enable,
                      int listenPort,
                      ap_uint<32>& listenAttempts,
                      ap_uint<32>& portState,
                      hls::stream<pkt16>& m_axis_tcp_listen_port,
                      hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portRequested = false;
#pragma HLS RESET variable=portRequested
     static bool portOpened = false;
#pragma HLS RESET variable=portOpened
     static ap_uint<32> waitTimer = 0;
#pragma HLS RESET variable=waitTimer
     static ap_uint<32> attempts = 0;
#pragma HLS RESET variable=attempts

     // До разрешения хоста не трогаем стек: listenPort может быть ещё не
     // записан, а сам стек — ещё не запущен (см. шапку файла). Значение
     // порта приходит аргументом, поэтому одна и та же функция обслуживает
     // обе половины со своими номерами.
     if (!enable)
     {
          portState = 0;
          return;
     }

     if (!portRequested)
     {
          pkt16 listen_port_pkt;
          listen_port_pkt.data = 0;
          listen_port_pkt.data(15, 0) = (ap_uint<16>)listenPort;
          m_axis_tcp_listen_port.write(listen_port_pkt);
          portRequested = true;
          waitTimer = 0;
          attempts++;
          listenAttempts = attempts;
          portState = 1;
     }
     else if (!portOpened)
     {
          if (!s_axis_tcp_port_status.empty())
          {
               pkt8 status_pkt = s_axis_tcp_port_status.read();
               bool success = status_pkt.data(0, 0);
               if (success)
               {
                    portOpened = true;
                    portState = 2;
               }
               else
               {
                    // не открылось — просим снова на следующем такте
                    portRequested = false;
               }
          }
          else if (waitTimer >= (ap_uint<32>)LISTEN_TIMEOUT)
          {
               // Стек молчит. Раньше здесь наступало вечное ожидание;
               // теперь повторяем запрос — растущий listenAttempts на
               // хосте прямо показывает, что ответа так и нет.
               portRequested = false;
          }
          else
          {
               waitTimer++;
          }
     }
}

/*
 * Приём уведомлений: см. echo_rx_notify в hls_echo_krnl.cpp — логика
 * без изменений, продублирована по той же причине, что и listen выше.
 *
 * Добавлен notifyCount: по нему на хосте видно, дошло ли до ядра хоть
 * одно уведомление о данных. Вместе с portState это разделяет "порт не
 * открыт", "порт открыт, но клиент не подключился" и "данные идут".
 */
void dual_echo_rx_notify(ap_uint<32>& notifyCount,
                         hls::stream<pkt128>& s_axis_tcp_notification,
                         hls::stream<pkt32>& m_axis_tcp_read_pkg,
                         hls::stream<ap_uint<16> >& rxSessionFifo,
                         hls::stream<ap_uint<16> >& rxLengthFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static ap_uint<32> notifications = 0;
#pragma HLS RESET variable=notifications

     if (s_axis_tcp_notification.empty())
          return;

     if (rxSessionFifo.full() || rxLengthFifo.full())
          return;

     pkt128 notification_pkt = s_axis_tcp_notification.read();
     ap_uint<16> sessionID = notification_pkt.data(15, 0);
     ap_uint<16> length    = notification_pkt.data(31, 16);

     notifications++;
     notifyCount = notifications;

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
 * Вычитывает пришедшие данные и выбрасывает. См. echo_rx_drain в
 * hls_echo_krnl.cpp — логика без изменений.
 */
void dual_echo_rx_drain(hls::stream<pkt16>& s_axis_tcp_rx_meta,
                        hls::stream<pkt512>& s_axis_tcp_rx_data,
                        hls::stream<ap_uint<16> >& rxSessionFifo,
                        hls::stream<ap_uint<16> >& rxLengthFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum drainStateType {IDLE, FORWARD};
     static drainStateType drainState = IDLE;
#pragma HLS RESET variable=drainState

     switch (drainState)
     {
     case IDLE:
          if (!rxSessionFifo.empty() && !rxLengthFifo.empty()
              && !s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               rxSessionFifo.read();
               rxLengthFifo.read();
               drainState = FORWARD;
          }
          break;

     case FORWARD:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();
               if (rx_word.last)
               {
                    drainState = IDLE;
               }
          }
          break;
     }
}

/*
 * Одна половина: слушает порт, поглощает данные на своём наборе
 * портов network_krnl. Вызывается два раза с независимыми именами
 * static-потоков (см. HLS STREAM variable= — влияет на итоговое имя
 * сигнала в RTL, поэтому суффикс _a/_b обязателен, иначе два вызова
 * получили бы одинаковые внутренние имена и синтез перепутал бы их
 * FIFO друг с другом).
 */
void dual_echo_half_a(int enable,
                      int listenPort,
                      ap_uint<32>& listenAttempts,
                      ap_uint<32>& portState,
                      ap_uint<32>& notifyCount,
                      hls::stream<pkt16>& m_axis_tcp_listen_port,
                      hls::stream<pkt8>& s_axis_tcp_port_status,
                      hls::stream<pkt128>& s_axis_tcp_notification,
                      hls::stream<pkt32>& m_axis_tcp_read_pkg,
                      hls::stream<pkt16>& s_axis_tcp_rx_meta,
                      hls::stream<pkt512>& s_axis_tcp_rx_data)
{
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     // Половина — DATAFLOW-регион, её входные скаляры формально тоже входы
     // региона. stable здесь оставлен как страховка: вреда он не несёт, а
     // синхронизацию между стадиями снимает. ГЛАВНОЕ же лечение — отсутствие
     // DATAFLOW у вызывающей dual_echo_core, см. пояснение там.
     #pragma HLS stable variable = enable
     #pragma HLS stable variable = listenPort

     static hls::stream<ap_uint<16> > rxSessionFifo_a("rxSessionFifo_a");
     #pragma HLS STREAM variable=rxSessionFifo_a depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_a("rxLengthFifo_a");
     #pragma HLS STREAM variable=rxLengthFifo_a depth=512

     dual_echo_listen(enable, listenPort, listenAttempts, portState,
                      m_axis_tcp_listen_port, s_axis_tcp_port_status);

     dual_echo_rx_notify(notifyCount,
                        s_axis_tcp_notification, m_axis_tcp_read_pkg,
                        rxSessionFifo_a, rxLengthFifo_a);

     dual_echo_rx_drain(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                       rxSessionFifo_a, rxLengthFifo_a);
}

void dual_echo_half_b(int enable,
                      int listenPort,
                      ap_uint<32>& listenAttempts,
                      ap_uint<32>& portState,
                      ap_uint<32>& notifyCount,
                      hls::stream<pkt16>& m_axis_tcp_listen_port,
                      hls::stream<pkt8>& s_axis_tcp_port_status,
                      hls::stream<pkt128>& s_axis_tcp_notification,
                      hls::stream<pkt32>& m_axis_tcp_read_pkg,
                      hls::stream<pkt16>& s_axis_tcp_rx_meta,
                      hls::stream<pkt512>& s_axis_tcp_rx_data)
{
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     // См. пояснение в dual_echo_half_a и в dual_echo_core.
     #pragma HLS stable variable = enable
     #pragma HLS stable variable = listenPort

     static hls::stream<ap_uint<16> > rxSessionFifo_b("rxSessionFifo_b");
     #pragma HLS STREAM variable=rxSessionFifo_b depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_b("rxLengthFifo_b");
     #pragma HLS STREAM variable=rxLengthFifo_b depth=512

     dual_echo_listen(enable, listenPort, listenAttempts, portState,
                      m_axis_tcp_listen_port, s_axis_tcp_port_status);

     dual_echo_rx_notify(notifyCount,
                        s_axis_tcp_notification, m_axis_tcp_read_pkg,
                        rxSessionFifo_b, rxLengthFifo_b);

     dual_echo_rx_drain(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
                       rxSessionFifo_b, rxLengthFifo_b);
}

void dual_echo_core(
     // половина a (-> network_krnl_1, QSFP0)
     hls::stream<pkt512>& s_axis_udp_rx_a,
     hls::stream<pkt512>& m_axis_udp_tx_a,
     hls::stream<pkt256>& s_axis_udp_rx_meta_a,
     hls::stream<pkt256>& m_axis_udp_tx_meta_a,
     hls::stream<pkt16>& m_axis_tcp_listen_port_a,
     hls::stream<pkt8>& s_axis_tcp_port_status_a,
     hls::stream<pkt64>& m_axis_tcp_open_connection_a,
     hls::stream<pkt128>& s_axis_tcp_open_status_a,
     hls::stream<pkt16>& m_axis_tcp_close_connection_a,
     hls::stream<pkt128>& s_axis_tcp_notification_a,
     hls::stream<pkt32>& m_axis_tcp_read_pkg_a,
     hls::stream<pkt16>& s_axis_tcp_rx_meta_a,
     hls::stream<pkt512>& s_axis_tcp_rx_data_a,
     hls::stream<pkt32>& m_axis_tcp_tx_meta_a,
     hls::stream<pkt512>& m_axis_tcp_tx_data_a,
     hls::stream<pkt64>& s_axis_tcp_tx_status_a,
     // половина b (-> network_krnl_2, QSFP1)
     hls::stream<pkt512>& s_axis_udp_rx_b,
     hls::stream<pkt512>& m_axis_udp_tx_b,
     hls::stream<pkt256>& s_axis_udp_rx_meta_b,
     hls::stream<pkt256>& m_axis_udp_tx_meta_b,
     hls::stream<pkt16>& m_axis_tcp_listen_port_b,
     hls::stream<pkt8>& s_axis_tcp_port_status_b,
     hls::stream<pkt64>& m_axis_tcp_open_connection_b,
     hls::stream<pkt128>& s_axis_tcp_open_status_b,
     hls::stream<pkt16>& m_axis_tcp_close_connection_b,
     hls::stream<pkt128>& s_axis_tcp_notification_b,
     hls::stream<pkt32>& m_axis_tcp_read_pkg_b,
     hls::stream<pkt16>& s_axis_tcp_rx_meta_b,
     hls::stream<pkt512>& s_axis_tcp_rx_data_b,
     hls::stream<pkt32>& m_axis_tcp_tx_meta_b,
     hls::stream<pkt512>& m_axis_tcp_tx_data_b,
     hls::stream<pkt64>& s_axis_tcp_tx_status_b,
     // управление и телеметрия (s_axi_control)
     int enable,
     int listenPortA,
     int listenPortB,
     ap_uint<32>& listenAttempts_a,
     ap_uint<32>& portState_a,
     ap_uint<32>& notifyCount_a,
     ap_uint<32>& listenAttempts_b,
     ap_uint<32>& portState_b,
     ap_uint<32>& notifyCount_b)
{
// INLINE ставить нельзя — HLS 214-272, как и в hls_echo_krnl.cpp.
#pragma HLS INLINE off

#pragma HLS DATAFLOW disable_start_propagation


     dual_echo_half_a(enable, listenPortA,
                      listenAttempts_a, portState_a, notifyCount_a,
                      m_axis_tcp_listen_port_a, s_axis_tcp_port_status_a,
                      s_axis_tcp_notification_a, m_axis_tcp_read_pkg_a,
                      s_axis_tcp_rx_meta_a, s_axis_tcp_rx_data_a);

     dual_echo_half_b(enable, listenPortB,
                      listenAttempts_b, portState_b, notifyCount_b,
                      m_axis_tcp_listen_port_b, s_axis_tcp_port_status_b,
                      s_axis_tcp_notification_b, m_axis_tcp_read_pkg_b,
                      s_axis_tcp_rx_meta_b, s_axis_tcp_rx_data_b);

     // Заглушки на всё, что не используется — по одной на каждую
     // половину, неподключённый порт стека ломает сборку hw.
     tie_off_udp(s_axis_udp_rx_a, m_axis_udp_tx_a,
                 s_axis_udp_rx_meta_a, m_axis_udp_tx_meta_a);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection_a,
                                 s_axis_tcp_open_status_a);
     tie_off_tcp_close_con(m_axis_tcp_close_connection_a);
     tie_off_tcp_tx(m_axis_tcp_tx_meta_a, m_axis_tcp_tx_data_a,
                    s_axis_tcp_tx_status_a);

     tie_off_udp(s_axis_udp_rx_b, m_axis_udp_tx_b,
                 s_axis_udp_rx_meta_b, m_axis_udp_tx_meta_b);
     tie_off_tcp_open_connection(m_axis_tcp_open_connection_b,
                                 s_axis_tcp_open_status_b);
     tie_off_tcp_close_con(m_axis_tcp_close_connection_b);
     tie_off_tcp_tx(m_axis_tcp_tx_meta_b, m_axis_tcp_tx_data_b,
                    s_axis_tcp_tx_status_b);
}

extern "C" {
void hls_dual_echo_krnl(
               // половина a — подключается к network_krnl_1 (QSFP0)
               hls::stream<pkt512>& s_axis_udp_rx_a,
               hls::stream<pkt512>& m_axis_udp_tx_a,
               hls::stream<pkt256>& s_axis_udp_rx_meta_a,
               hls::stream<pkt256>& m_axis_udp_tx_meta_a,
               hls::stream<pkt16>& m_axis_tcp_listen_port_a,
               hls::stream<pkt8>& s_axis_tcp_port_status_a,
               hls::stream<pkt64>& m_axis_tcp_open_connection_a,
               hls::stream<pkt128>& s_axis_tcp_open_status_a,
               hls::stream<pkt16>& m_axis_tcp_close_connection_a,
               hls::stream<pkt128>& s_axis_tcp_notification_a,
               hls::stream<pkt32>& m_axis_tcp_read_pkg_a,
               hls::stream<pkt16>& s_axis_tcp_rx_meta_a,
               hls::stream<pkt512>& s_axis_tcp_rx_data_a,
               hls::stream<pkt32>& m_axis_tcp_tx_meta_a,
               hls::stream<pkt512>& m_axis_tcp_tx_data_a,
               hls::stream<pkt64>& s_axis_tcp_tx_status_a,

               // половина b — подключается к network_krnl_2 (QSFP1)
               hls::stream<pkt512>& s_axis_udp_rx_b,
               hls::stream<pkt512>& m_axis_udp_tx_b,
               hls::stream<pkt256>& s_axis_udp_rx_meta_b,
               hls::stream<pkt256>& m_axis_udp_tx_meta_b,
               hls::stream<pkt16>& m_axis_tcp_listen_port_b,
               hls::stream<pkt8>& s_axis_tcp_port_status_b,
               hls::stream<pkt64>& m_axis_tcp_open_connection_b,
               hls::stream<pkt128>& s_axis_tcp_open_status_b,
               hls::stream<pkt16>& m_axis_tcp_close_connection_b,
               hls::stream<pkt128>& s_axis_tcp_notification_b,
               hls::stream<pkt32>& m_axis_tcp_read_pkg_b,
               hls::stream<pkt16>& s_axis_tcp_rx_meta_b,
               hls::stream<pkt512>& s_axis_tcp_rx_data_b,
               hls::stream<pkt32>& m_axis_tcp_tx_meta_b,
               hls::stream<pkt512>& m_axis_tcp_tx_data_b,
               hls::stream<pkt64>& s_axis_tcp_tx_status_b,

               // ── Параметры (пишутся по JTAG до enable) ──
               //
               // ВАЖНО: смещения регистров берутся из сгенерированного
               // заголовка драйвера, а не вычисляются по порядку
               // аргументов — HLS вставляет ap_vld-регистр после каждого
               // ВЫХОДНОГО значения, поэтому шаг у входов 8 байт, а у
               // выходов 16. При правке этой сигнатуры сверить
               // DUAL_ECHO_OFF_* в scripts/vivado/jtag_ctrl.tcl заново.
               int listenPortA,             // порт слушания половины a (QSFP0)
               int listenPortB,             // порт слушания половины b (QSFP1)

               // ── Телеметрия (только чтение) ──
               ap_uint<32>& listenAttempts_a,  // сколько раз просили listen
               ap_uint<32>& portState_a,       // 0=ждём enable 1=запрос 2=открыт
               ap_uint<32>& notifyCount_a,     // уведомлений о данных
               ap_uint<32>& listenAttempts_b,
               ap_uint<32>& portState_b,
               ap_uint<32>& notifyCount_b,

               // enable ВСЕГДА последний — разрешение начать работу.
               int enable)
{
#pragma HLS INTERFACE axis port = s_axis_udp_rx_a
#pragma HLS INTERFACE axis port = m_axis_udp_tx_a
#pragma HLS INTERFACE axis port = s_axis_udp_rx_meta_a
#pragma HLS INTERFACE axis port = m_axis_udp_tx_meta_a
#pragma HLS INTERFACE axis port = m_axis_tcp_listen_port_a
#pragma HLS INTERFACE axis port = s_axis_tcp_port_status_a
#pragma HLS INTERFACE axis port = m_axis_tcp_open_connection_a
#pragma HLS INTERFACE axis port = s_axis_tcp_open_status_a
#pragma HLS INTERFACE axis port = m_axis_tcp_close_connection_a
#pragma HLS INTERFACE axis port = s_axis_tcp_notification_a
#pragma HLS INTERFACE axis port = m_axis_tcp_read_pkg_a
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_meta_a
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_data_a
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_meta_a
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_data_a
#pragma HLS INTERFACE axis port = s_axis_tcp_tx_status_a

#pragma HLS INTERFACE axis port = s_axis_udp_rx_b
#pragma HLS INTERFACE axis port = m_axis_udp_tx_b
#pragma HLS INTERFACE axis port = s_axis_udp_rx_meta_b
#pragma HLS INTERFACE axis port = m_axis_udp_tx_meta_b
#pragma HLS INTERFACE axis port = m_axis_tcp_listen_port_b
#pragma HLS INTERFACE axis port = s_axis_tcp_port_status_b
#pragma HLS INTERFACE axis port = m_axis_tcp_open_connection_b
#pragma HLS INTERFACE axis port = s_axis_tcp_open_status_b
#pragma HLS INTERFACE axis port = m_axis_tcp_close_connection_b
#pragma HLS INTERFACE axis port = s_axis_tcp_notification_b
#pragma HLS INTERFACE axis port = m_axis_tcp_read_pkg_b
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_meta_b
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_data_b
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_meta_b
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_data_b
#pragma HLS INTERFACE axis port = s_axis_tcp_tx_status_b

#pragma HLS INTERFACE s_axilite port = listenPortA bundle = control
#pragma HLS INTERFACE s_axilite port = listenPortB bundle = control

#pragma HLS INTERFACE s_axilite port = listenAttempts_a bundle = control
#pragma HLS INTERFACE s_axilite port = portState_a      bundle = control
#pragma HLS INTERFACE s_axilite port = notifyCount_a    bundle = control
#pragma HLS INTERFACE s_axilite port = listenAttempts_b bundle = control
#pragma HLS INTERFACE s_axilite port = portState_b      bundle = control
#pragma HLS INTERFACE s_axilite port = notifyCount_b    bundle = control

#pragma HLS INTERFACE s_axilite port = enable bundle = control
// ─────────────────────────────────────────────────────────────────────────────
// ap_ctrl_hs (по умолчанию), а НЕ ap_ctrl_none — и это принципиально.
//
// ПОЧЕМУ НЕ ap_ctrl_none. Free-running ядро несовместимо с параметрами от
// хоста. Документация Xilinx прямо это пишет: "The kernel interface should not
// have any #pragma HLS interface s_axilite (as there should not be any memory
// or control port)". Мы это проверили на плате и получили ровно обещанное:
// входные скаляры защёлкиваются один раз, в состоянии 2 автомата верхнего
// модуля:
//
//     always @ (posedge ap_clk)
//         if ((1'b1 == ap_CS_fsm_state2))
//             enable_read_reg_738 <= enable;      // защёлка, а не провод
//
// При ap_ctrl_none это состояние проходится ОДИН раз, сразу после снятия
// сброса, когда хост ещё ничего не записал. Дальше ядро работает вечно и в
// state2 не возвращается — запись по JTAG (секунды позже) до логики не доходит
// НИКОГДА. Симптом: enable в регистре читается 1, а ядро видит 0 (portState с
// ap_vld=1 и значением 0, listenAttempts с ap_vld=0). listenPortA/B
// защёлкивались там же и тоже нулями.
//
// ЧТО НЕ ПОМОГЛО (проверено csynth, не гадания):
//   * #pragma HLS stable на скалярах — pragma принимается без предупреждений,
//     enable_read_reg остаётся. stable снимает синхронизацию МЕЖДУ процессами
//     dataflow, а не защёлкивание аргумента на входе региона.
//   * убрать DATAFLOW из dual_echo_core — защёлка осталась в том же state2,
//     потому что автомат создаёт сама топ-функция.
//
// ПОЧЕМУ ap_ctrl_hs РАБОТАЕТ. Появляется ap_start, и скаляры защёлкиваются по
// его фронту. Значит порядок «записать параметры -> дёрнуть ap_start» верен по
// построению, а не вопреки документации. Ровно так и работает network_krnl в
// этом же дизайне: ap_ctrl_hs, бесконечная логика, auto_restart, и его
// ip_addr/mac_addr через s_axilite до логики доходят (видно в VIO).
//
// Хост обязан записать 0x81 в ap_ctrl (ap_start=1 + auto_restart=1), см.
// dual_echo_enable в jtag_ctrl.tcl. auto_restart нужен, чтобы ядро
// перезапускалось само и работало непрерывно.
//
// ПОБОЧНАЯ ПОЛЬЗА: гонка «ядро запросило listen до записи параметров»
// становится невозможной — до ap_start ядро не исполняется вовсе.
// ─────────────────────────────────────────────────────────────────────────────
#pragma HLS INTERFACE s_axilite port = return bundle = control

     dual_echo_core(s_axis_udp_rx_a, m_axis_udp_tx_a,
                    s_axis_udp_rx_meta_a, m_axis_udp_tx_meta_a,
                    m_axis_tcp_listen_port_a, s_axis_tcp_port_status_a,
                    m_axis_tcp_open_connection_a, s_axis_tcp_open_status_a,
                    m_axis_tcp_close_connection_a,
                    s_axis_tcp_notification_a, m_axis_tcp_read_pkg_a,
                    s_axis_tcp_rx_meta_a, s_axis_tcp_rx_data_a,
                    m_axis_tcp_tx_meta_a, m_axis_tcp_tx_data_a,
                    s_axis_tcp_tx_status_a,

                    s_axis_udp_rx_b, m_axis_udp_tx_b,
                    s_axis_udp_rx_meta_b, m_axis_udp_tx_meta_b,
                    m_axis_tcp_listen_port_b, s_axis_tcp_port_status_b,
                    m_axis_tcp_open_connection_b, s_axis_tcp_open_status_b,
                    m_axis_tcp_close_connection_b,
                    s_axis_tcp_notification_b, m_axis_tcp_read_pkg_b,
                    s_axis_tcp_rx_meta_b, s_axis_tcp_rx_data_b,
                    m_axis_tcp_tx_meta_b, m_axis_tcp_tx_data_b,
                    s_axis_tcp_tx_status_b,

                    enable, listenPortA, listenPortB,
                    listenAttempts_a, portState_a, notifyCount_a,
                    listenAttempts_b, portState_b, notifyCount_b);
}
}
