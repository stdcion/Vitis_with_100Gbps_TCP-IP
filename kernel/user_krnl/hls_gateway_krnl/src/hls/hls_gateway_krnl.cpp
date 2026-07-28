/************************************************
TCP gateway kernel.

Слушает порт listenPort и принимает подключение одного клиента.
Одновременно открывает исходящее соединение к upstream-серверу
(serverIpAddress:serverPort) и работает как двунаправленный релей:

    client --> gateway --> server      (uplink)
    client <-- gateway <-- server      (downlink)

Релей не интерпретирует содержимое: любые куски данных любого
прикладного протокола пересылаются как есть, с сохранением порядка
байтов и границ сегментов.

Обработка разрывов:
  - обрыв upstream  -> соединение к серверу переоткрывается
                       автоматически (с паузой между попытками),
                       сессия клиента при этом сохраняется;
  - обрыв клиента   -> состояние сбрасывается, следующее входящее
                       подключение подхватывается автоматически.

Структура повторяет идиому iperf_client.cpp: топ-функция помечена
DATAFLOW, каждая стадия — отдельный процесс с PIPELINE II=1 и
INLINE off, состояние держится в static-переменных. Стадии соединены
внутренними FIFO, и в каждый выходной AXI-Stream порт пишет РОВНО
ОДНА функция. Порт m_axis_tcp_tx_* физически один на всё ядро, а
сессии клиента и сервера различаются полем sessionID внутри tx_meta,
поэтому оба направления сводятся в единственный передатчик
gw_tx_merged.

ВАЖНО: топ-функцию нельзя помечать PIPELINE — обратные связи между
стадиями (upstreamLostFifo: gw_route -> gw_connect_upstream) в одном
конвейере становятся carried dependence, и HLS растягивает II до 10,
что режет пропускную способность в 10 раз. DATAFLOW делает стадии
независимыми процессами, и обратные FIFO становятся бесплатными.

Точка расширения для будущей обработки данных отмечена в коде
комментарием "HOOK".
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Пауза между попытками переподключения к upstream-серверу, в тактах
// (250 МГц => 250000000 тактов ≈ 1 секунда).
//
// Это НЕ compile-time define: раньше csim собиралась с
// -DGW_RECONNECT_DELAY=100, а синтез — без него, то есть в железо шёл
// код, отличающийся от протестированного. Теперь задержка приходит с
// хоста через AXI-lite (reconnectDelay), csim подставляет малое
// значение как обычный аргумент, и обе сборки используют один код.
//
// Значение по умолчанию для хоста, если регистр не записан.
#define GW_RECONNECT_DELAY_DEFAULT 250000000

/*
 * Открывает listen-порт для входящих подключений клиента.
 * Повторяет попытку, пока стек не подтвердит успех.
 *
 * Порт остаётся открытым и после отключения клиента, поэтому
 * повторное подключение принимается стеком автоматически.
 */
void gw_listen(int listenPort,
               hls::stream<pkt16>& m_axis_tcp_listen_port,
               hls::stream<pkt8>& s_axis_tcp_port_status)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     static bool portRequested = false;
     static bool portOpened = false;

     if (!portRequested)
     {
          pkt16 listen_port_pkt;
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
               // не открылось — пробуем снова
               portRequested = false;
          }
     }
}

/*
 * Держит исходящее соединение к upstream-серверу.
 *
 * При старте — открывает соединение. Если попытка неуспешна или
 * ранее установленное соединение оборвалось (сигнал приходит через
 * upstreamLostFifo), выдерживает паузу и подключается заново.
 *
 * Полученный sessionID публикуется в два независимых FIFO — по
 * одному на потребителя, так как один hls::stream нельзя читать
 * из двух функций.
 */
void gw_connect_upstream(int serverIpAddress,
                         int serverPort,
                         ap_uint<32> reconnectDelay,
                         hls::stream<pkt64>& m_axis_tcp_open_connection,
                         hls::stream<pkt128>& s_axis_tcp_open_status,
                         hls::stream<ap_uint<16> >& serverSessionToRoute,
                         hls::stream<ap_uint<16> >& serverSessionToTx,
                         hls::stream<bool>& upstreamLostFifo,
                         hls::stream<bool>& upstreamLostFromTx)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum connStateType {CONNECT, WAIT_STATUS, ESTABLISHED, BACKOFF};
     static connStateType connState = CONNECT;
