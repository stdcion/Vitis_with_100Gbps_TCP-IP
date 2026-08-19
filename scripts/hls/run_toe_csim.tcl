# =============================================================================
# run_toe_csim.tcl -- csim TOE С НАШИМИ ФЛАГАМИ СБОРКИ
# =============================================================================
#
# ЗАЧЕМ. Дамп с платы 19.08 показал: сервер отправляет SYN-ACK на 0.0.0.0
# (наблюдение пользователя в Wireshark на dual_echo, подтверждено числами
# probe -- ARP уходит на несуществующий шлюз, потому что dstIp сессии нулевой).
#
# Цепочка по коду прослежена до конца:
#   SYN-ACK dstIp <- reverseLookupTable[sessionID].theirIp  (session_lookup:288)
#                 <- intQuery.tuple                         (:150, :183)
#                 <- sessionLookupQuery(tuple, ...)          (rx_engine:905)
#                 <- tupleBufferIn                           (:866)
#                 <- fourTuple(header.getSrcAddr(), ...)     (:475, PSEUDO-HEADER)
#
# Последнее звено внутри TOE и по коду не проверяется. csim его показывает:
# rx_engine печатает "RX_SYN: session id:... seqNum:...", tx_engine печатает
# "TX_SYN_ACK session id:... seqNum:... ackNum:...".
#
# ПОЧЕМУ НЕ run_hls.csim.tcl. Тот собирает БЕЗ -cflags, то есть с дефолтами:
# WINDOW_SCALE не определён (у нас 1, WINDOW_BITS 18 против 16), RX_DDR_BYPASS
# не определён (у нас 1). Это ДРУГОЙ код, и его результат к нашему битстриму
# отношения не имеет. Флаги ниже скопированы из фактического лога нашей сборки
# (cmake_make_ip.txt:3526).
#
# ═══ RX_DDR_BYPASS=1 -- КАК НА ПЛАТЕ. РАСХОЖДЕНИЯ НЕТ ═══════════════════════
#
# Сначала здесь стоял 0, потому что при 1 не компилировалось. Причина была НЕ в
# этом флаге: тестбенч зовёт toe(), а в заголовок выведена только toe_core, и
# типы у них разные (ap_axiu против net_axis). См. пояснение к set_top выше.
#
# toe_core НЕ МЕНЯЕТ СИГНАТУРУ от RX_DDR_BYPASS: rxBufferWriteStatus присутствует
# всегда (toe.hpp:177, без #if). Внутри тела флаг работает (7 вхождений), но
# интерфейс один. Поэтому можно поставить 1 -- ровно как в нашей сборке, и
# результат csim будет относиться к тому же коду, что в битстриме.
#
# ВЕКТОР io_fin_5.dat уже воспроизводит нашу ситуацию: myIpAddress=0x01010101,
# а кадр адресован 1.1.1.1 от 10.10.10.10 -- то есть сервер принимает SYN от
# клиента, ровно как на плате.
#
# Запуск (с сборочной машины, где есть Vitis HLS):
#     cd fpga-network-stack/hls/toe
#     vitis_hls -f ../../../scripts/hls/run_toe_csim.tcl 2>&1 | tee ~/toe_csim.log
#
# ЧТО ИСКАТЬ В ЛОГЕ:
#     grep -E "RX_SYN|TX_SYN_ACK|forwarding|dropping" ~/toe_csim.log
#
# "dropping packet, ip valid: 0" означает, что ip_handler отбросил кадр по
# несовпадению адреса (ip_handler.cpp:155). "RX_SYN" без последующего
# "TX_SYN_ACK" -- сессия не создалась. Оба случая объясняют 0.0.0.0.

# ── АБСОЛЮТНЫЙ ПУТЬ К ШИМУ ──────────────────────────────────────────────────
# Относительный путь в -include НЕ РАБОТАЕТ: clang запускается из
# <project>/<solution>/csim/build, а не из каталога, где лежит скрипт. Ровно та
# же ловушка, что с путями к тестовым векторам (там ../../../../), но там она
# была видна из штатного скрипта, а здесь я её повторил.
#
# [info script] даёт путь к этому .tcl, куда бы его ни положили -- надёжнее,
# чем считать уровни вложенности руками.
set SHIM [file normalize [file join [file dirname [info script]] toe_csim_shim.hpp]]
puts "shim: $SHIM"

