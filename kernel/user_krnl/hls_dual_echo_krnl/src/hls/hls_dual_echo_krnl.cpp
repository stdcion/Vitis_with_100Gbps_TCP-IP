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

// Граница вечного цикла стадий ТОЛЬКО для csim (см. пояснение у while(true) в
// dual_echo_listen). При синтезе не используется: в железе цикл бесконечен.
// Значение с запасом — тестбенчу нужны единицы итераций на шаг протокола, а
// лишние обходы холостые.
#ifndef __SYNTHESIS__
#define DE_CSIM_ITERS 10000
#endif

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
/*
 * Состояние rx_notify и rx_drain — тоже В СТРУКТУРАХ, по той же причине, что и
 * listenState ниже: обе функции вызываются ДВАЖДЫ, по разу на половину.
 *
 * Пока половины были отдельными вложенными DATAFLOW-регионами, HLS создавал две
 * копии железа и static-переменные внутри функций не сталкивались. После
 * перехода на плоский DATAFLOW (все шесть стадий в dual_echo_core) копии
 * слились, и HLS отказался синтезировать:
 *
 *     ERROR: [HLS 200-471] Dataflow form checks found feedback dependence
 *            in dataflow-region for global/static variable notifications
 *     ERROR: [HLS 200-471] ... for global/static variable drainState
 *
 * То есть инструмент прямо говорит: две стадии одного региона не могут делить
 * static. Лечится так же, как для listen — состояние наружу, по ссылке.
 */
struct notifyState
{
     ap_uint<32> notifications;
};

struct drainState_t
{
     enum { IDLE, FORWARD } st;
};

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
#pragma HLS INLINE off

     // ── ВЕЧНЫЙ ЦИКЛ: СТАДИЯ НЕ ДОЛЖНА ВЫДАВАТЬ ap_done ──────────────────────
     //
     // ЗАЧЕМ. В dataflow-регионе `ap_continue` каждой стадии равен `ap_sync_done`
     // — логическому И по `ap_done` ВСЕХ 14 стадий (dual_echo_core.v:1337). А
     // внутри стадии `ap_done_reg` сбрасывается только по `ap_continue`
     // (dual_echo_listen.v:303), и пока он поднят, конвейер заблокирован (:609).
     //
     // Пока ВСЕ стадии короткие, `ap_sync_done` вычисляется каждый такт и требует
     // совпадения 14 сигналов с разными периодами (у нас смесь II=1 и II=2).
     // Совпадения не происходит, `ap_continue` не приходит, и каждая стадия
     // встаёт после ПЕРВОГО прохода. Измерено на полном ядре в tb_core_ap_done:
     // 3 млн тактов при enable=1 и TREADY=1 дали ОДНУ запись listen-порта вместо
     // повторов по таймауту.
     //
     // Достаточно ОДНОЙ незавершающейся стадии, чтобы `ap_sync_done` навсегда
     // ушёл в ноль: тогда барьер просто не срабатывает, и остальные стадии
     // перестают в него упираться. Именно так устроен упстрим — и это НЕ
     // самодеятельность:
     //
     //   * hls_recv_krnl, recvData_handshake (communication.hpp:1218):
     //         do { ... } while (rxByteCnt < expRxBytePerSession);
     //     `expRxBytePerSession` задаёт хост, на плате это минуты работы.
     //     В отчёте csynth латентность такой стадии — «?», ap_done не выдаётся.
     //   * iperf_krnl, client (iperf_client.cpp:170) — FSM в цикле, тоже не
     //     завершается.
     //
     // То есть у авторов барьер `ap_sync_done` МЁРТВ ПО ПОСТРОЕНИЮ: его держит
     // долгоживущая стадия. Мы его случайно оживили, сделав все стадии
     // короткими.
     //
     // ПОЧЕМУ ПРАГМА ПЕРЕЕХАЛА ВНУТРЬ. `PIPELINE II=1` относится к телу цикла, а
     // не к функции: снаружи он бы конвейеризовал функцию целиком и цикл остался
     // бы последовательным.
     //
     // `return` ЗАМЕНЁН НА `continue` — иначе выход из функции завершил бы её и
     // вернул ту самую `ap_done`, ради отсутствия которой цикл и заведён.
     //
     // `static`-состояние (st) остаётся снаружи: внутри цикла оно живёт всё время
     // работы ядра, рестарта больше нет. Ср. hls-early-return-stops-stage.
     //
     // ПРО ГРАНИЦУ ЦИКЛА В csim. Вечный цикл повесил бы csim: тестбенч вызывает
     // топ-функцию и ждёт возврата (test_hls_dual_echo_krnl.cpp:113). Поэтому
     // число итераций ограничено ТОЛЬКО в программной сборке, а при синтезе
     // остаётся бесконечным. Так же поступает упстрим, только иначе: у него
     // условие выхода — счётчик принятых байт, который хост задаёт огромным
     // (`expRxBytePerSession`), то есть цикл конечен формально и бесконечен
     // практически. Наш вариант честнее: в железе НЕТ условия выхода вообще,
     // а не «очень большое», поэтому и рассуждать о его достижимости не нужно.
     //
     // DE_CSIM_ITERS подобран так, чтобы тестбенчу хватило на все сценарии:
     // ему нужны единицы итераций на каждый шаг протокола.