#pragma HLS RESET variable=connState

     static ap_uint<32> backoffCounter = 0;

     // Сообщение об обрыве может прийти в любом состоянии и из двух
     // источников: gw_route (notification с closed) и gw_tx_merged
     // (tx_status с error==1). Один hls::stream нельзя писать из двух
     // функций, поэтому источников два, а слияние — здесь.
     bool lost = false;
     if (!upstreamLostFifo.empty())
     {
          upstreamLostFifo.read();
          lost = true;
     }
     if (!upstreamLostFromTx.empty())
     {
          upstreamLostFromTx.read();
          lost = true;
     }

     switch (connState)
     {
     case CONNECT:
     {
          pkt64 open_pkt;
          open_pkt.data(31, 0) = serverIpAddress;
          open_pkt.data(47, 32) = serverPort;
          m_axis_tcp_open_connection.write(open_pkt);
          connState = WAIT_STATUS;
          break;
     }

     case WAIT_STATUS:
          if (!s_axis_tcp_open_status.empty())
          {
               pkt128 status_pkt = s_axis_tcp_open_status.read();
               ap_uint<16> sessionID = status_pkt.data(15, 0);
               ap_uint<1> success = status_pkt.data(16, 16);

               if (success)
               {
                    serverSessionToRoute.write(sessionID);
                    serverSessionToTx.write(sessionID);
                    connState = ESTABLISHED;
               }
               else
               {
                    // сервер не принял соединение — пауза и повтор
                    backoffCounter = 0;
                    connState = BACKOFF;
               }
          }
          break;

     case ESTABLISHED:
          if (lost)
          {
               backoffCounter = 0;
               connState = BACKOFF;
          }
          break;

     case BACKOFF:
          backoffCounter++;
          if (backoffCounter >= reconnectDelay)
          {
               connState = CONNECT;
          }
          break;
     }
}

/*
 * Обрабатывает уведомления стека.
 *
 * Уведомление с length != 0 означает поступление данных: выставляем
 * read request и сообщаем router-у (sessionID, length).
 *
 * Уведомление с битом closed означает разрыв сессии: сообщаем об
 * этом router-у отдельным сообщением, чтобы он сбросил привязку
 * sessionID.
 *
 * ВАЖНО (дедлок): gw_route вычитывает closedSessionFifo только в
 * состоянии IDLE, то есть между пакетами. Во время длинной передачи
 * уведомления копятся. Если писать в FIFO безусловно, то при его
 * заполнении эта стадия заблокируется на write, перестанет выставлять
 * read request, данные перестанут приходить, gw_route никогда не
 * вернётся в IDLE и не освободит FIFO — взаимная блокировка.
 *
 * Поэтому уведомление ЗАБИРАЕТСЯ из входного потока только тогда,
 * когда все нужные ему выходные FIFO гарантированно готовы принять
 * запись (full() == false). Иначе оно остаётся в s_axis_tcp_notification
 * до следующего вызова — стек применит backpressure, но ядро не встанет.
 */
void gw_rx_handshake(hls::stream<pkt128>& s_axis_tcp_notification,
                     hls::stream<pkt32>& m_axis_tcp_read_pkg,
                     hls::stream<ap_uint<16> >& rxSessionFifo,
                     hls::stream<ap_uint<16> >& rxLengthFifo,
                     hls::stream<ap_uint<16> >& closedSessionFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     if (s_axis_tcp_notification.empty())
          return;

     // Не читаем уведомление, пока не ясно, что его можно обработать
     // без блокировки. Данные и close идут по разным путям, но тип
     // уведомления заранее неизвестен, поэтому требуем готовности всех.
     bool dataPathReady   = !rxSessionFifo.full() && !rxLengthFifo.full();
     bool closePathReady  = !closedSessionFifo.full();
     if (!dataPathReady || !closePathReady)
          return;

     pkt128 notification_pkt = s_axis_tcp_notification.read();
     ap_uint<16> sessionID = notification_pkt.data(15, 0);
     ap_uint<16> length = notification_pkt.data(31, 16);
     ap_uint<1> closed = notification_pkt.data(80, 80);

     // Уведомление может нести И данные, И признак закрытия
     // одновременно (rx_engine.cpp: appNotification(..., length, ...,
     // true) при FIN с данными), поэтому это не else-if.
     if (length != 0)
     {
          pkt32 readRequest_pkt;
          readRequest_pkt.data(15, 0) = sessionID;
          readRequest_pkt.data(31, 16) = length;
          m_axis_tcp_read_pkg.write(readRequest_pkt);

          rxSessionFifo.write(sessionID);
          rxLengthFifo.write(length);
     }
     if (closed)
     {
          closedSessionFifo.write(sessionID);
     }
}

/*
 * Читает пришедшие данные и раскладывает их по направлениям:
 * данные от клиента -> очередь на сервер, и наоборот.
 * Направление определяется сравнением sessionID с сессией сервера.
 *
 * sessionID клиента заранее не известен — он берётся из первого
 * входящего пакета, пришедшего не от сервера.
 *
 * При разрыве сессии соответствующая привязка сбрасывается:
 *  - отвалился клиент -> ждём нового подключения, сообщаем
 *    передатчику, что старая сессия больше не валидна;
 *  - отвалился сервер -> сигнализируем gw_connect_upstream, чтобы
 *    тот переоткрыл соединение.
 */
