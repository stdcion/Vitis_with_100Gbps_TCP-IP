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

ГДЕ ЖИВУТ РЕГИСТРЫ. enable/listenPortA/listenPortB и счётчики телеметрии
приходят сюда ОБЫЧНЫМИ АРГУМЕНТАМИ, без s_axilite — то есть становятся
проводами RTL, видимыми каждый такт. Сами регистры держит HDL-обёртка
(src/hdl/dual_echo_control_s_axi.v + hls_dual_echo_krnl_wrapper.sv).

Так сделано не из вкуса, а потому что иначе нельзя: UG1393 (Free-Running
Kernels) запрещает s_axilite при ap_ctrl_none, и это ровно тот случай,
когда HLS не выдаёт ошибку, а молча портит дизайн. Проверено на плате:
скаляры защёлкивались один раз в state2 автомата верхнего модуля —

    always @ (posedge ap_clk)
        if ((1'b1 == ap_CS_fsm_state2))
            enable_read_reg_738 <= enable;      // защёлка, а не провод

— то есть сразу после снятия сброса, когда хост ещё ничего не записал.
Симптом: enable в регистре читается 1, а ядро видит 0.

ЧТО НЕ ПОМОГЛО (проверено csynth, не гадания):
  * #pragma HLS stable на скалярах — pragma принимается молча, защёлка
    остаётся: stable снимает синхронизацию МЕЖДУ процессами dataflow, а
    не защёлкивание аргумента на входе региона. Лечит s_axilite-защёлку
    только отсутствие s_axilite;
  * убрать DATAFLOW из dual_echo_core — автомат создаёт сама топ-функция.

ЧЕМ ОБЪЯВЛЕНЫ СКАЛЯРЫ. На границе ядра — #pragma HLS INTERFACE ap_none
register, то есть явное «это провод, читай каждый такт»; форма взята у
iperf_krnl (iperf_client.cpp:572-582). Внутри, на границах вложенных
dataflow-регионов (половины), — stable, потому что INTERFACE применим только
к портам ядра. Эти два механизма не конкурируют: первый задаёт форму порта,
второй снимает синхронизацию со стартом региона.

ПОЧЕМУ НЕ ap_ctrl_hs. Он даёт ap_start, и скаляры защёлкиваются по его
фронту — соблазнительно, но неверно: стадии ниже это тела функций БЕЗ
цикла, они выполняются за один проход. При ap_ctrl_hs один ap_start = один
проход, и непрерывная работа получается только через auto_restart, то есть
на каденции перезапусков вместо II=1. Тогда waitTimer тикает раз на
перезапуск, а не раз на такт (LISTEN_TIMEOUT посчитан из тактов и теряет
смысл), а rx_drain читает одно слово за перезапуск и не успевает за 100G.
network_krnl с ap_ctrl_hs — не образец: он рукописный SystemVerilog и
подделывает ap_done таймером на секунду (network_stack.sv:921).

Образец здесь — iperf_krnl, работающий на этом железе: HLS-функция
ap_ctrl_none без единого s_axilite (iperf_client.cpp:546), скаляры
проводами, регистры в iperf_role.sv:369. При этом iperf_krnl.xml заявляет
hwControlProtocol="ap_ctrl_hs" — противоречия нет, ap_ctrl_hs реализует
обёртка, а логика внутри свободно течёт с II=1.

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
 * Состояние автомата listen, вынесенное из static-переменных В ЯВНУЮ
 * СТРУКТУРУ.
 *
 * ЗАЧЕМ. Раньше состояние жило в static внутри dual_echo_listen, а функция
 * вызывается ДВАЖДЫ — по разу на половину. Работало это лишь потому, что
 * INLINE off + DATAFLOW заставляют HLS создать две отдельные копии железа,
 * у каждой свои регистры. Но это не гарантия, а наблюдаемое поведение
 * инструмента: стоит HLS переиспользовать один экземпляр, и половины a/b
 * молча делят portRequested/portOpened — тогда откроется РОВНО ОДИН порт.
 * А смысл всего ядра — доказать, что половины независимы; именно этот отказ
 * оставлять на усмотрение синтезатора нельзя.
 *
 * Со структурой независимость становится свойством кода, а не свойством
 * версии Vitis: два разных объекта -> два разных набора регистров, что бы
 * инструмент ни решил про инстанцирование.
 */
struct listenState
{
     bool portRequested;
     bool portOpened;
     ap_uint<32> waitTimer;
     ap_uint<32> attempts;
};

/*
 * Открывает listen-порт и держит его.
 *
 * portState отдаётся наружу проводом (регистр держит HDL-обёртка), чтобы по
 * JTAG было видно, на чём именно встало: 0=ждём enable, 1=запрос отправлен,
 * 2=порт открыт. Без этого "соединение не устанавливается" не отличить от
 * "порт не открылся", а на плате это единственный способ понять разницу.
 */
void dual_echo_listen(int enable,
                      int listenPort,
                      listenState& st,
                      ap_uint<32>& listenAttempts,
                      ap_uint<32>& portState,
                      hls::stream<pkt16>& m_axis_tcp_listen_port,
                      hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     // До разрешения хоста не трогаем стек: listenPort может быть ещё не
     // записан, а сам стек — ещё не запущен (см. шапку файла). Значение
     // порта приходит аргументом, поэтому одна и та же функция обслуживает
     // обе половины со своими номерами.
     if (!enable)
     {
          portState = 0;
          return;
     }

     if (!st.portRequested)
     {
          // Порт занят предыдущим запросом? Не пишем в полный поток —
          // блокирующая запись остановила бы всю стадию.
          if (m_axis_tcp_listen_port.full())
               return;

          pkt16 listen_port_pkt;
          listen_port_pkt.data = 0;
          listen_port_pkt.data(15, 0) = (ap_uint<16>)listenPort;
          m_axis_tcp_listen_port.write(listen_port_pkt);
          st.portRequested = true;
          st.waitTimer = 0;
          st.attempts++;
          listenAttempts = st.attempts;
          portState = 1;
     }
     else if (!st.portOpened)
     {
          if (!s_axis_tcp_port_status.empty())
          {
               pkt8 status_pkt = s_axis_tcp_port_status.read();
               bool success = status_pkt.data(0, 0);
               if (success)
               {
                    st.portOpened = true;
                    portState = 2;
               }
               else
               {
                    // не открылось — просим снова на следующем такте
                    st.portRequested = false;
               }
          }
          else if (st.waitTimer >= (ap_uint<32>)LISTEN_TIMEOUT)
          {
               // Стек молчит. Раньше здесь наступало вечное ожидание;
               // теперь повторяем запрос — растущий listenAttempts на
               // хосте прямо показывает, что ответа так и нет.
               st.portRequested = false;
          }
          else
          {
               st.waitTimer++;
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

     // Половина — ВЛОЖЕННЫЙ DATAFLOW-регион, её входные скаляры формально тоже
     // входы региона. Здесь нужен именно stable, а не INTERFACE: форма
     // интерфейса задаётся только на границе ядра (там стоит ap_none register),
     // у внутренней функции RTL-портов нет.
     //
     // Требование stable соблюдено буквально: UG1399 требует, чтобы читаемые
     // ячейки не перезаписывались другим процессом или вызывающим контекстом во
     // время исполнения региона. Это внешние входы, внутри дизайна их не пишет
     // никто. Предупреждение HLS 200-991 ловит ЗАПИСЬ stable-скаляра — в наших
     // логах его нет.
     #pragma HLS stable variable = enable
     #pragma HLS stable variable = listenPort

     static listenState st_a = {false, false, 0, 0};
     #pragma HLS RESET variable=st_a

     static hls::stream<ap_uint<16> > rxSessionFifo_a("rxSessionFifo_a");
     #pragma HLS STREAM variable=rxSessionFifo_a depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_a("rxLengthFifo_a");
     #pragma HLS STREAM variable=rxLengthFifo_a depth=512

     dual_echo_listen(enable, listenPort, st_a, listenAttempts, portState,
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

     // См. пояснение в dual_echo_half_a: вложенный регион, поэтому stable, а
     // не INTERFACE.
     #pragma HLS stable variable = enable
     #pragma HLS stable variable = listenPort

     // Свой объект состояния, отдельный от st_a — см. комментарий к
     // listenState: именно это делает независимость половин свойством кода.
     static listenState st_b = {false, false, 0, 0};
     #pragma HLS RESET variable=st_b

     static hls::stream<ap_uint<16> > rxSessionFifo_b("rxSessionFifo_b");
     #pragma HLS STREAM variable=rxSessionFifo_b depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_b("rxLengthFifo_b");
     #pragma HLS STREAM variable=rxLengthFifo_b depth=512

     dual_echo_listen(enable, listenPort, st_b, listenAttempts, portState,
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

               // ── Параметры: ПРОВОДА из HDL-обёртки, не s_axilite ──
               //
               // Регистры держит dual_echo_control_s_axi.v, здесь это
               // обычные аргументы -> входные порты RTL, видимые каждый
               // такт. Адресная карта задана в обёртке явно (таблица в
               // шапке dual_echo_control_s_axi.v), поэтому смещения больше
               // НЕ надо угадывать по порядку аргументов и сверять с
               // драйверным заголовком.
               int listenPortA,             // порт слушания половины a (QSFP0)
               int listenPortB,             // порт слушания половины b (QSFP1)

               // ── Телеметрия: провода НАРУЖУ, в read-only регистры ──
               ap_uint<32>& listenAttempts_a,  // сколько раз просили listen
               ap_uint<32>& portState_a,       // 0=ждём enable 1=запрос 2=открыт
               ap_uint<32>& notifyCount_a,     // уведомлений о данных
               ap_uint<32>& listenAttempts_b,
               ap_uint<32>& portState_b,
               ap_uint<32>& notifyCount_b,

               // enable — разрешение начать работу (провод из обёртки).
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

// ─────────────────────────────────────────────────────────────────────────────
// НИ ОДНОГО s_axilite — это обязательное условие ap_ctrl_none, см. подробное
// пояснение в шапке файла. Скаляры выше (listenPortA/B, enable, счётчики)
// остаются обычными аргументами и становятся портами RTL — проводами, которые
// подключает hls_dual_echo_krnl_wrapper.sv. Регистры и адресная карта живут в
// dual_echo_control_s_axi.v.
//
// ap_ctrl_none: ядро "течёт" каждый такт, стадии ниже сохраняют состояние в
// static с RESET. Каденция II=1 сохранена, поэтому LISTEN_TIMEOUT считается в
// тактах (как и задумано), а rx_drain успевает за 100G.
//
// Блочный протокол ap_ctrl_hs, который ждёт от ядра XRT/BD, реализует
// обёртка — ровно как iperf_krnl.xml заявляет ap_ctrl_hs при ap_ctrl_none у
// самой HLS-функции.
// ─────────────────────────────────────────────────────────────────────────────
#pragma HLS INTERFACE ap_ctrl_none port = return

// ВХОДНЫЕ СКАЛЯРЫ — ЯВНО ПРОВОДА.
//
// Без этих строк режим определялся неявным умолчанием. csynth подтверждал, что
// умолчание верное ("Setting interface mode on port 'enable' to 'ap_none'"), и
// битстрим на этом собрался. Но полагаться на умолчание в ядре, где неверная
// форма скаляра уже стоила нескольких сессий на плате, — плохая идея: оно
// молчаливое и может измениться с версией инструмента.
//
// Форма взята у iperf_krnl (iperf_client.cpp:572-582) — ядра, работающего на
// этом железе. register даёт защёлку на входе порта: чистая граница для
// таймингового анализа и никакого длинного комбинационного пути от регистра в
// обёртке до логики стадии.
#pragma HLS INTERFACE ap_none register port = enable
#pragma HLS INTERFACE ap_none register port = listenPortA
#pragma HLS INTERFACE ap_none register port = listenPortB

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