#ifdef __SYNTHESIS__
     while (true)
#else
     for (int csim_guard = 0; csim_guard < DE_CSIM_ITERS; csim_guard++)
#endif
     {
     #pragma HLS PIPELINE II=1

          // До разрешения хоста не трогаем стек: listenPort может быть ещё не
          // записан, а сам стек — ещё не запущен (см. шапку файла). Значение
          // порта приходит аргументом, поэтому одна и та же функция обслуживает
          // обе половины со своими номерами.
          if (!enable)
          {
               portState = 0;
               continue;
          }

          if (!st.portRequested)
          {
               // Порт занят предыдущим запросом? Не пишем в полный поток —
               // блокирующая запись остановила бы всю стадию.
               if (m_axis_tcp_listen_port.full())
                    continue;

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
}

/*
 * Приём уведомлений: см. echo_rx_notify в hls_echo_krnl.cpp — логика
 * без изменений, продублирована по той же причине, что и listen выше.
 *
 * Добавлен notifyCount: по нему на хосте видно, дошло ли до ядра хоть
 * одно уведомление о данных. Вместе с portState это разделяет "порт не
 * открыт", "порт открыт, но клиент не подключился" и "данные идут".
 */
void dual_echo_rx_notify(notifyState& ns,
                         ap_uint<32>& notifyCount,
                         hls::stream<pkt128>& s_axis_tcp_notification,
                         hls::stream<pkt32>& m_axis_tcp_read_pkg,
                         hls::stream<ap_uint<16> >& rxSessionFifo,
                         hls::stream<ap_uint<16> >& rxLengthFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off


     if (s_axis_tcp_notification.empty())
          return;

     if (rxSessionFifo.full() || rxLengthFifo.full())
          return;

     pkt128 notification_pkt = s_axis_tcp_notification.read();
     ap_uint<16> sessionID = notification_pkt.data(15, 0);
     ap_uint<16> length    = notification_pkt.data(31, 16);

     ns.notifications++;
     notifyCount = ns.notifications;

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
void dual_echo_rx_drain(drainState_t& ds,
                        hls::stream<pkt16>& s_axis_tcp_rx_meta,
                        hls::stream<pkt512>& s_axis_tcp_rx_data,
                        hls::stream<ap_uint<16> >& rxSessionFifo,
                        hls::stream<ap_uint<16> >& rxLengthFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     switch (ds.st)
     {
     case drainState_t::IDLE:
          if (!rxSessionFifo.empty() && !rxLengthFifo.empty()
              && !s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               rxSessionFifo.read();
               rxLengthFifo.read();
               ds.st = drainState_t::FORWARD;
          }
          break;

     case drainState_t::FORWARD:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();
               if (rx_word.last)
               {
                    ds.st = drainState_t::IDLE;
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
/*
 * ПОЛОВИН КАК ФУНКЦИЙ БОЛЬШЕ НЕТ — И ЭТО ГЛАВНАЯ ПРАВКА ЭТОГО ЯДРА.
 *
 * Здесь были dual_echo_half_a и dual_echo_half_b: каждая со своим
 * #pragma HLS DATAFLOW, внутри — вызовы listen/rx_notify/rx_drain. Итого ТРИ
 * вложенных DATAFLOW-региона (core + две половины), и скаляр из AXI пересекал
 * ДВЕ границы: снаружи в core, потом из core в половину.
 *
 * НА ВТОРОЙ ГРАНИЦЕ HLS ПРЕВРАЩАЕТ СКАЛЯР В FIFO-КАНАЛ. Проверено на
 * сгенерированном RTL (dual_echo_core.v), одинаково и для enable, и для
 * listenPort:
 *
 *     .enable(empty_178)                 <- половине a провод
 *     .enable_dout(p_c_dout)             <- половине b канал
 *     .enable_empty_n(p_c_empty_n)
 *     .listenPort(empty_180)             <- то же самое с портом
 *     .listenPort_dout(p_c1_dout)
 *
 * Причём писателем канала оказывалась САМА половина a. А она внутри
 * dual_echo_listen делала `if (!enable) return;` — то есть выходила ДО записи в
 * канал. Итог: enable=0 -> a не пишет -> b навсегда стоит на empty_n=0 -> b не
 * отдаёт ap_ready -> регион встал -> a больше никогда не исполнится, чтобы
 * увидеть, что enable уже стал единицей. ВЗАИМНАЯ БЛОКИРОВКА.
 *
 * Симптом на плате (стоил половины сессии): регистры живые, enable=1 читается
 * обратно, listenPortA/B подтверждаются — а вся телеметрия нули НАВСЕГДА и
 * listenAttempts не растёт. Выглядит в точности как старый баг с s_axilite,
 * поэтому легко решить, что прошита не та версия. Это и есть те самые
 * предупреждения HLS 200-656 "Deadlocks can occur", которые неделями
 * принимались за шум.
 *
 * ПОЧЕМУ ПОМОГЛО ПЛОСКОЕ РАЗВЁРТЫВАНИЕ. hls_echo_probe_dual_krnl устроен с
 * ОДНИМ уровнем DATAFLOW: четыре стадии лежат прямо в epd_core. Проверено на
 * его RTL — там все скаляры доехали ПРОВОДАМИ, включая triggerGo, который
 * меняется на каждом замере, и три копии enable:
 *
 *     .enableConn(enableConn)  .serverIp(serverIp)  .triggerGo(triggerGo)
 *     grep "_c_dout|_c_empty_n|_c_write|_c_U" -> ПУСТО
 *
 * Поэтому здесь сделано так же: шесть стадий (по три на половину) вызываются
 * прямо из dual_echo_core, промежуточного уровня нет. Скаляр пересекает ОДНУ
 * границу и остаётся проводом.
 *
 * НЕЗАВИСИМОСТЬ ПОЛОВИН ОТ ЭТОГО НЕ ПОСТРАДАЛА. Она держится не на том, что
 * половины были отдельными функциями, а на раздельном состоянии: st_a/st_b —
 * разные объекты listenState, rxSessionFifo_a/_b и rxLengthFifo_a/_b — разные
 * потоки. Это было сделано раньше (см. комментарий к listenState) именно чтобы
 * независимость стала свойством кода, а не свойством инстанцирования.
 *
 * ПРАВИЛО НА БУДУЩЕЕ, в том числе для hls_ouch_krnl: держать DATAFLOW ПЛОСКИМ.
 * Один регион, все стадии в нём. Вложенные регионы ломают передачу скаляров, и
 * csynth об этом не сообщает — видно только в syn/verilog.
 */

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
     // управление и телеметрия. enableA/enableB — одно значение из обёртки,
     // раздельные аргументы, чтобы у каждого был ОДИН читатель (см. шапку
     // топ-функции: один общий enable HLS раздавал половинам несимметрично).
     int enableA,
     int enableB,
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

     // stable на входных скалярах региона: снимает их синхронизацию со стартом
     // региона, значения приходят проводами из обёртки и меняются асинхронно.
     // Ровно так же помечены скаляры в epd_core у probe-ядра, где всё доезжает
     // проводами. Это ЕДИНСТВЕННАЯ граница DATAFLOW в ядре — вложенных больше
     // нет, см. комментарий выше.
#pragma HLS stable variable = enableA
#pragma HLS stable variable = enableB
#pragma HLS stable variable = listenPortA
#pragma HLS stable variable = listenPortB

     // ── состояние и внутренние потоки: раздельные на половину ──
     //
     // Именно это, а не разделение на функции, делает половины независимыми:
     // два разных объекта listenState и две пары FIFO. Раньше они жили внутри
     // функций-половин, теперь — здесь, в единственном DATAFLOW-регионе.
     static listenState st_a = {false, false, 0, 0};
     #pragma HLS RESET variable=st_a
     static listenState st_b = {false, false, 0, 0};
     #pragma HLS RESET variable=st_b

     // Состояние notify/drain — тоже раздельное на половину, по той же причине
     // (см. notifyState/drainState_t): в плоском DATAFLOW две стадии не могут
     // делить static, HLS отвергает это как feedback dependence.
     static notifyState ns_a = {0};
     #pragma HLS RESET variable=ns_a
     static notifyState ns_b = {0};
     #pragma HLS RESET variable=ns_b

     static drainState_t ds_a = {drainState_t::IDLE};
     #pragma HLS RESET variable=ds_a
     static drainState_t ds_b = {drainState_t::IDLE};
     #pragma HLS RESET variable=ds_b

     static hls::stream<ap_uint<16> > rxSessionFifo_a("rxSessionFifo_a");
     #pragma HLS STREAM variable=rxSessionFifo_a depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_a("rxLengthFifo_a");
     #pragma HLS STREAM variable=rxLengthFifo_a depth=512
     static hls::stream<ap_uint<16> > rxSessionFifo_b("rxSessionFifo_b");
     #pragma HLS STREAM variable=rxSessionFifo_b depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo_b("rxLengthFifo_b");
     #pragma HLS STREAM variable=rxLengthFifo_b depth=512

     // ── шесть стадий ПЛОСКО, по три на половину ──
     //
     // Ни одного вложенного DATAFLOW: скаляры (enableA/B, listenPortA/B)
     // пересекают одну границу региона и остаются проводами. См. большой
     // комментарий выше о том, что было при вложенности.

     // половина a -> network_krnl_1 (QSFP0)
     dual_echo_listen(enableA, listenPortA, st_a, listenAttempts_a, portState_a,
                      m_axis_tcp_listen_port_a, s_axis_tcp_port_status_a);

     dual_echo_rx_notify(ns_a, notifyCount_a,
                         s_axis_tcp_notification_a, m_axis_tcp_read_pkg_a,
                         rxSessionFifo_a, rxLengthFifo_a);

     dual_echo_rx_drain(ds_a, s_axis_tcp_rx_meta_a, s_axis_tcp_rx_data_a,
                        rxSessionFifo_a, rxLengthFifo_a);

     // половина b -> network_krnl_2 (QSFP1)
     dual_echo_listen(enableB, listenPortB, st_b, listenAttempts_b, portState_b,
                      m_axis_tcp_listen_port_b, s_axis_tcp_port_status_b);

     dual_echo_rx_notify(ns_b, notifyCount_b,
                         s_axis_tcp_notification_b, m_axis_tcp_read_pkg_b,
                         rxSessionFifo_b, rxLengthFifo_b);

     dual_echo_rx_drain(ds_b, s_axis_tcp_rx_meta_b, s_axis_tcp_rx_data_b,
                        rxSessionFifo_b, rxLengthFifo_b);

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

               // ── enable: ДВА аргумента на одно значение ──
               //
               // Обёртка подаёт на оба один и тот же регистр (0x10), так что
               // снаружи это по-прежнему ОДИН enable — адресная карта и
               // jtag_ctrl.tcl не меняются.
               //
               // ЗАЧЕМ РАЗДЕЛЕНО. Пока это был один аргумент, его читали ОБЕ
               // половины, и HLS раздал его НЕСИММЕТРИЧНО (проверено в
               // сгенерированном RTL, dual_echo_core.v):
               //
               //     .enable(empty_176)              <- половине a провод
               //     .enable_dout(p_c_dout)          <- половине b FIFO p_c_U
               //     .enable_empty_n(p_c_empty_n)
               //     .enable_read(...)
               //
               // Половина b блокировалась на пустом канале, а через
               // ap_ready/ap_continue DATAFLOW-региона вставала и половина a.
               // Симптом на плате: регистры живые, enable=1 читается, а
               // listenAttempts=0 и вся телеметрия нули НАВСЕГДА. Ядро не
               // исполнялось ни в одной половине.
               //
               // Теперь у каждого аргумента ОДИН читатель — размножать нечего,
               // и независимость стала свойством кода, а не расписания HLS.
               // Тот же дефект был у probe-ядра со скаляром cycleCount.
               int enableA,
               int enableB)
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

// ─────────────────────────────────────────────────────────────────────────────
// DATAFLOW НА ТОП-ФУНКЦИИ — БЕЗ ЭТОЙ СТРОКИ СКАЛЯРЫ НЕ ДОХОДЯТ.
//
// Без неё HLS строит для топ-функции обычный автомат, и на входе КАЖДОГО
// скаляра появляется буфер с рукопожатием, подтверждение которого привязано к
// состоянию этого автомата (проверено в сгенерированном
// hls_dual_echo_krnl.v):
//
//     reg [31:0] enableA_0_data_reg;
//     reg        enableA_0_vld_reg;
//     reg        enableA_0_ack_out;
//
//     if ((ack_out == 1 & vld_reg == 1) | (vld_reg == 0))
//         enableA_0_data_reg <= enableA;          // защёлка
//
//     if ((1'b1 == ap_CS_fsm_state2) | ...)
//         enableA_0_ack_out = 1'b1;               // <-- ЗАВИСИТ ОТ state2
//
// При ap_ctrl_none автомат проходит state2 РОВНО ОДИН РАЗ, сразу после снятия
// сброса. Значит ack_out поднимается однажды, буфер защёлкивает то, что было на
// входе в тот момент (нули — хост по JTAG ещё ничего не записал), и больше
// НИКОГДА не обновляется. Это буквально тот же state2-баг, из-за которого
// затевалась HDL-обёртка (см. шапку файла), только на уровень выше: обёртка
// довозит значение до порта ядра, а внутри оно застревает в буфере.
//
// Симптом на плате, стоивший половины сессии: регистры живые, enable=1
// читается обратно, listenPortA/B подтверждаются — а listenAttempts=0 и вся
// телеметрия нули НАВСЕГДА.
//
// С DATAFLOW на топ-функции автомата с state2 не возникает: регион течёт,
// и скаляры проходят проводами. Образец — hls_echo_probe_dual_krnl, у которого
// эта строка есть и в чьём RTL grep "_0_data_reg" не находит НИЧЕГО.
//
// НЕ УБИРАТЬ. Без неё сборка проходит без единой ошибки и csynth молчит.
// ─────────────────────────────────────────────────────────────────────────────
#pragma HLS DATAFLOW disable_start_propagation

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
#pragma HLS INTERFACE ap_none register port = enableA
#pragma HLS INTERFACE ap_none register port = enableB
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

                    enableA, enableB, listenPortA, listenPortB,
                    listenAttempts_a, portState_a, notifyCount_a,
                    listenAttempts_b, portState_b, notifyCount_b);
}
}
