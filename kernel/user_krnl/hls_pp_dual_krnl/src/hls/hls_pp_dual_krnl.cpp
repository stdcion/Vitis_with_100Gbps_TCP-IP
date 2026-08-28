/************************************************
TCP-эхо на половине a, приёмник на половине b.

ЧТО ЭТО И ЗАЧЕМ.

Первое ядро, которое ОТДАЁТ данные обратно в сеть. До него на этой плате
работали только приёмники: фазы 1-3 лестницы hls_recv_dual_krnl прошли
зелёными, но TX-путь стека в них стоял на tie_off_tcp_tx и не проверялся
ни разу.

Ядро собрано так, чтобы новый код был только там, где без него нельзя:

  обвязка, порты, pragma, половина b  -- дословно из hls_recv_dual_krnl
                                         (фаза 3, коммит 4e45d13, зелёная
                                         на плате 25.08)
  pp_echo                             -- дословно из hls_pingpong_krnl
                                         плюс два выходных скаляра
  pp_listen                           -- оттуда же, с двумя правками

Всё остальное -- копия того, что уже работало.

ПОЧЕМУ ЭХО ТРЕБУЕТ ИМЕННО ТАКОЙ ПОСЛЕДОВАТЕЛЬНОСТИ.

Прочитано в tx_app_stream_if.cpp: tasi_metaLoader на каждый tx_meta
отвечает одним словом в appTxDataRsp (наш s_axis_tcp_tx_status) и ТОЛЬКО
при NO_ERROR выдаёт tasi_meta2pkgPushCmd -- команду, по которой данные
вообще начнут читаться.

При TCP_NODELAY=1 (значение по умолчанию, наша сборка его не меняет)
toe_duplicate_stream кладёт каждое слово в ДВА потока по 1024 слова:
tasi_dataFifo и txApp2txEng_data_stream. Оба читаются автоматами, которые
ждут команду. Если tx_meta получил ошибку, команды нет НИ ДЛЯ ОДНОГО из
них, а залитые слова остаются в обоих FIFO навсегда. Следующий успешный
tx_meta выдаст команду -- и автомат отправит СТАРЫЕ слова. Это не потеря
пакета, а сдвиг всего потока на одно сообщение, без восстановления.

Отсюда порядок, отступать от которого нельзя:

    tx_meta -> ЖДАТЬ tx_status -> только при error==0 лить данные

Store-and-forward здесь не осторожность, а требование протокола: данные
надо где-то держать, пока ждём ответа. Поэтому payload[] в BRAM.

ЧТО ИЗМЕРЯЕМ ЭТИМ ЗАПУСКОМ.

Только одно: работает ли эхо. Врезки времени намеренно нет -- она
требует правки axis_net между network_krnl и CMAC, то есть риска задеть
то, что уже работает. Задержка меряется вторым заходом, когда эхо
подтверждено. RTT этого запуска снимается tcpdump'ом на хосте.

ТЕЛЕМЕТРИЯ: ТРИ СКАЛЯРА, НЕ БОЛЬШЕ.

Их отсутствие -- ровно то, что стоило недели на dual_echo: ядро молчало,
и по молчанию нельзя было понять, на каком шаге оно встало.

  portState   0 = не запрашивали, 1 = запрос отправлен, 2 = порт открыт
  ppState     сырое состояние FSM эха: на каком шаге стоит
  notifyCount сколько уведомлений о данных дошло до ядра

ppState -- главный из трёх. Он не проверяет гипотезу, а прямо показывает
шаг: STATUS = стек не ответил на tx_meta, RX = данные не пришли,
NOTIFY = уведомления нет. Каждое значение -- однозначный вывод.

Скаляры отдаются присваиванием в конце стадии. Что это работает при
ap_ctrl_hs, проверено на dual_echo: listenAttempts и portState читались
с платы, когда всё остальное молчало.

СХЕМА ЗАПУСКА: кабель в QSFP0, половина a слушает 7001 и отражает,
половина b -- как в фазе 3 (listenPorts + recvData), кабель в неё НЕ
включён. Половина b здесь только чтобы отличие от фазы 3 было
минимальным: если эхо не заработает, причина не в том, что мы заодно
убрали вторую половину.
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Максимальный размер сообщения в 64-байтных словах (64 * 64 = 4096 байт).
// Совпадает с MSS стека по умолчанию (FNS_TCP_STACK_MSS=4096), поэтому
// один TCP-сегмент всегда влезает в буфер целиком.
//
// ДОЛЖНО БЫТЬ СТЕПЕНЬЮ ДВОЙКИ: в TX используется маска
// (wordIdx & (PP_MAX_WORDS-1)) как защита от выхода за границу BRAM.
#define PP_MAX_WORDS 64
static_assert((PP_MAX_WORDS & (PP_MAX_WORDS - 1)) == 0,
              "PP_MAX_WORDS must be a power of two (see mask in TX)");

/*
 * Открывает listen-порт, повторяя запрос до подтверждения стека.
 *
 * ОДНА ПРАВКА ОТНОСИТЕЛЬНО pp_listen ИЗ hls_pingpong_krnl: portState
 * наружу. Без него "соединение не устанавливается" не отличить от "порт не
 * открылся", а это первое, что надо знать с платы.
 *
 * ЗАПИСЬ БЛОКИРУЮЩАЯ, БЕЗ full() -- И ЭТО СОЗНАТЕЛЬНО.
 *
 * Сначала я поставил здесь проверку full(), считая её бесплатной
 * страховкой. csynth показал цену: II Violation 200-880, carried
 * dependence между full() и write() по одному порту, Final II = 2 вместо 1.
 *
 * Сравнение с логом csynth РАБОТАЮЩЕГО hls_recv_dual_krnl (25.08, фаза 3
 * зелёная на плате) показало, что это ЕДИНСТВЕННОЕ расхождение с эталоном:
 *
 *   Fmax               259.20 МГц   ==   259.20 МГц
 *   HLS 200-471        2 issue(s)   ==   2 issue(s)   (оба в апстримных
 *                                                     sendDataPtr/recvDataPtr,
 *                                                     которые не вызываются)
 *   HLS 200-656        есть         ==   есть         (на апстримном
 *                                                     port_status_handler тоже)
 *   ap_ctrl            s_axilite+hs ==   s_axilite+hs
 *   II Violation       НЕТ          !=   1 (pp_listen)   <-- только у нас
 *
 * Смешанный II в DATAFLOW-регионе -- ровно то, что убивало регион раньше:
 * ap_sync_done требует ap_done всех стадий в ОДНОМ такте. Под ap_ctrl_hs
 * это не должно мешать, но проверять такое на плате при одной попытке в
 * сутки -- плохая сделка, когда цена устранения три строки.
 *
 * Риск блокирующей записи здесь минимальный: pp_listen пишет ОДИН пакет за
 * всю жизнь ядра, и FIFO listen-порта к этому моменту пуст. Апстримный
 * server() в iperf_client.cpp:405 пишет так же и работает на этом железе.
 *
 * ФОРМА СТАДИИ -- КАК У АПСТРИМА. iperf_client.cpp:386 server(): тот же
 * автомат, PIPELINE II=1, INLINE off, неблокирующее чтение через empty(),
 * и после открытия порта шина port_status больше не читается.
 */