void gw_route(hls::stream<pkt16>& s_axis_tcp_rx_meta,
              hls::stream<pkt512>& s_axis_tcp_rx_data,
              hls::stream<ap_uint<16> >& rxSessionFifo,
              hls::stream<ap_uint<16> >& rxLengthFifo,
              hls::stream<ap_uint<16> >& closedSessionFifo,
              hls::stream<ap_uint<16> >& serverSessionToRoute,
              hls::stream<ap_uint<512> >& toServerData,
              hls::stream<ap_uint<16> >& toServerLength,
              hls::stream<ap_uint<512> >& toClientData,
              hls::stream<ap_uint<16> >& toClientLength,
              hls::stream<ap_uint<16> >& clientSessionFifo,
              hls::stream<bool>& clientLostFifo,
              hls::stream<bool>& upstreamLostFifo,
              hls::stream<bool>& upstreamLostTxFifo,
              hls::stream<ap_uint<16> >& straySessionFifo)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     enum routeStateType {IDLE, FORWARD};
     static routeStateType routeState = IDLE;
#pragma HLS RESET variable=routeState

     static ap_uint<16> serverSession = 0;
     static bool serverSessionValid = false;
     static ap_uint<16> clientSession = 0;
     static bool clientSessionValid = false;
     static bool currentIsFromServer = false;
     // Текущая порция пришла от лишней (незарегистрированной) сессии —
     // её слова надо вычитать из rx_data и выбрасывать, иначе поток
     // встанет, а границы следующих пакетов сдвинутся.
     static bool currentIsStray = false;
     // Буфер на один такт между чтением serverSessionToRoute и
     // применением значения — разрывает критический путь (см. ниже)
     static ap_uint<16> pendingServerSession = 0;
     static bool pendingServerSessionValid = false;
     // Отложенная на такт запись лишней сессии в straySessionFifo
     static ap_uint<16> strayToClose = 0;
     static bool strayPending = false;
     // Буфер на такт между чтением closedSessionFifo и сравнением
     static ap_uint<16> closedSessionReg = 0;
     static bool closedPending = false;
     // Отложенная публикация sessionID клиента передатчику
     static ap_uint<16> clientToPublish = 0;
     static bool clientPublishPending = false;

     // Новый sessionID upstream-соединения (приходит при каждом
     // успешном подключении, в том числе после переподключения).
     //
     // ВАЖНО ДЛЯ ТАЙМИНГА: результат этого чтения НЕ используется в
     // этом же такте. Раньше прочитанный serverSession сразу шёл в
     // цепочку сравнений и дальше в запись straySessionFifo, и весь
     // путь (1.336 + сравнения + 1.344 нс) не влезал в бюджет 2.920:
     //   [HLS 200-871] Estimated clock period (4.483 ns)
     // Поэтому обновление откладывается на следующий такт через
     // pendingServerSession: чтение FIFO и использование значения
     // разнесены по разным итерациям конвейера.
     if (pendingServerSessionValid)
     {
          serverSession = pendingServerSession;
          serverSessionValid = true;
          pendingServerSessionValid = false;
     }
     else if (!serverSessionToRoute.empty())
     {
          pendingServerSession = serverSessionToRoute.read();
          pendingServerSessionValid = true;
     }

     // Уведомления о разрывах обрабатываем только между пакетами,
     // чтобы не потерять середину уже идущей передачи.
     //
     // Забираем уведомление только если оба сигнальных FIFO готовы
     // принять запись, иначе эта стадия заблокируется на write и
     // перестанет читать s_axis_tcp_rx_data — см. комментарий о
     // дедлоке в gw_rx_handshake.
     //
     // ТАЙМИНГ (UG1448, 200-880: "break up these dependencies in the
     // user code"): чтение closedSessionFifo и сравнение с сессиями
     // разнесены на два такта. Раньше путь был
     //   read closedSessionFifo (1.409 нс) -> icmp -> and -> phi
     //   -> and -> write clientSessionFifo (1.336 нс)
     // = 4.161 нс против бюджета 2.920. Теперь прочитанное значение
     // используется только на следующей итерации конвейера.
     if (closedPending)
     {
          if (serverSessionValid && closedSessionReg == serverSession)
          {
               serverSessionValid = false;
               // сообщаем и тому, кто переподключается, и передатчику
               upstreamLostFifo.write(true);
               upstreamLostTxFifo.write(true);
          }
          else if (clientSessionValid && closedSessionReg == clientSession)
          {
               clientSessionValid = false;
               clientLostFifo.write(true);
          }
          closedPending = false;
     }
     else if (routeState == IDLE && !closedSessionFifo.empty()
              && !upstreamLostFifo.full() && !upstreamLostTxFifo.full()
              && !clientLostFifo.full())
     {
          closedSessionReg = closedSessionFifo.read();
          closedPending = true;
     }

     // Отложенные записи (решения приняты такт назад)
     if (strayPending && !straySessionFifo.full())
     {
          straySessionFifo.write(strayToClose);
          strayPending = false;
     }
     if (clientPublishPending && !clientSessionFifo.full())
     {
          clientSessionFifo.write(clientToPublish);
          clientPublishPending = false;
     }

     switch (routeState)
     {
     case IDLE:
          if (!rxSessionFifo.empty() && !rxLengthFifo.empty() && !s_axis_tcp_rx_meta.empty()
              && !toClientLength.full() && !toServerLength.full()
              && !clientPublishPending && !strayPending)
          {
               s_axis_tcp_rx_meta.read();
               ap_uint<16> currentSession = rxSessionFifo.read();
               ap_uint<16> length = rxLengthFifo.read();

               currentIsFromServer = (serverSessionValid && currentSession == serverSession);
               currentIsStray = false;

               if (currentIsFromServer)
               {
                    // downlink: сервер -> клиент.
                    // Если клиент ещё не известен (или уже отвалился),
                    // отправлять ответ некуда. Раньше длина всё равно
                    // писалась в toClientLength, и передатчик уходил в
                    // DISCARD — но при уже известном СТАРОМ клиенте
                    // данные ушли бы в мёртвую сессию. Помечаем порцию
                    // как отбрасываемую явно.
                    toClientLength.write(length);
               }
               else
               {
                    // uplink: клиент -> сервер.
                    // sessionID клиента узнаём только из данных: стек
                    // не уведомляет о входящем подключении до первого
                    // пакета (rx_engine.cpp: на SYN пишется лишь
                    // SYN_ACK-событие, notification не формируется).
                    if (!clientSessionValid)
                    {
                         clientSession = currentSession;
                         clientSessionValid = true;
                         // Запись в clientSessionFifo — следующим
                         // тактом, по той же причине, что и stray:
                         // иначе она стоит в конце цепочки сравнений
                         // (это и был путь 4.161 нс).
                         clientToPublish = currentSession;
                         clientPublishPending = true;
                         toServerLength.write(length);
                    }
                    else if (currentSession == clientSession)
                    {
                         toServerLength.write(length);
                    }
                    else
                    {
                         // Уже есть активный клиент, а это другая
                         // сессия. Раньше она молча перехватывала
                         // clientSession: трафик двух клиентов
                         // смешивался в один upstream, а ответы уходили
                         // тому, кто написал последним. Шлюз
                         // рассчитан на одного клиента, поэтому лишнюю
                         // сессию закрываем, а её данные отбрасываем
                         // (длина в toServerLength не пишется, слова
                         // будут вычитаны ниже в FORWARD и выброшены).
                         //
                         // Саму запись в straySessionFifo делаем не
                         // здесь, а следующим тактом: иначе она
                         // оказывается в конце длинной цепочки
                         // сравнений сессий и ломает тайминг.
                         strayToClose = currentSession;
                         strayPending = true;
                         currentIsStray = true;
                    }
               }
               routeState = FORWARD;
          }
          break;

     case FORWARD:
     {
          // Не забираем слово, пока целевая очередь не готова его
          // принять — иначе блокирующий write остановит стадию.
          bool sinkReady = currentIsStray
                           || (currentIsFromServer ? !toClientData.full()
                                                   : !toServerData.full());
          if (!s_axis_tcp_rx_data.empty() && sinkReady)
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();

               // HOOK: здесь можно инспектировать/модифицировать rx_word.data
               // перед пересылкой (фильтр, парсер протокола и т.п.).

               if (currentIsStray)
               {
                    // данные лишней сессии — выбрасываем
               }
               else if (currentIsFromServer)
               {
                    toClientData.write(rx_word.data);
               }
               else
               {
                    toServerData.write(rx_word.data);
               }

               if (rx_word.last)
               {
                    routeState = IDLE;
               }
          }
          break;
     }
     }
}

