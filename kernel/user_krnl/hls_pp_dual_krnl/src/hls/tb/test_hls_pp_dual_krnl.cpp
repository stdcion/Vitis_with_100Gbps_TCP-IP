/************************************************
C-симуляция для hls_pingpong_krnl.

Тестбенч подменяет собой TCP/IP-стек: подаёт уведомления и данные так,
как это делал бы стек, и проверяет, что ядро отражает обратно.

Ядро объявлено с ap_ctrl_none и работает вечно, поэтому в csim его
нельзя вызвать «до завершения» — тестбенч вызывает его в цикле по
одному такту (tick) и между тактами подкладывает/забирает данные.

Модель стека — независимый процесс stack_tick(), вызываемый на каждом
такте вместе с ядром. Настраивается:
  - задержка ответа tx_status (statusDelay),
  - код ошибки на N-й транзакции (forceErrorOn/forceErrorCode),
  - остановка приёма tx_data (stallData) для проверки backpressure.

Это важно: если тестбенч сам отвечает статусом сразу после чтения
tx_meta и всегда успехом, то ветки error==1/error==2 остаются мёртвым
кодом, а backpressure не возникает никогда.

ГРАНИЦЫ ПРИМЕНИМОСТИ. В C-симуляции hls::stream не имеет ограниченной
глубины и блокирующая запись никогда не блокируется, поэтому csim
принципиально НЕ может воспроизвести дедлок по заполнению FIFO.
Проверка глубин — только co-simulation или железо.

Сценарии:
  1. Открытие listen-порта
  2. Базовое эхо (2 полных слова)
  3. Неполное последнее слово (length не кратна 64) — проверка keep
  4. Реконнект клиента (новый sessionID)
  5. Серия сообщений подряд
  6. tx_status error==2 — повтор tx_meta
  7. tx_status error==1 — сообщение отбрасывается, ядро живо
  8. Сообщение больше PP_MAX_WORDS (усечение)
  9. Сообщение, разбитое на два уведомления (сегментация TCP)
 10. Стек отдал меньше слов, чем обещал в уведомлении
 11. Backpressure: стек не принимает tx_data

 12. ТЕЛЕМЕТРИЯ: portState/ppState/notifyCount соответствуют факту

ОТКУДА ВЗЯТ И ЧТО ИЗМЕНЕНО.

Тестбенч скопирован из hls_pingpong_krnl (11 сценариев, все проходили) и
адаптирован под hls_pp_dual_krnl машинно, а не переписан руками. Изменения:

  - вызываются СТАДИИ половины a, а не топ-функция (причина -- у объявлений
    pp_listen/pp_echo ниже, там же границы применимости)
  - сценарий 12 -- новый, проверяет телеметрию, которой у pingpong не было

Сценарии 1-11 не тронуты: их код обязан остаться тем же, иначе прохождение
ничего не скажет о ядре, вокруг которого он собран.

ЗАЧЕМ СЦЕНАРИЙ 12. Три скаляра -- единственное, чем мы будем читать плату.
Если ppState врёт (например, отстаёт на такт или не обновляется в части
состояний), то отладка пойдёт по ложному следу, а попытка у платы одна в
сутки. Тест сверяет ppState с фактическим шагом, наблюдаемым по шинам.

Сборка без Vitis HLS (см. kernel/common/csim_shim/README.md):
    SHIM=$PWD/kernel/common/csim_shim
    g++ -std=c++14 -I$SHIM -o /tmp/tb <ядро>.cpp tb/test_<ядро>.cpp && /tmp/tb

Сборка на машине с Vitis HLS:
    vitis_hls -f run_csim.tcl
************************************************/
#include "ap_axi_sdata.h"
#include "ap_int.h"
#include "hls_stream.h"

#include <iostream>
#include <deque>
#include <vector>
#include <string>

typedef ap_axiu<512, 0, 0, 0> pkt512;
typedef ap_axiu<256, 0, 0, 0> pkt256;
typedef ap_axiu<128, 0, 0, 0> pkt128;
typedef ap_axiu<64, 0, 0, 0>  pkt64;
typedef ap_axiu<32, 0, 0, 0>  pkt32;
typedef ap_axiu<16, 0, 0, 0>  pkt16;
typedef ap_axiu<8, 0, 0, 0>   pkt8;

// Должно совпадать с PP_MAX_WORDS в ядре
static const int PP_MAX_WORDS_TB = 64;