open_project toe_csim_prj

# ── ПОЧЕМУ toe_core, А НЕ toe ────────────────────────────────────────────────
# Штатный run_hls.csim.tcl ставит `set_top toe`, и это НЕ РАБОТАЕТ:
#   toe.hpp объявляет ТОЛЬКО toe_core (:175);
#   toe() определена в toe.cpp (:826), но в заголовок не выведена, поэтому
#   тестбенч её не видит -- отсюда "use of undeclared identifier 'toe'".
# Кроме того типы не совпадают: toe() принимает ap_axiu, а тестбенч объявляет
# ipRxData как stream<net_axis<DATA_WIDTH>> (toe_tb.cpp:575) -- ровно то, что
# ждёт toe_core. То есть тестбенч написан под toe_core, и штатный скрипт просто
# устарел вместе с двумя другими своими ошибками (dummy_memory.cpp, RX_DDR_BYPASS).
set_top toe_core

# Флаги -- ТЕ ЖЕ, что в нашей сборке битстрима. Менять только вместе с
# CMakeLists.txt, иначе csim и железо разойдутся.
set OUR_FLAGS "-DFNS_DATA_WIDTH=64 -DTCP_NODELAY=1 -DTCP_MSS=4096 \
-DTCP_STACK_MAX_SESSIONS=1000 -DRX_DDR_BYPASS=1 -DFAST_RETRANSMIT=1 \
-DWINDOW_SCALE=1 -DFNS_ROCE_STACK_MAX_QPS=500 -Wno-unknown-pragmas"

foreach f {../axi_utils.cpp
           ack_delay/ack_delay.cpp
           close_timer/close_timer.cpp
           event_engine/event_engine.cpp
           port_table/port_table.cpp
           probe_timer/probe_timer.cpp
           retransmit_timer/retransmit_timer.cpp
           rx_app_if/rx_app_if.cpp
           rx_app_stream_if/rx_app_stream_if.cpp
           rx_engine/rx_engine.cpp
           rx_sar_table/rx_sar_table.cpp
           session_lookup_controller/session_lookup_controller.cpp
           state_table/state_table.cpp
           tx_app_if/tx_app_if.cpp
           tx_app_stream_if/tx_app_stream_if.cpp
           tx_engine/tx_engine.cpp
           tx_sar_table/tx_sar_table.cpp
           tx_app_interface/tx_app_interface.cpp
           toe.cpp} {
     add_files $f -cflags $OUR_FLAGS
}
# ── ШИМ ВМЕСТО ПРАВКИ АПСТРИМНОГО ТЕСТБЕНЧА ─────────────────────────────────
# toe_tb.cpp зовёт toe(), которой нет в заголовке. Шим даёт ей определение --
# переброс в toe_core<DATA_WIDTH>. Подробности и две провалившиеся попытки
# (-Dtoe=..., отдельный .cpp) -- в шапке scripts/hls/toe_csim_shim.hpp.
# -include вставляет шим перед первой строкой toe_tb.cpp, апстримный файл не
# тронут. Путь АБСОЛЮТНЫЙ (см. set SHIM выше).
add_files -tb toe_tb.cpp -cflags "$OUR_FLAGS -include $SHIM"

open_solution "sol_csim"
# Часть и клок для csim не важны (RTL не генерируется), но нужны для solution.
set_part {xcu200-fsgd2104-2-e}
create_clock -period 6.06 -name default

# ПУТИ -- ЧЕТЫРЕ УРОВНЯ ВВЕРХ, и это не описка. csim запускает тестбенч из
# <project>/<solution>/csim/build, поэтому относительные пути к векторам
# отсчитываются оттуда, а не от каталога проекта. Так же сделано в штатном
# run_hls.csim.tcl:33 -- сверено с ним, а не угадано.
#
# argv: mode(0=rx) input rxOutput txOutput gold
csim_design -clean -argv {0 ../../../../testVectors/io_fin_5.dat ../../../../testVectors/rxOutput.dat ../../../../testVectors/txOutput.dat ../../../../testVectors/rx_io_fin_5.gold}

exit