void pp_listen(int listenPort,
               ap_uint<32>& portState,
               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portOpened = false;
#pragma HLS RESET variable=portOpened
     static ap_uint<32> attempts = 0;

     // RESET ТОЛЬКО НА portOpened, НЕ НА attempts -- ТАК ЖЕ, КАК В АПСТРИМЕ.
     //
     // По умолчанию HLS сбрасывает по ap_rst только управляющие регистры
     // (ap_CS_fsm, ap_done_reg, ap_start_reg) -- проверено по
     // сгенерированному RTL работающего recv_krnl: в reset-блоках его стадий
     // нет НИ ОДНОЙ пользовательской переменной. Значение `= false` попадает
     // лишь в initial/битстрим, то есть после перезапуска ядра (не пересборки)
     // portOpened сохранит старое значение и порт не будет запрошен заново.
     //
     // attempts оставлен без RESET сознательно: это счётчик телеметрии, а не
     // состояние автомата. Апстрим (iperf_client server()) ставит RESET
     // ровно на один регистр состояния -- listenState -- и ни на один из
     // остальных static. На весь сетевой стек там 1 RESET при 1023 static.

     // ЗАПРОС ПОВТОРЯЕТСЯ КАЖДЫЙ ПРОХОД, ПОКА ПОРТ НЕ ОТКРЫТ.
     //
     // Первая версия писала порт РОВНО ОДИН РАЗ (static portRequested), и это
     // отличало её от апстрима -- у него listen_port_handler это `for` без
     // состояния, то есть при auto_restart порт запрашивается СНОВА на каждом
     // перезапуске региона, пока стек не подтвердит.
     //
     // ПОЧЕМУ ЭТО ВАЖНО. Хост стартует ядро (0x81) после network_start, но
     // "стек запущен" не значит "TOE готов принять listen": ему нужно время на
     // инициализацию таблиц в DDR. Если единственный запрос пришёл в это окно,
     // второй попытки не будет никогда, и portState навсегда останется 1.
     //
     // Прогон на плате 25.08 дал ровно эту картину: connection refused на
     // 7001, то есть стек ответил RST -- он жив и обрабатывает пакет, а порт
     // не зарегистрирован.
     //
     // ПОВТОР БЕЗОПАСЕН, проверено по коду TOE. port_table.cpp:63-70 на
     // запрос уже открытого порта отвечает true, а не отказом:
     //
     //     if (listeningPortTable[port]) portTable2rxApp_listen_rsp.write(true);
     //
     // То есть лишние запросы ничего не портят.
     if (!portOpened)
     {
          if (!m_axis_tcp_listen_port.full())
          {
               pkt16 listen_port_pkt;
               listen_port_pkt.data(15, 0) = listenPort;
               m_axis_tcp_listen_port.write(listen_port_pkt);
               attempts++;
          }

          // Ответ читаем в том же проходе, если он уже есть. Неблокирующе:
          // стек отвечает через десятки тактов, а стадия обязана вернуться.
          if (!s_axis_tcp_port_status.empty())
          {
               pkt8 status_pkt = s_axis_tcp_port_status.read();
               if (status_pkt.data(0, 0)) portOpened = true;
          }
     }

     // portState: 0 -- ни одной попытки (стадия не работает вовсе),
     //            1 -- запросы идут, подтверждения нет,
     //            2 -- порт открыт.
     //
     // Ноль теперь означает ровно одно: стадия не запускается. Это отличает
     // "ядро мёртвое" от "стек не отвечает", чего первая версия не давала.
     portState = portOpened ? (ap_uint<32>)2
                            : (attempts > 0 ? (ap_uint<32>)1 : (ap_uint<32>)0);
}

