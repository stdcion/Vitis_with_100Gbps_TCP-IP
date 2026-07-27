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

Структура повторяет идиому библиотеки communication.hpp (см.
allReduce_sum): стадии соединены внутренними FIFO, и в каждый
выходной AXI-Stream порт пишет РОВНО ОДНА функция. Порт
m_axis_tcp_tx_* физически один на всё ядро, а сессии клиента и
сервера различаются полем sessionID внутри tx_meta, поэтому оба
направления сводятся в единственный передатчик gw_tx_merged.

Точка расширения для будущей обработки данных отмечена в коде
комментарием "HOOK".
************************************************/
#include "ap_axi_sdata.h"
#include <ap_fixed.h>
#include "ap_int.h"
#include "../../../../common/include/communication.hpp"
#include "hls_stream.h"

// Пауза между попытками переподключения к upstream-серверу,
// в тактах (250 МГц => 250000000 тактов ≈ 1 секунда).
// В C-симуляции переопределяется на малое значение через -D.
#ifndef GW_RECONNECT_DELAY
#define GW_RECONNECT_DELAY 250000000
#endif

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
                         hls::stream<pkt64>& m_axis_tcp_open_connection,
                         hls::stream<pkt128>& s_axis_tcp_open_status,
                         hls::stream<ap_uint<16> >& serverSessionToRoute,
                         hls::stream<ap_uint<16> >& serverSessionToTx,
                         hls::stream<bool>& upstreamLostFifo)
{
#pragma HLS INLINE off

     enum connStateType {CONNECT, WAIT_STATUS, ESTABLISHED, BACKOFF};
     static connStateType connState = CONNECT;
#pragma HLS RESET variable=connState

     static ap_uint<32> backoffCounter = 0;

     // Сообщение об обрыве может прийти в любом состоянии
     bool lost = false;
     if (!upstreamLostFifo.empty())
     {
          upstreamLostFifo.read();
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
          if (backoffCounter >= GW_RECONNECT_DELAY)
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
 */
void gw_rx_handshake(hls::stream<pkt128>& s_axis_tcp_notification,
                     hls::stream<pkt32>& m_axis_tcp_read_pkg,
                     hls::stream<ap_uint<16> >& rxSessionFifo,
                     hls::stream<ap_uint<16> >& rxLengthFifo,
                     hls::stream<ap_uint<16> >& closedSessionFifo)
{
#pragma HLS INLINE off

     if (!s_axis_tcp_notification.empty())
     {
          pkt128 notification_pkt = s_axis_tcp_notification.read();
          ap_uint<16> sessionID = notification_pkt.data(15, 0);
          ap_uint<16> length = notification_pkt.data(31, 16);
          ap_uint<1> closed = notification_pkt.data(80, 80);

          if (length != 0)
          {
               pkt32 readRequest_pkt;
               readRequest_pkt.data(15, 0) = sessionID;
               readRequest_pkt.data(31, 16) = length;
               m_axis_tcp_read_pkg.write(readRequest_pkt);

               rxSessionFifo.write(sessionID);
               rxLengthFifo.write(length);
          }
          else if (closed)
          {
               closedSessionFifo.write(sessionID);
          }
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
              hls::stream<bool>& upstreamLostFifo)
{
#pragma HLS INLINE off

     enum routeStateType {IDLE, FORWARD};
     static routeStateType routeState = IDLE;
#pragma HLS RESET variable=routeState

     static ap_uint<16> serverSession = 0;
     static bool serverSessionValid = false;
     static ap_uint<16> clientSession = 0;
     static bool clientSessionValid = false;
     static bool currentIsFromServer = false;

     // Новый sessionID upstream-соединения (приходит при каждом
     // успешном подключении, в том числе после переподключения)
     if (!serverSessionToRoute.empty())
     {
          serverSession = serverSessionToRoute.read();
          serverSessionValid = true;
     }

     // Уведомления о разрывах обрабатываем только между пакетами,
     // чтобы не потерять середину уже идущей передачи
     if (routeState == IDLE && !closedSessionFifo.empty())
     {
          ap_uint<16> closedSession = closedSessionFifo.read();

          if (serverSessionValid && closedSession == serverSession)
          {
               serverSessionValid = false;
               upstreamLostFifo.write(true);
          }
          else if (clientSessionValid && closedSession == clientSession)
          {
               clientSessionValid = false;
               clientLostFifo.write(true);
          }
     }

     switch (routeState)
     {
     case IDLE:
          if (!rxSessionFifo.empty() && !rxLengthFifo.empty() && !s_axis_tcp_rx_meta.empty())
          {
               s_axis_tcp_rx_meta.read();
               ap_uint<16> currentSession = rxSessionFifo.read();
               ap_uint<16> length = rxLengthFifo.read();

               currentIsFromServer = (serverSessionValid && currentSession == serverSession);

               if (currentIsFromServer)
               {
                    // downlink: сервер -> клиент
                    toClientLength.write(length);
               }
               else
               {
                    // uplink: клиент -> сервер.
                    // Первый пакет нового клиента сообщает его sessionID.
                    if (!clientSessionValid || currentSession != clientSession)
                    {
                         clientSession = currentSession;
                         clientSessionValid = true;
                         clientSessionFifo.write(currentSession);
                    }
                    toServerLength.write(length);
               }
               routeState = FORWARD;
          }
          break;

     case FORWARD:
          if (!s_axis_tcp_rx_data.empty())
          {
               pkt512 rx_word = s_axis_tcp_rx_data.read();

               // HOOK: здесь можно инспектировать/модифицировать rx_word.data
               // перед пересылкой (фильтр, парсер протокола и т.п.).

               if (currentIsFromServer)
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
                  hls::stream<pkt64>& s_axis_tcp_tx_status)
{
#pragma HLS INLINE off

     enum txStateType {SELECT, WAIT_STATUS, WRITE_DATA, DISCARD};
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

          if (pick || discard)
          {
               pendingLength = activeIsClient ? toClientLength.read()
                                              : toServerLength.read();
               wordsToSend = (pendingLength + 63) >> 6;
               wordsSent = 0;
               bytesRemaining = pendingLength;
          }

          if (pick)
          {
               pkt32 tx_meta_pkt;
               tx_meta_pkt.data(15, 0) = activeIsClient ? clientSession : serverSession;
               tx_meta_pkt.data(31, 16) = pendingLength;
               m_axis_tcp_tx_meta.write(tx_meta_pkt);
               txState = WAIT_STATUS;
          }
          else if (discard)
          {
               txState = DISCARD;
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
                    // соединение разорвано — данные этой порции сбрасываем
                    if (activeIsClient) clientSessionValid = false;
                    else                serverSessionValid = false;
                    txState = DISCARD;
               }
               else
               {
                    // нет места в буфере получателя — повторяем запрос
                    pkt32 tx_meta_pkt;
                    tx_meta_pkt.data(15, 0) = activeIsClient ? clientSession : serverSession;
                    tx_meta_pkt.data(31, 16) = pendingLength;
                    m_axis_tcp_tx_meta.write(tx_meta_pkt);
               }
          }
          break;

     case WRITE_DATA:
     {
          bool dataReady = activeIsClient ? !toClientData.empty()
                                          : !toServerData.empty();
          if (dataReady)
          {
               ap_uint<512> payload = activeIsClient ? toClientData.read()
                                                     : toServerData.read();

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

               wordsSent++;
               tx_word.last = (wordsSent == wordsToSend);
               m_axis_tcp_tx_data.write(tx_word);

               if (tx_word.last)
               {
                    // транзакция завершена — уступаем очередь второму направлению
                    serveClient = !serveClient;
                    txState = SELECT;
               }
          }
          break;
     }

     case DISCARD:
     {
          // Вычитываем данные, которые уже некому отправить
          bool dataReady = activeIsClient ? !toClientData.empty()
                                          : !toServerData.empty();
          if (dataReady)
          {
               if (activeIsClient) toClientData.read();
               else                toServerData.read();

               wordsSent++;
               if (wordsSent >= wordsToSend)
               {
                    serveClient = !serveClient;
                    txState = SELECT;
               }
          }
          break;
     }
     }
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
               int serverPort          // порт upstream-сервера
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
#pragma HLS INTERFACE ap_ctrl_none port = return

#pragma HLS PIPELINE II=1

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

     // Уведомления о закрытии сессий
     static hls::stream<ap_uint<16> > closedSessionFifo("closedSessionFifo");
     #pragma HLS STREAM variable=closedSessionFifo depth=8
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
     tie_off_udp(s_axis_udp_rx, m_axis_udp_tx, s_axis_udp_rx_meta, m_axis_udp_tx_meta);
     tie_off_tcp_close_con(m_axis_tcp_close_connection);

     // ---- Стадии релея ----

     // 1. Слушаем порт для клиента
     gw_listen(listenPort, m_axis_tcp_listen_port, s_axis_tcp_port_status);

     // 2. Держим соединение с upstream-сервером (с переподключением)
     gw_connect_upstream(serverIpAddress, serverPort,
                         m_axis_tcp_open_connection, s_axis_tcp_open_status,
                         serverSessionToRoute, serverSessionToTx,
                         upstreamLostFifo);

     // 3. Приём: подтверждаем уведомления, ловим разрывы
     gw_rx_handshake(s_axis_tcp_notification, m_axis_tcp_read_pkg,
                     rxSessionFifo, rxLengthFifo, closedSessionFifo);

     // 4. Маршрутизация принятых данных по направлениям
     gw_route(s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
              rxSessionFifo, rxLengthFifo, closedSessionFifo,
              serverSessionToRoute,
              toServerData, toServerLength,
              toClientData, toClientLength,
              clientSessionFifo, clientLostFifo, upstreamLostFifo);

     // 5. Единственный передатчик — обслуживает оба направления
     gw_tx_merged(serverSessionToTx, clientSessionFifo,
                  clientLostFifo, upstreamLostTxFifo,
                  toServerData, toServerLength,
                  toClientData, toClientLength,
                  m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
                  s_axis_tcp_tx_status);
}
}