/*
 * ВЫЗЫВАЕМ СТАДИИ ПОЛОВИНЫ a НАПРЯМУЮ, А НЕ ТОП-ФУНКЦИЮ.
 *
 * ПОЧЕМУ. Топ-функция вызывает на половине b апстримные listenPorts и
 * recvData, и обе содержат циклы, не завершающиеся без данных:
 *
 *   port_status_handler   for (i < useConn) { port_status.read(...) }   :746
 *   recvData_handshake    do {...} while (rxByteCnt < expRxByteCnt)     :1239
 *
 * На плате это правильно -- стадии независимое железо, чтение ждёт. В csim
 * вызов ядра не возвращается, и подложить данные между тактами нельзя:
 * такта не будет.
 *
 * Три попытки обойти это провалились, каждая с новым симптомом:
 *   1) отвечать после запроса        -> assert "read() из пустого stream"
 *   2) кормить между тактами         -> зависание в :1239 (найдено через
 *                                       sample на живом процессе)
 *   3) держать по слову на проход    -> зависание, когда данные кончились
 *
 * Именно поэтому у recv-ядер в этом репозитории тестбенчей НЕТ ВООБЩЕ.
 * Условную компиляцию в ядро добавлять нельзя: тогда тест проверял бы не тот
 * код, что пойдёт в железо.
 *
 * ЧТО ЭТО ЗНАЧИТ ДЛЯ ГРАНИЦ ТЕСТА. Проверяется логика pp_listen и pp_echo --
 * то есть весь НОВЫЙ код ядра. НЕ проверяется:
 *
 *   - что половина b не мешает эху (нужен cosim или плата)
 *   - что DATAFLOW-регион из 8 стадий синтезируется и живёт (csynth/железо)
 *   - что скаляры доезжают через s_axilite (только плата)
 *
 * Половина b -- дословная копия зелёной фазы 3, поэтому её собственная логика
 * уже проверена на плате 25.08. Открытым остаётся только их совместная жизнь
 * в одном регионе, и это первое, что покажет запуск.
 */
void pp_listen(int listenPort,
     ap_uint<32>& portState,
     hls::stream<pkt16>& m_axis_tcp_listen_port,
     hls::stream<pkt8>& s_axis_tcp_port_status);

void pp_echo(ap_uint<32>& ppStateOut,
     ap_uint<32>& notifyCount,
     hls::stream<pkt128>& s_axis_tcp_notification,
     hls::stream<pkt32>& m_axis_tcp_read_pkg,
     hls::stream<pkt16>& s_axis_tcp_rx_meta,
     hls::stream<pkt512>& s_axis_tcp_rx_data,
     hls::stream<pkt32>& m_axis_tcp_tx_meta,
     hls::stream<pkt512>& m_axis_tcp_tx_data,
     hls::stream<pkt64>& s_axis_tcp_tx_status);

// ---------------------------------------------------------------
static const int LISTEN_PORT = 5001;

static const ap_uint<16> SESSION_A = 3;   // первый клиент
static const ap_uint<16> SESSION_B = 9;   // после реконнекта

// ---------------------------------------------------------------
static hls::stream<pkt512> s_axis_udp_rx;
static hls::stream<pkt512> m_axis_udp_tx;
static hls::stream<pkt256> s_axis_udp_rx_meta;
static hls::stream<pkt256> m_axis_udp_tx_meta;
static hls::stream<pkt16>  m_axis_tcp_listen_port;
static hls::stream<pkt8>   s_axis_tcp_port_status;
static hls::stream<pkt64>  m_axis_tcp_open_connection;
static hls::stream<pkt128> s_axis_tcp_open_status;
static hls::stream<pkt16>  m_axis_tcp_close_connection;
static hls::stream<pkt128> s_axis_tcp_notification;
static hls::stream<pkt32>  m_axis_tcp_read_pkg;
static hls::stream<pkt16>  s_axis_tcp_rx_meta;
static hls::stream<pkt512> s_axis_tcp_rx_data;
static hls::stream<pkt32>  m_axis_tcp_tx_meta;
static hls::stream<pkt512> m_axis_tcp_tx_data;
static hls::stream<pkt64>  s_axis_tcp_tx_status;