/*
 * Echo-конвейер одним FSM. Из hls_pingpong_krnl БЕЗ ИЗМЕНЕНИЙ логики;
 * добавлены только ppState и notifyCount наружу.
 *
 * NOTIFY : пришло уведомление -> выставляем read request
 * META   : забираем rx_meta
 * RX     : читаем слова в буфер до флага last
 * REQ    : выставляем tx_meta на ту же длину и ту же сессию
 * STATUS : ждём подтверждения стека
 * TX     : отдаём буфер обратно
 *
 * Store-and-forward: сообщение принимается целиком, потом отправляется.
 * Иначе нельзя -- см. разбор tx_app_stream_if в шапке файла.
 *
 * static-переменные здесь безопасны: функция вызывается ОДИН раз. Когда
 * в dual_echo такую же стадию вызвали дважды в одном DATAFLOW-регионе,
 * HLS отказался синтезировать (HLS 200-471, feedback dependence on
 * static). Половина b использует апстримный recvData, своего эха у неё
 * нет, поэтому выносить состояние в структуру не требуется.
 */
void pp_echo(ap_uint<32>& ppStateOut,
             ap_uint<32>& notifyCount,
             hls::stream<pkt128>& s_axis_tcp_notification,
             hls::stream<pkt32>& m_axis_tcp_read_pkg,
             hls::stream<pkt16>& s_axis_tcp_rx_meta,
             hls::stream<pkt512>& s_axis_tcp_rx_data,
             hls::stream<pkt32>& m_axis_tcp_tx_meta,
             hls::stream<pkt512>& m_axis_tcp_tx_data,
             hls::stream<pkt64>& s_axis_tcp_tx_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     // ПОРЯДОК ЭТОГО enum -- ЧИСЛА, КОТОРЫЕ ЧИТАЮТСЯ С ПЛАТЫ.
     //
     // ppState отдаётся наружу как есть, поэтому значения зашиты ещё в ДВУХ
     // местах, и при правке порядка их надо менять вместе:
     //
     //   scripts/vivado/jtag_ctrl.tcl   proc _pp_state_name  -- расшифровка
     //                                  в pp_dual_dump
     //   host/hls_pp_dual_krnl/main.go  подсказка при "эхо не пришло"
     //
     // Разъехавшись, они будут называть НЕ ТОТ шаг, а именно по этому числу
     // мы и решаем, где искать дефект. Проверка на согласованность --
     // сравнить руками, автоматической нет.
     enum ppStateType {NOTIFY, META, RX, REQ, STATUS, TX};
     static ppStateType ppState = NOTIFY;
#pragma HLS RESET variable=ppState

     // ОДИН RESET, И ТОЛЬКО НА ppState -- ЭТО НЕ ЭКОНОМИЯ, А ПРОВЕРЕННОЕ ПРАВИЛО.
     //
     // Апстрим (iperf_client server()) ставит RESET ровно на listenState и ни
     // на одну переменную данных; на весь сетевой стек 1 RESET при 1023 static.
     //
     // Почему этого достаточно здесь: КАЖДАЯ переменная ниже записывается при
     // ВХОДЕ в своё состояние раньше, чем читается. sessionID/msgLength/
     // wordCount пишутся в NOTIFY, txLength в REQ, wordIdx/bytesRemaining в
     // STATUS перед переходом в TX. Поэтому после сброса ppState в NOTIFY их
     // прежние значения недостижимы -- мусор в них не наблюдаем.
     //
     // ppState же читается ПЕРВЫМ (switch) до любой записи, поэтому без RESET
     // ядро после перезапуска могло бы стартовать посреди TX и погнать в стек
     // мусор из payload[] под чужим sessionID.
     //
     // payload[] (BRAM) не сбрасывается принципиально: RESET на массив
     // развернулся бы в цикл обнуления на 64 такта и сломал бы II=1.

     static ap_uint<512> payload[PP_MAX_WORDS];
#pragma HLS BIND_STORAGE variable=payload type=RAM_2P impl=BRAM

     static ap_uint<16> sessionID = 0;
     static ap_uint<16> msgLength = 0;    // обещано уведомлением
     static ap_uint<16> txLength = 0;     // фактически отражаем
     static ap_uint<16> wordCount = 0;    // сохранено в payload[]
     static ap_uint<16> wordIdx = 0;
     static ap_uint<16> bytesRemaining = 0;
     static ap_uint<32> notifications = 0;

     switch (ppState)
     {
     case NOTIFY:
          if (!s_axis_tcp_notification.empty())
          {
               pkt128 notification_pkt = s_axis_tcp_notification.read();
               ap_uint<16> notifLength = notification_pkt.data(31, 16);

               notifications++;

               if (notifLength != 0)
               {
                    // sessionID берём из уведомления -- так реконнекты
                    // клиента подхватываются без дополнительной логики
                    sessionID = notification_pkt.data(15, 0);

                    // Запрашиваем не больше, чем вмещает буфер.
                    //
                    // Раньше запрашивалась вся notifLength, а RX молча
                    // отбрасывал слова за PP_MAX_WORDS, продолжая
                    // считать wordCount. В TX индекс уходил за границу
                    // payload[], и эхо содержало мусор при заявленной
                    // полной длине (проверено: слова 64,65 отдавались
                    // как 0x101 вместо данных).
                    //
                    // Остаток стек отдаст следующим уведомлением --
                    // read request только подтверждает то, что заберём.
                    const ap_uint<16> maxBytes = PP_MAX_WORDS * 64;
                    msgLength = (notifLength > maxBytes) ? maxBytes : notifLength;

                    pkt32 readRequest_pkt;
                    readRequest_pkt.data(15, 0) = sessionID;
                    readRequest_pkt.data(31, 16) = msgLength;
                    m_axis_tcp_read_pkg.write(readRequest_pkt);

                    wordCount = 0;
                    ppState = META;
               }
          }
          break;

     case META:
          if (!s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               ppState = RX;
          }
          break;

     case RX:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();
               // Слова сверх буфера отбрасываем, но и НЕ засчитываем:
               // wordCount задаёт, сколько слов отдаст TX, поэтому он
               // не должен превышать число реально сохранённых.
               if (wordCount < PP_MAX_WORDS)
               {
                    payload[wordCount] = rx_word.data;
                    wordCount++;
               }
               if (rx_word.last)
               {
                    ppState = REQ;
               }
          }
          break;

     case REQ:
     {
          // Отражаем ровно то, что реально приняли и сохранили.
          //
          // msgLength пришла из уведомления, wordCount -- факт приёма.
          // Если стек отдал меньше слов, чем обещал (или больше, чем
          // вместил буфер), доверять надо факту: иначе tx_meta заявит
          // длину, под которую нет данных, и стек будет ждать слова,
          // которых ядро не отдаст.
          ap_uint<16> wordBytes = (ap_uint<16>)(wordCount * 64);
          txLength = (msgLength < wordBytes) ? msgLength : wordBytes;

          pkt32 tx_meta_pkt;
          tx_meta_pkt.data(15, 0) = sessionID;
          tx_meta_pkt.data(31, 16) = txLength;
          m_axis_tcp_tx_meta.write(tx_meta_pkt);
          ppState = STATUS;
          break;
     }

     case STATUS:
          if (!s_axis_tcp_tx_status.empty())
          {
               pkt64 status_pkt = s_axis_tcp_tx_status.read();
               ap_uint<2> error = status_pkt.data(63, 62);

               if (error == 0)
               {
                    wordIdx = 0;
                    bytesRemaining = txLength;
                    ppState = TX;
               }
               else if (error == 1)
               {
                    // соединение разорвано -- ждём следующего сообщения
                    ppState = NOTIFY;
               }
               else
               {
                    // нет места в буфере получателя -- повторяем запрос.
                    // Данные ЛИТЬ НЕЛЬЗЯ: команды pkgPush стек не выдал,
                    // слова осели бы в двух FIFO и сдвинули весь поток.
                    ppState = REQ;
               }
          }
          break;

     case TX:
     {
          pkt512 tx_word;
          // Индекс не может выйти за буфер: wordCount ограничен
          // PP_MAX_WORDS в RX. Маска -- страховка на случай будущих
          // правок, чтобы чтение за границей BRAM не появилось снова.
          tx_word.data = payload[wordIdx & (PP_MAX_WORDS - 1)];

          // в последнем слове валидны только оставшиеся байты
          ap_uint<7> validBytes = (bytesRemaining >= 64) ? (ap_uint<7>)64
                                                         : (ap_uint<7>)bytesRemaining;
          for (int b = 0; b < 64; b++)
          {
          #pragma HLS UNROLL
               tx_word.keep(b, b) = (b < validBytes) ? 1 : 0;
          }
          bytesRemaining = (bytesRemaining >= 64) ? (ap_uint<16>)(bytesRemaining - 64)
                                                  : (ap_uint<16>)0;

          wordIdx++;
          tx_word.last = (wordIdx == wordCount);
          m_axis_tcp_tx_data.write(tx_word);

          if (tx_word.last)
          {
               ppState = NOTIFY;
          }
          break;
     }
     }

     // Телеметрия -- безусловно, каждый проход: так HLS создаёт теневой
     // регистр *_preg и держит значение между обновлениями.
     ppStateOut  = (ap_uint<32>)ppState;
     notifyCount = notifications;
}