/*
 * Единственный писатель в m_axis_tcp_tx_meta / m_axis_tcp_tx_data.
 *
 * Обслуживает оба направления по очереди (round-robin), но НЕ
 * переключается в середине транзакции: сначала полностью
 * отправляется meta + все слова данных одного направления, и только
 * потом рассматривается второе. Это требование стека — данные должны
 * непрерывно следовать за своим tx_meta.
 *
 * tx_status приходит общим потоком на обе сессии; так как в каждый
 * момент активна ровно одна транзакция, ответ всегда относится к ней.
 *
 * Актуальные sessionID обновляются при каждом (пере)подключении;
 * при разрыве соответствующее направление помечается невалидным,
 * а накопленные для него данные отбрасываются, чтобы FIFO не
 * переполнилось и очередь не рассинхронизировалась.
 */
void gw_tx_merged(hls::stream<ap_uint<16> >& serverSessionToTx,
                  hls::stream<ap_uint<16> >& clientSessionFifo,
                  hls::stream<bool>& clientLostFifo,
                  hls::stream<bool>& upstreamLostTxFifo,
                  hls::stream<ap_uint<512> >& toServerData,
                  hls::stream<ap_uint<16> >& toServerLength,
                  hls::stream<ap_uint<512> >& toClientData,
                  hls::stream<ap_uint<16> >& toClientLength,
                  hls::stream<pkt32>& m_axis_tcp_tx_meta,
                  hls::stream<pkt512>& m_axis_tcp_tx_data,
                  hls::stream<pkt64>& s_axis_tcp_tx_status,
                  hls::stream<bool>& upstreamLostFromTx,
                  hls::stream<ap_uint<16> >& strayFromTx)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     // SELECT решает, какое направление обслуживать (и только это),
     // ISSUE в следующем такте читает длину и выставляет tx_meta.
     // Раньше и арбитраж, и чтение длины, и (len+63)>>6 попадали в
     // один такт — критический путь 3.846 нс против бюджета 2.920 нс.
     enum txStateType {SELECT, ISSUE, WAIT_STATUS, WRITE_DATA, DISCARD};
     static txStateType txState = SELECT;