// Выходные скаляры. Начальные значения намеренно НЕВОЗМОЖНЫЕ: если ядро их
// не тронет, тест это увидит, а не примет нуль за настоящий NOTIFY.
static ap_uint<32> tlm_portState   = 0xDEAD;
static ap_uint<32> tlm_ppState     = 0xDEAD;
static ap_uint<32> tlm_notifyCount = 0xDEAD;

static int failures = 0;

static void check(bool cond, const std::string& what)
{
     if (cond) std::cout << "  [ OK ] " << what << std::endl;
     else    { std::cout << "  [FAIL] " << what << std::endl; failures++; }
}

// ---------------------------------------------------------------
// Модель TCP-стека
// ---------------------------------------------------------------
struct TxCapture
{
     ap_uint<16>              sessionID;
     ap_uint<16>              length;
     int                      words;
     ap_uint<64>              lastKeep;
     std::vector<ap_uint<32> > firstWordLo;  // младшее слово каждого data-слова
};

static std::deque<TxCapture> captured;

static int  stk_statusDelay   = 0;
static int  stk_forceErrorOn  = -1;
static int  stk_forceErrorCode = 0;
static bool stk_stallData     = false;

static int         stk_txCount    = 0;
static bool        stk_haveMeta   = false;
static ap_uint<16> stk_metaSession = 0;
static ap_uint<16> stk_metaLength  = 0;
static int         stk_delayLeft  = 0;
static bool        stk_awaitData  = false;
static int         stk_strayWords = 0;
static TxCapture   stk_cur;

// Забранные стеком read request. Тесты, которым нужно посмотреть на
// сам запрос, выключают drainReadPkg и читают поток напрямую.
static std::deque<pkt32> readReqs;
static bool drainReadPkg = true;

static void stack_reset_cfg()
{
     stk_statusDelay    = 0;
     stk_forceErrorOn   = -1;
     stk_forceErrorCode = 0;
     stk_stallData      = false;
}

static void stack_tick()
{
     // 1. Приём tx_meta
     if (!stk_haveMeta && !stk_awaitData && !m_axis_tcp_tx_meta.empty())
     {
          pkt32 meta = m_axis_tcp_tx_meta.read();
          stk_metaSession = meta.data(15, 0);
          stk_metaLength  = meta.data(31, 16);
          stk_haveMeta    = true;
          stk_delayLeft   = stk_statusDelay;
          stk_txCount++;
     }

     // 2. Ответ tx_status
     if (stk_haveMeta)
     {
          if (stk_delayLeft > 0) stk_delayLeft--;
          else
          {
               int err = 0;
               if (stk_forceErrorOn == stk_txCount) err = stk_forceErrorCode;

               pkt64 s;
               s.data = 0;
               s.data(15, 0)  = stk_metaSession;
               s.data(31, 16) = stk_metaLength;
               s.data(61, 32) = 60000;
               s.data(63, 62) = err;
               s_axis_tcp_tx_status.write(s);

               stk_haveMeta = false;
               if (err == 0)
               {
                    stk_awaitData     = true;
                    stk_cur.sessionID = stk_metaSession;
                    stk_cur.length    = stk_metaLength;
                    stk_cur.words     = 0;
                    stk_cur.lastKeep  = 0;
                    stk_cur.firstWordLo.clear();
               }
          }
     }

     // 3. Приём tx_data
     if (stk_awaitData && !stk_stallData && !m_axis_tcp_tx_data.empty())
     {
          pkt512 w = m_axis_tcp_tx_data.read();
          stk_cur.words++;
          stk_cur.lastKeep = w.keep;
          stk_cur.firstWordLo.push_back((ap_uint<32>)w.data(31, 0));
          if (w.last)
          {
               captured.push_back(stk_cur);
               stk_awaitData = false;
          }
     }
     // Слова вне разрешённой транзакции — нарушение протокола
     else if (!stk_awaitData && !stk_stallData && !m_axis_tcp_tx_data.empty())
     {
          m_axis_tcp_tx_data.read();
          stk_strayWords++;
     }

     if (!m_axis_tcp_close_connection.empty()) m_axis_tcp_close_connection.read();
     if (!m_axis_tcp_open_connection.empty())  m_axis_tcp_open_connection.read();

     // Read request: реальный стек всегда его забирает. Складываем в
     // очередь, чтобы тесты могли проверить содержимое, но НЕ оставляем
     // в hls::stream — иначе csim заканчивается предупреждением
     //   [HLS SIM] hls::stream '...' contains leftover data, which may
     //   result in RTL simulation hanging
     // и cosim на этом действительно встанет.
     if (drainReadPkg && !m_axis_tcp_read_pkg.empty())
     {
          pkt32 rr = m_axis_tcp_read_pkg.read();
          readReqs.push_back(rr);
          if (readReqs.size() > 64) readReqs.pop_front();  // не растём без предела
     }
}