extern "C" {
void hls_pp_dual_krnl(
               // ── канал a -> network_krnl_1 (QSFP0): ЭХО ──

               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status,
               hls::stream<pkt128>& s_axis_tcp_notification,
               hls::stream<pkt32>& m_axis_tcp_read_pkg,
               hls::stream<pkt16>& s_axis_tcp_rx_meta,
               hls::stream<pkt512>& s_axis_tcp_rx_data,
               hls::stream<pkt32>& m_axis_tcp_tx_meta,
               hls::stream<pkt512>& m_axis_tcp_tx_data,
               hls::stream<pkt64>& s_axis_tcp_tx_status,
               // ── канал b -> network_krnl_2 (QSFP1): как в фазе 3 ──

               int useConn,
               int basePort,
               ap_uint<64> expectedRxByteCnt,
               ap_uint<32>& portState,
               ap_uint<32>& ppState,
               ap_uint<32>& notifyCount
                      ) {


#pragma HLS INTERFACE axis port = m_axis_tcp_listen_port
#pragma HLS INTERFACE axis port = s_axis_tcp_port_status
#pragma HLS INTERFACE axis port = s_axis_tcp_notification
#pragma HLS INTERFACE axis port = m_axis_tcp_read_pkg
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_meta
#pragma HLS INTERFACE axis port = s_axis_tcp_rx_data
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_meta
#pragma HLS INTERFACE axis port = m_axis_tcp_tx_data
#pragma HLS INTERFACE axis port = s_axis_tcp_tx_status

#pragma HLS INTERFACE s_axilite port=useConn bundle = control
#pragma HLS INTERFACE s_axilite port=basePort bundle = control
#pragma HLS INTERFACE s_axilite port=expectedRxByteCnt bundle = control
#pragma HLS INTERFACE s_axilite port=portState bundle = control
#pragma HLS INTERFACE s_axilite port=ppState bundle = control
#pragma HLS INTERFACE s_axilite port=notifyCount bundle = control
#pragma HLS INTERFACE s_axilite port = return bundle = control

#pragma HLS dataflow

          // ── канал a: ЭХО. basePort как listenPort -- одна половина
          // слушает один порт, useConn на канале a не применяется.
          pp_listen(basePort, portState,
               m_axis_tcp_listen_port,
               s_axis_tcp_port_status);

          pp_echo(ppState, notifyCount,
               s_axis_tcp_notification,
               m_axis_tcp_read_pkg,
               s_axis_tcp_rx_meta,
               s_axis_tcp_rx_data,
               m_axis_tcp_tx_meta,
               m_axis_tcp_tx_data,
               s_axis_tcp_tx_status);

          // ── ЗАГЛУШЕК ЗДЕСЬ БОЛЬШЕ НЕТ. ОНИ В RTL-ОБЁРТКЕ ──────────────
          //
          // Раньше тут стояли шесть tie_off_* из communication.hpp. Они и
          // оказались причиной отказа 27.08: плата выпустила 3000 SYN к
          // 0.0.0.0 и 513 ARP, TOE утонул в мусорных сессиях и на настоящий
          // SYN от ПК сессии не осталось.
          //
          // ПОЧЕМУ tie_off ПИШЕТ В СТЕК. Каждая объявляет ЛОКАЛЬНЫЙ поток и
          // проверяет его на пустоту:
          //
          //     hls::stream<ipTuple> openConnection;      // никто не пишет
          //     if (!openConnection.empty())              // должно быть false
          //          m_axis_tcp_open_connection.write(...);
          //
          // У потока нет производителя (HLS предупреждает XFORM 203-731), и он
          // схлопывается в константы -- проверено по сгенерированному RTL:
          //
          //     assign openConnection_dout    = 48'd0;
          //     assign openConnection_empty_n = 1'b1;   // "НЕ пуст" ВСЕГДА
          //
          // То есть empty() всегда false, условие выполняется каждый проход, и
          // стадия просит стек открыть соединение к 0.0.0.0:0.
          //
          // ПОЧЕМУ У АПСТРИМНОГО recv_krnl ТО ЖЕ САМОЕ И ОН РАБОТАЕТ. Там в
          // регионе висит recvData, поэтому
          //     ap_sync_ready = AND(готовность всех стадий)
          // никогда не поднимается, ap_sync_reg не сбрасывается и
          //     stage_ap_start = (~ap_sync_reg) & ap_start
          // остаётся нулём. Стадии запускаются РОВНО ОДИН РАЗ -- один мусорный
          // SYN за всё время, его никто не замечает.
          //
          // Убрав висящую половину b, я включил барьер -- и вместе с
          // pp_listen/pp_echo начали перезапускаться шесть заглушек. То есть
          // поток мусора создало предыдущее исправление, а не сами tie_off.
          //
          // КАК ДЕЛАЕТ АПСТРИМ. iperf_client не использует tie_off вообще: у
          // него в сигнатуре нет ни одного лишнего потока, а неиспользуемые
          // порты заглушены КОНСТАНТАМИ В RTL-ОБЁРТКЕ
          // (kernel/user_krnl/iperf_krnl/src/hdl/user_krnl.sv:239):
          //
          //     assign s_axis_udp_rx_tready = 1'b1;   // принимай и выбрасывай
          //     assign m_axis_udp_tx_tvalid = 1'b0;   // не передавай НИКОГДА
          //
          // Константа в барьере не участвует, перезапускать нечего, отправить
          // пакет физически невозможно. Мы делаем так же -- см. блок
          // "заглушки неиспользуемых портов" в hls_pp_dual_krnl_wrapper.sv.

     }
}