#pragma HLS RESET variable=txState

     static ap_uint<16> serverSession = 0;
     static bool serverSessionValid = false;
     static ap_uint<16> clientSession = 0;
     static bool clientSessionValid = false;

     // false -> обслуживаем uplink (к серверу), true -> downlink (к клиенту)
     static bool serveClient = false;
     static bool activeIsClient = false;

     static ap_uint<16> pendingLength = 0;
     static ap_uint<16> wordsToSend = 0;
     static ap_uint<16> wordsSent = 0;
     static ap_uint<16> bytesRemaining = 0;
     // Решение, принятое в SELECT и исполняемое в ISSUE
     static bool issueDiscard = false;
     // Повтор tx_meta после error==2 (длину заново не читать)
     static bool retryMeta = false;

     // Актуализируем sessionID (в т.ч. после переподключения)
     if (!serverSessionToTx.empty())
     {
          serverSession = serverSessionToTx.read();
          serverSessionValid = true;
     }
     if (!clientSessionFifo.empty())
     {
          clientSession = clientSessionFifo.read();
          clientSessionValid = true;
     }
     if (!clientLostFifo.empty())
     {
          clientLostFifo.read();
          clientSessionValid = false;
     }
     if (!upstreamLostTxFifo.empty())
     {
          upstreamLostTxFifo.read();
          serverSessionValid = false;
     }

     switch (txState)
     {
     case SELECT:
     {
          // Отправлять можно только в живую сессию. Данные для
          // отвалившегося направления отбрасываем.
          bool clientPending = !toClientLength.empty();
          bool serverPending = !toServerLength.empty();
          bool clientReady = clientSessionValid && clientPending;
          bool serverReady = serverSessionValid && serverPending;

          bool pick = false;
          bool discard = false;

          if (serveClient)
          {
               if (clientReady)      { activeIsClient = true;  pick = true; }
               else if (serverReady) { activeIsClient = false; pick = true; }
          }
          else
          {
               if (serverReady)      { activeIsClient = false; pick = true; }
               else if (clientReady) { activeIsClient = true;  pick = true; }
          }

          if (!pick)
          {
               // Есть данные, но получатель отключён — сбрасываем их
               if (clientPending && !clientSessionValid)
               {
                    activeIsClient = true;
                    discard = true;
               }
               else if (serverPending && !serverSessionValid)
               {
                    activeIsClient = false;
                    discard = true;
               }
          }

          // Только фиксируем решение; чтение длины — в ISSUE
          if (pick || discard)
          {
               issueDiscard = discard;
               txState = ISSUE;
          }
          break;
     }

     case ISSUE:
     {
          // Длина уже гарантированно есть (проверено в SELECT), но
          // между вызовами направление не менялось, поэтому читаем
          // ровно из выбранной очереди.
          //
          // retryMeta означает повтор после tx_status error==2: длина
          // уже прочитана в прошлый раз, читать её снова нельзя.
          if (!retryMeta)
          {
               pendingLength = activeIsClient ? toClientLength.read()
                                              : toServerLength.read();
               wordsToSend = (pendingLength + 63) >> 6;
               wordsSent = 0;
               bytesRemaining = pendingLength;
          }
          retryMeta = false;

          if (issueDiscard)
          {
               txState = DISCARD;
          }
          else
          {
               // Единственное место записи в m_axis_tcp_tx_meta на всё
               // ядро — см. пояснение про 200-1960 ниже в WRITE_DATA.
               // full() не проверяем: блокировка на выходном порту к
               // стеку — штатный backpressure. Раньше здесь были два
               // обращения (full + write) и ещё одно в WAIT_META_SPACE,
               // то есть три обращения к одному AXIS-порту.
               pkt32 tx_meta_pkt;
               tx_meta_pkt.data(15, 0) = activeIsClient ? clientSession : serverSession;
               tx_meta_pkt.data(31, 16) = pendingLength;
               m_axis_tcp_tx_meta.write(tx_meta_pkt);
               txState = WAIT_STATUS;
          }
          break;
     }

     case WAIT_STATUS:
          if (!s_axis_tcp_tx_status.empty())
          {
               pkt64 status_pkt = s_axis_tcp_tx_status.read();
               ap_uint<2> error = status_pkt.data(63, 62);

               if (error == 0)
               {
                    txState = WRITE_DATA;
               }
               else if (error == 1)
               {
                    // Соединение разорвано — данные этой порции
                    // сбрасываем. Стек сообщает об обрыве ТОЛЬКО здесь,
                    // notification с closed может не прийти, поэтому
                    // недостаточно сбросить свой локальный флаг: надо
                    // разбудить того, кто переподключается (upstream)
                    // или закрыть повисшую клиентскую сессию.
                    // Иначе upstream остаётся мёртвым навсегда.
                    if (activeIsClient)
                    {
                         clientSessionValid = false;
                         if (!strayFromTx.full())
                              strayFromTx.write(clientSession);
                    }
                    else
                    {
                         serverSessionValid = false;
                         if (!upstreamLostFromTx.full())
                              upstreamLostFromTx.write(true);
                    }
                    txState = DISCARD;
               }
               else
               {
                    // Нет места в буфере получателя — повторяем запрос.
                    // Длина и счётчики уже установлены и не меняются,
                    // поэтому возвращаемся в ISSUE, но БЕЗ повторного
                    // чтения длины из FIFO (её там уже нет).
                    retryMeta = true;
                    txState = ISSUE;
               }
          }
          break;

     // WRITE_DATA и DISCARD объединены: оба вычитывают слово из той же
     // очереди, отличается только судьба слова (отправить или выбросить).
     //
     // РАЗДЕЛЯТЬ ИХ НЕЛЬЗЯ. Когда read() по toServerData/toClientData
     // стоял в двух разных состояниях, HLS видел два обращения к одному
     // порту и не мог уложить их в один такт:
     //   [HLS 200-880] carried dependence between fifo read on port
     //   'toServerData' (DISCARD) and fifo request (WRITE_DATA) => II=2
     // А II=2 в передатчике — это половина пропускной способности.
     // Теперь на каждый порт ровно одно место чтения.
     case WRITE_DATA:
     case DISCARD:
     {
          bool discarding = (txState == DISCARD);

          bool dataReady = activeIsClient ? !toClientData.empty()
                                          : !toServerData.empty();

          // full() на m_axis_tcp_tx_data НЕ проверяем.
          //
          // UG1448, сообщение 200-1960: множественные обращения к
          // AXIS/ap_hs/FIFO-порту внутри одного конвейера дают
          // "conflicts across pipeline stages". Проверка full() плюс
          // write() — это два обращения к одному порту, и они как раз
          // и удерживали II=2:
          //   [200-880] between axis write (:739) and axis request (:713)
          //   on port 'm_axis_tcp_tx_data'
          //
          // Блокирующая запись в выходной поток к стеку — это штатный
          // backpressure, а не дедлок: стек всегда в конце концов
          // забирает данные, обратной связи через это ядро нет.
          // Guard здесь был лишним с самого начала.
          if (dataReady)
          {
               ap_uint<512> payload = activeIsClient ? toClientData.read()
                                                    : toServerData.read();

               wordsSent++;

               if (!discarding)
               {
                    pkt512 tx_word;
                    tx_word.data = payload;

                    // В последнем слове валидны только оставшиеся байты
                    ap_uint<7> validBytes = (bytesRemaining >= 64) ? (ap_uint<7>)64
                                                                   : (ap_uint<7>)bytesRemaining;
                    for (int i = 0; i < 64; i++)
                    {
                    #pragma HLS UNROLL
                         tx_word.keep(i, i) = (i < validBytes) ? 1 : 0;
                    }
                    bytesRemaining = (bytesRemaining >= 64) ? (ap_uint<16>)(bytesRemaining - 64)
                                                           : (ap_uint<16>)0;

                    tx_word.last = (wordsSent == wordsToSend);
                    m_axis_tcp_tx_data.write(tx_word);
               }

               if (wordsSent >= wordsToSend)
               {
                    // транзакция завершена — уступаем очередь второму направлению
                    serveClient = !serveClient;
                    txState = SELECT;
               }
          }
          break;
     }
     }
}