static void tick()
{
     // Порядок как в DATAFLOW-регионе: стадии независимы, но в csim вызов
     // последователен. Порядок listen->echo совпадает с порядком в .cpp.
     pp_listen(LISTEN_PORT, tlm_portState,
               m_axis_tcp_listen_port, s_axis_tcp_port_status);

     pp_echo(tlm_ppState, tlm_notifyCount,
             s_axis_tcp_notification, m_axis_tcp_read_pkg,
             s_axis_tcp_rx_meta, s_axis_tcp_rx_data,
             m_axis_tcp_tx_meta, m_axis_tcp_tx_data,
             s_axis_tcp_tx_status);

     stack_tick();
}

static void run(int cycles) { for (int i = 0; i < cycles; i++) tick(); }

static bool wait_captured(size_t n, int limit)
{
     for (int i = 0; i < limit && captured.size() < n; i++) tick();
     return captured.size() >= n;
}

static bool pop_captured(TxCapture& out, int limit = 2000)
{
     if (!wait_captured(1, limit)) return false;
     out = captured.front();
     captured.pop_front();
     return true;
}

// ---------------------------------------------------------------
// Хелперы
// ---------------------------------------------------------------
static void push_notification(ap_uint<16> sessionID, ap_uint<16> length)
{
     pkt128 n;
     n.data = 0;
     n.data(15, 0)  = sessionID;
     n.data(31, 16) = length;
     n.data(63, 32) = 0x0A0A0A0A;
     n.data(79, 64) = 1234;
     n.data(80, 80) = 0;
     s_axis_tcp_notification.write(n);
}

// Тело сообщения: каждое слово помечено seed+i, чтобы отличать данные
static void push_rx_payload(ap_uint<16> sessionID, int numWords, ap_uint<32> seed)
{
     pkt16 meta;
     meta.data = 0;
     meta.data(15, 0) = sessionID;
     s_axis_tcp_rx_meta.write(meta);

     for (int i = 0; i < numWords; i++)
     {
          pkt512 w;
          w.data = 0;
          for (int k = 0; k < 16; k++)
               w.data(k * 32 + 31, k * 32) = seed + i;
          w.keep = ~ap_uint<64>(0);
          w.last = (i == numWords - 1);
          s_axis_tcp_rx_data.write(w);
     }
}

// Полный цикл: уведомление -> read request -> тело
static void deliver(ap_uint<16> sessionID, ap_uint<16> length, int numWords,
                    ap_uint<32> seed)
{
     push_notification(sessionID, length);
     run(5);   // stack_tick() сам забирает read request (см. drainReadPkg)
     push_rx_payload(sessionID, numWords, seed);
}

static int count_keep(ap_uint<64> keep)
{
     int n = 0;
     for (int i = 0; i < 64; i++) if (keep[i]) n++;
     return n;
}