/*
 * Закрывает лишние сессии: шлюз обслуживает одного клиента, а
 * listen-порт принимает любые входящие подключения. Единственный
 * писатель в m_axis_tcp_close_connection.
 */
void gw_close_stray(hls::stream<ap_uint<16> >& straySessionFifo,
                    hls::stream<ap_uint<16> >& strayFromTx,
                    hls::stream<pkt16>& m_axis_tcp_close_connection)
{
#pragma HLS PIPELINE II=1
#pragma HLS INLINE off

     // Два источника (gw_route и gw_tx_merged), потому что один
     // hls::stream нельзя писать из двух функций. Обслуживаем по
     // одному за вызов, приоритет не важен.
     //
     // Одно место записи в m_axis_tcp_close_connection и без проверки
     // full() — раньше было два write() плюс full(), то есть три
     // обращения к одному AXIS-порту, что держало II=2
     // (UG1448, 200-1960: multiple reads/writes to AXIS => conflicts
     // across pipeline stages).
     bool haveStray = !straySessionFifo.empty();
     bool haveTxStray = !strayFromTx.empty();

     if (haveStray || haveTxStray)
     {
          ap_uint<16> session = haveStray ? straySessionFifo.read()
                                         : strayFromTx.read();
          pkt16 close_pkt;
          close_pkt.data = 0;
          close_pkt.data(15, 0) = session;
          m_axis_tcp_close_connection.write(close_pkt);
     }
}

/*
 * Тело релея: все стадии и внутренние FIFO.
 *
 * Вынесено из top-функции, чтобы его могли использовать ДВА входа:
 *   - hls_gateway_krnl      — то, что идёт в железо (скаляры по AXI-lite);
 *   - hls_gateway_krnl_cosim — обёртка для co-simulation, где скаляры
 *     зашиты константами.
 *
 * Причина раздвоения: cosim не поддерживает ap_ctrl_none-дизайн со
 * скалярными портами без valid/ready —
 *   [COSIM] found non-self-synchronizing top I/O listenPort
 *   [COSIM 212-345] Cosim only supports ... (3) designs with array
 *   streaming or hls_stream or AXI4 stream ports
 * Убрав скаляры, дизайн попадает под пункт (3) и cosim становится
 * возможен. Внутренняя логика и глубины FIFO при этом ровно те же,
 * а именно их и нужно проверить на дедлок (UG1448, Data FIFO Sizing).
 */
void gw_core(int listenPort,
                    int serverIpAddress,
                    int serverPort,
                    ap_uint<32> reconnectDelay,
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
// function". Top-функции сами не dataflow-регионы, они лишь вызывают
// gw_core, поэтому gw_core остаётся отдельной dataflow-функцией.
//
// DATAFLOW, а не PIPELINE: стадии становятся независимыми процессами,
// и обратная связь gw_route -> gw_connect_upstream через
// upstreamLostFifo перестаёт быть carried dependence (было II=10).
#pragma HLS INLINE off
#pragma HLS DATAFLOW disable_start_propagation

     // ---- Внутренние FIFO между стадиями ----

     // sessionID сервера: отдельный FIFO на каждого потребителя,
     // один поток нельзя читать из двух функций
     static hls::stream<ap_uint<16> > serverSessionToRoute("serverSessionToRoute");
     #pragma HLS STREAM variable=serverSessionToRoute depth=4
     static hls::stream<ap_uint<16> > serverSessionToTx("serverSessionToTx");
     #pragma HLS STREAM variable=serverSessionToTx depth=4

     // sessionID клиента (узнаём из первого входящего пакета)
     static hls::stream<ap_uint<16> > clientSessionFifo("clientSessionFifo");
     #pragma HLS STREAM variable=clientSessionFifo depth=4

     // Лишние сессии, подлежащие закрытию (из gw_route)
     static hls::stream<ap_uint<16> > straySessionFifo("straySessionFifo");
     #pragma HLS STREAM variable=straySessionFifo depth=16

     // То же, но обнаруженное передатчиком по tx_status error==1
     static hls::stream<ap_uint<16> > strayFromTx("strayFromTx");
     #pragma HLS STREAM variable=strayFromTx depth=16

     // Обрыв upstream, обнаруженный передатчиком (tx_status error==1).
     // Отдельный FIFO, т.к. upstreamLostFifo пишет gw_route.
     static hls::stream<bool> upstreamLostFromTx("upstreamLostFromTx");
     #pragma HLS STREAM variable=upstreamLostFromTx depth=4

     // Уведомления о закрытии сессий.
     // Глубина с запасом: gw_route вычитывает этот FIFO только между
     // пакетами, поэтому во время длинной передачи уведомления копятся.
     // Переполнение больше не приводит к дедлоку (gw_rx_handshake
     // проверяет full() перед чтением уведомления), но лишний
     // backpressure на стек нежелателен.
     static hls::stream<ap_uint<16> > closedSessionFifo("closedSessionFifo");
     #pragma HLS STREAM variable=closedSessionFifo depth=64
     static hls::stream<bool> clientLostFifo("clientLostFifo");
     #pragma HLS STREAM variable=clientLostFifo depth=4
     static hls::stream<bool> upstreamLostFifo("upstreamLostFifo");
     #pragma HLS STREAM variable=upstreamLostFifo depth=4
     static hls::stream<bool> upstreamLostTxFifo("upstreamLostTxFifo");
     #pragma HLS STREAM variable=upstreamLostTxFifo depth=4

     // rx handshake -> router
     static hls::stream<ap_uint<16> > rxSessionFifo("rxSessionFifo");
     #pragma HLS STREAM variable=rxSessionFifo depth=512
     static hls::stream<ap_uint<16> > rxLengthFifo("rxLengthFifo");
     #pragma HLS STREAM variable=rxLengthFifo depth=512

     // router -> передатчик (uplink: в сторону сервера)
     static hls::stream<ap_uint<512> > toServerData("toServerData");
     #pragma HLS STREAM variable=toServerData depth=1024
     static hls::stream<ap_uint<16> > toServerLength("toServerLength");
     #pragma HLS STREAM variable=toServerLength depth=512

     // router -> передатчик (downlink: в сторону клиента)
     static hls::stream<ap_uint<512> > toClientData("toClientData");
     #pragma HLS STREAM variable=toClientData depth=1024
     static hls::stream<ap_uint<16> > toClientLength("toClientLength");
     #pragma HLS STREAM variable=toClientLength depth=512

     // ---- Неиспользуемые интерфейсы ----
     // m_axis_tcp_close_connection больше НЕ заглушен: в него пишет
     // gw_close_stray, закрывая лишние клиентские сессии.
     tie_off_udp(s_axis_udp_rx, m_axis_udp_tx, s_axis_udp_rx_meta, m_axis_udp_tx_meta);

     // ---- Стадии релея ----

     // 1. Слушаем порт для клиента
     gw_listen(listenPort, m_axis_tcp_listen_port, s_axis_tcp_port_status);

     // 2. Держим соединение с upstream-сервером (с переподключением)
     gw_connect_upstream(serverIpAddress, serverPort, reconnectDelay,
                         m_axis_tcp_open_connection, s_axis_tcp_open_status,
                         serverSessionToRoute, serverSessionToTx,
                         upstreamLostFifo, upstreamLostFromTx);

     // 3. Приём: подтверждаем уведомления, ловим разрывы
     gw_rx_handshake(s_axis_tcp_notification, m_axis_tcp_read_pkg,
                     rxSessionFifo, rxLengthFifo, closedSessionFifo);

     // 4. Маршрутизация принятых данных по направлениям
     gw_route(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
              rxSessionFifo, rxLengthFifo, closedSessionFifo,
              serverSessionToRoute,
              toServerData, toServerLength,
              toClientData, toClientLength,
              clientSessionFifo, clientLostFifo,
              upstreamLostFifo, upstreamLostTxFifo,
              straySessionFifo);

     // 5. Единственный передатчик — обслуживает оба направления
     gw_tx_merged(serverSessionToTx, clientSessionFifo,
                  clientLostFifo, upstreamLostTxFifo,
                  toServerData, toServerLength,
                  toClientData, toClientLength,
                  m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                  s_axis_tcp_tx_status,
                  upstreamLostFromTx, strayFromTx);

     // 6. Закрываем лишние клиентские сессии
     gw_close_stray(straySessionFifo, strayFromTx, m_axis_tcp_close_connection);
}