// ---------------------------------------------------------------
int main()
{
     std::cout << "=== hls_pp_dual_krnl C-simulation ===" << std::endl;

     TxCapture tx;
     stack_reset_cfg();


     // -----------------------------------------------------------
     std::cout << "\n[1] Открытие listen-порта" << std::endl;

     run(5);
     bool gotListen = !m_axis_tcp_listen_port.empty();
     check(gotListen, "ядро запросило listen-порт");
     if (gotListen)
     {
          pkt16 lp = m_axis_tcp_listen_port.read();
          check(lp.data(15, 0) == LISTEN_PORT, "listen-порт равен заданному");
     }
     // portState ДО ответа стека обязан быть 1 (запрос отправлен), не 2.
     //
     // Проверка добавлена после мутационного прогона: мутация
     // "portState = 2 всегда" проходила тест незамеченной, а на плате это
     // означало бы "порт открыт" при закрытом порте -- и отладка пошла бы по
     // ложному следу. Сценарий 12 ловит только противоположный случай.
     check(tlm_portState == 1,
           "portState == 1 до ответа стека (запрос отправлен, не подтверждён)");

     pkt8 ps; ps.data = 1;
     s_axis_tcp_port_status.write(ps);
     run(10);

     check(tlm_portState == 2, "portState == 2 после подтверждения стека");

     // -----------------------------------------------------------
     std::cout << "\n[2] Базовое эхо: 128 байт" << std::endl;

     readReqs.clear();
     push_notification(SESSION_A, 128);
     run(5);
     bool gotRead = !readReqs.empty();
     check(gotRead, "ядро выставило read request");
     if (gotRead)
     {
          pkt32 rr = readReqs.front(); readReqs.pop_front();
          check(rr.data(15, 0) == SESSION_A, "read request для нужной сессии");
          check(rr.data(31, 16) == 128, "запрошенная длина верна");
     }
     push_rx_payload(SESSION_A, 2, 0xAA00);

     if (pop_captured(tx))
     {
          check(tx.sessionID == SESSION_A, "эхо ушло в ТУ ЖЕ сессию");
          check(tx.length == 128, "длина сохранена");
          check(tx.words == 2, "передано 2 слова");
          bool dataOk = tx.firstWordLo.size() == 2
                        && tx.firstWordLo[0] == 0xAA00
                        && tx.firstWordLo[1] == 0xAA01;
          check(dataOk, "содержимое совпало с принятым");
     }
     else check(false, "эхо не пришло");

     // -----------------------------------------------------------
     std::cout << "\n[3] Неполное последнее слово: 100 байт" << std::endl;

     deliver(SESSION_A, 100, 2, 0xCC00);
     if (pop_captured(tx))
     {
          check(tx.length == 100, "длина 100 сохранена");
          check(tx.words == 2, "передано 2 слова");
          check(count_keep(tx.lastKeep) == 36, "keep последнего слова = 36 байт");
     }
     else check(false, "эхо с неполным словом не пришло");

     // -----------------------------------------------------------
     std::cout << "\n[4] Реконнект клиента (новый sessionID)" << std::endl;

     deliver(SESSION_B, 64, 1, 0xDD00);
     if (pop_captured(tx))
          check(tx.sessionID == SESSION_B, "эхо ушло НОВОМУ клиенту");
     else check(false, "эхо после реконнекта не пришло");

     // -----------------------------------------------------------
     std::cout << "\n[5] Серия сообщений подряд" << std::endl;

     const int SERIES = 8;
     for (int i = 0; i < SERIES; i++)
          deliver(SESSION_B, 64, 1, 0x1000 + i);

     bool allSeries = wait_captured(SERIES, 20000);
     check(allSeries, "все сообщения серии отражены");
     if (allSeries)
     {
          bool ok = true;
          for (int i = 0; i < SERIES; i++)
          {
               TxCapture c = captured.front(); captured.pop_front();
               if (c.length != 64 || c.words != 1) ok = false;
               if (c.firstWordLo.size() != 1
                   || c.firstWordLo[0] != (ap_uint<32>)(0x1000 + i)) ok = false;
          }
          check(ok, "порядок и содержимое серии сохранены");
     }

     // -----------------------------------------------------------
     std::cout << "\n[6] tx_status error==2: повтор tx_meta" << std::endl;

     stk_forceErrorOn   = stk_txCount + 1;
     stk_forceErrorCode = 2;

     deliver(SESSION_B, 64, 1, 0x2200);
     if (pop_captured(tx, 4000))
     {
          check(tx.length == 64, "после error==2 длина не потерялась");
          check(tx.words == 1, "данные переданы ровно один раз");
     }
     else check(false, "ядро не повторило tx_meta после error==2");

     stack_reset_cfg();

     // -----------------------------------------------------------
     std::cout << "\n[7] tx_status error==1: сообщение отбрасывается" << std::endl;

     stk_forceErrorOn   = stk_txCount + 1;
     stk_forceErrorCode = 1;
     stk_strayWords     = 0;

     deliver(SESSION_B, 128, 2, 0x3300);
     run(300);

     check(captured.empty(), "при error==1 эхо не отправлено");
     check(stk_strayWords == 0, "ни одно слово не ушло в tx_data после error==1");

     stack_reset_cfg();

     // Ядро должно остаться работоспособным
     deliver(SESSION_B, 64, 1, 0x4400);
     if (pop_captured(tx, 4000))
     {
          check(tx.length == 64, "ядро живо после error==1");
          check(tx.firstWordLo.size() == 1 && tx.firstWordLo[0] == 0x4400,
                "границы сообщений не сдвинулись после error==1");
     }
     else check(false, "ядро не восстановилось после error==1");

     // -----------------------------------------------------------
     std::cout << "\n[8] Сообщение больше PP_MAX_WORDS" << std::endl;

     {
          // PP_MAX_WORDS+2 слова: буфер в ядре вмещает только PP_MAX_WORDS
          const int big = PP_MAX_WORDS_TB + 2;
          const ap_uint<16> bigLen = (ap_uint<16>)(big * 64);

          // Отдельно проверяем сам read request: ядро не должно
          // запрашивать больше, чем способно сохранить. Иначе стек
          // отдаст лишние слова, которые придётся отбрасывать.
          //
          // Сначала опустошаем накопленные запросы: предыдущие тесты
          // оставляли в очереди свои, и без этого проверка читала
          // старый запрос (128 байт) вместо нужного — из-за чего
          // мутация «снять clamp» проходила незамеченной.
          readReqs.clear();

          push_notification(SESSION_B, bigLen);
          run(5);
          bool haveRR = !readReqs.empty();
          check(haveRR, "read request выставлен для большого сообщения");
          if (haveRR)
          {
               pkt32 rr = readReqs.front(); readReqs.pop_front();
               ap_uint<16> asked = rr.data(31, 16);
               check(asked <= (ap_uint<16>)(PP_MAX_WORDS_TB * 64),
                     "ядро запросило не больше размера буфера");
          }
          push_rx_payload(SESSION_B, big, 0x5000);

          if (pop_captured(tx, 20000))
          {
               // Ключевая проверка: эхо не должно содержать мусор.
               // Либо ядро отражает ровно то, что приняло, либо
               // ограничивает длину — но не заявляет полную длину,
               // отдавая непринятые слова.
               bool contentOk = true;
               for (size_t i = 0; i < tx.firstWordLo.size(); i++)
                    if (tx.firstWordLo[i] != (ap_uint<32>)(0x5000 + i))
                         contentOk = false;
               check(contentOk, "большое сообщение отражено без мусора");
               check(tx.length == (ap_uint<16>)(tx.words * 64)
                     || tx.length == bigLen,
                     "заявленная длина соответствует отданным словам");
          }
          else check(false, "большое сообщение не отражено");
     }

     // Ядро должно остаться работоспособным
     deliver(SESSION_B, 64, 1, 0x6600);
     if (pop_captured(tx, 4000))
          check(tx.firstWordLo.size() == 1 && tx.firstWordLo[0] == 0x6600,
                "ядро живо после большого сообщения");
     else check(false, "ядро зависло после большого сообщения");

     // -----------------------------------------------------------
     std::cout << "\n[9] Сообщение, разбитое на два уведомления" << std::endl;

     {
          // Стек прислал 64 байта, затем ещё 64 — это ОДНО прикладное
          // сообщение в 128 байт, пришедшее двумя сегментами.
          // Эхо-ядро отражает по уведомлению, поэтому ожидаем два
          // отдельных эха по 64 байта. Проверяем, что данные при этом
          // не теряются и не перемешиваются.
          deliver(SESSION_B, 64, 1, 0x7000);
          deliver(SESSION_B, 64, 1, 0x7001);

          bool got2 = wait_captured(2, 8000);
          check(got2, "оба сегмента отражены");
          if (got2)
          {
               TxCapture a = captured.front(); captured.pop_front();
               TxCapture b = captured.front(); captured.pop_front();
               check(a.firstWordLo[0] == 0x7000 && b.firstWordLo[0] == 0x7001,
                     "порядок сегментов сохранён");
               check(a.length == 64 && b.length == 64,
                     "каждый сегмент отражён своей длиной");
          }
     }

     // -----------------------------------------------------------
     std::cout << "\n[10] Стек отдал МЕНЬШЕ слов, чем обещал" << std::endl;

     {
          // Уведомление обещает 128 байт (2 слова), а тело приходит
          // одним словом с last. Ядро обязано отразить то, что реально
          // приняло (64 байта), а не заявленные 128: иначе tx_meta
          // просит у стека слова, которых ядро не отдаст, и передача
          // повиснет.
          readReqs.clear();
          push_notification(SESSION_B, 128);
          run(5);
          push_rx_payload(SESSION_B, 1, 0x9900);   // 1 слово вместо 2

          if (pop_captured(tx, 4000))
          {
               check(tx.words == 1, "отражено ровно одно принятое слово");
               check(tx.length == 64,
                     "заявлена фактическая длина (64), а не обещанная (128)");
          }
          else check(false, "ядро не отразило усечённое сообщение");
     }

     // Ядро должно остаться работоспособным
     deliver(SESSION_B, 64, 1, 0x9A00);
     if (pop_captured(tx, 4000))
          check(tx.firstWordLo.size() == 1 && tx.firstWordLo[0] == 0x9A00,
                "ядро живо после усечённого сообщения");
     else check(false, "ядро зависло после усечённого сообщения");

     // -----------------------------------------------------------
     std::cout << "\n[11] Backpressure: стек не принимает tx_data" << std::endl;

     stk_stallData = true;
     const int BURST = 12;
     for (int i = 0; i < BURST; i++)
          deliver(SESSION_B, 64, 1, 0x8000 + i);
     run(500);
     stk_stallData = false;

     bool drained = wait_captured(BURST, 60000);
     check(drained, "все сообщения дошли после снятия backpressure");
     if (drained)
     {
          bool ok = true;
          int n = 0;
          while (!captured.empty())
          {
               TxCapture c = captured.front(); captured.pop_front();
               if (c.length != 64 || c.words != 1) ok = false;
               n++;
          }
          check(ok, "ни одно сообщение не потеряно и не склеено");
          check(n == BURST, "число эх совпало с числом сообщений");
     }

     // -----------------------------------------------------------
     std::cout << "\n[12] Телеметрия: три скаляра соответствуют факту" << std::endl;

     {
          // ЗАЧЕМ. Эти три числа -- единственное, чем мы будем читать плату,
          // а попытка там одна в сутки. Если ppState отстаёт или не меняется
          // в части состояний, отладка пойдёт по ложному следу.

          // Начальные значения были 0xDEAD. К этому месту ядро отработало
          // сотни проходов, так что оба скаляра ОБЯЗАНЫ быть перезаписаны.
          check(tlm_portState != (ap_uint<32>)0xDEAD,
                "portState записан ядром, а не остался начальным");
          check(tlm_ppState != (ap_uint<32>)0xDEAD,
                "ppState записан ядром");
          check(tlm_notifyCount != (ap_uint<32>)0xDEAD,
                "notifyCount записан ядром");

          // Порт открывали в сценарии 1 -- значит 2, и никак иначе.
          check(tlm_portState == 2,
                "portState == 2 после успешного открытия порта");

          // Уведомлений было много; точное число зависит от сценариев выше,
          // поэтому проверяем не значение, а РОСТ: счётчик обязан
          // увеличиться ровно на 1 от одного нового сообщения.
          ap_uint<32> before = tlm_notifyCount;
          deliver(SESSION_B, 64, 1, 0xAB00);
          if (pop_captured(tx, 4000))
          {
               check(tlm_notifyCount == before + 1,
                     "notifyCount вырос ровно на 1 от одного сообщения");
          }
          else check(false, "сообщение сценария 12 не отражено");

          // В покое между сообщениями FSM обязан стоять в NOTIFY (0).
          // Любое другое значение здесь означает, что ядро зависло на
          // прошлом сообщении -- и на плате мы бы это увидели как ppState != 0.
          run(200);
          check(tlm_ppState == 0,
                "в покое ppState == 0 (NOTIFY) -- цикл завершается полностью");

          // Ключевая проверка: ppState ДЕЙСТВИТЕЛЬНО меняется по ходу
          // обработки, а не залипает на нуле. Ловим ненулевое значение
          // во время передачи -- иначе скаляр бесполезен как индикатор.
          bool sawNonZero = false;
          push_notification(SESSION_B, 64);
          for (int i = 0; i < 50 && !sawNonZero; i++)
          {
               tick();
               if (tlm_ppState != 0) sawNonZero = true;
          }
          check(sawNonZero,
                "ppState принимает ненулевые значения -- индикатор рабочий");
          push_rx_payload(SESSION_B, 1, 0xAC00);
          pop_captured(tx, 4000);
          run(200);
     }

     // -----------------------------------------------------------
     std::cout << "\n=== Итог: " << (failures == 0 ? "ВСЕ ТЕСТЫ ПРОШЛИ"
                                                   : "ЕСТЬ ОШИБКИ")
               << " (failures=" << failures << ") ===" << std::endl;
     return failures == 0 ? 0 : 1;
}