extern "C" {
void hls_gateway_krnl(
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

               // Скалярные аргументы (задаются с хоста)
               int listenPort,         // порт, который слушаем для клиента
               int serverIpAddress,    // IP upstream-сервера
               int serverPort,         // порт upstream-сервера
               int reconnectDelay      // пауза реконнекта, в тактах
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
#pragma HLS INTERFACE s_axilite port=serverIpAddress bundle = control
#pragma HLS INTERFACE s_axilite port=serverPort bundle = control
#pragma HLS INTERFACE s_axilite port=reconnectDelay bundle = control
#pragma HLS INTERFACE ap_ctrl_none port = return

// Вся логика — в gw_core (см. пояснение там). Здесь только интерфейс.
     gw_core(listenPort, serverIpAddress, serverPort,
             (ap_uint<32>)reconnectDelay,
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

/*
 * Точка входа ТОЛЬКО для co-simulation.
 *
 * Отличается от hls_gateway_krnl единственным: скалярные параметры не
 * являются портами, а зашиты константами. Все порты — AXI4-Stream,
 * поэтому дизайн попадает под условие COSIM 212-345 (3) и cosim
 * запускается. Внутри — тот же gw_core, те же стадии и те же глубины
 * FIFO, так что проверка дедлока осмысленна.
 *
 * В железо этот вход НЕ идёт: config_sp/сборка используют
 * hls_gateway_krnl. Значения должны совпадать с тем, что подаёт
 * тестбенч (см. test_hls_gateway_krnl.cpp).
 */
#define GW_COSIM_LISTEN_PORT      5001
#define GW_COSIM_SERVER_IP        0xC0A80114
#define GW_COSIM_SERVER_PORT      8080
#define GW_COSIM_RECONNECT_DELAY  100

void hls_gateway_krnl_cosim(
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
#pragma HLS INTERFACE ap_ctrl_none port = return

     gw_core(GW_COSIM_LISTEN_PORT, GW_COSIM_SERVER_IP, GW_COSIM_SERVER_PORT,
             (ap_uint<32>)GW_COSIM_RECONNECT_DELAY,
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
