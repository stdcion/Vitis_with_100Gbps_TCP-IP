// Клиент-измеритель для hls_pp_dual_krnl (TCP-эхо на половине a).
//
// Подключается к плате по TCP, шлёт сообщения фиксированного размера и меряет
// RTT каждого: отправил -> получил эхо обратно. Это полный путь
//
//	приложение -> NIC -> провод -> CMAC -> стек TOE -> ядро ->
//	стек TOE -> CMAC -> провод -> NIC -> приложение
//
// Методика перенесена из host/hls_pingpong_krnl/pingpong_client.c, где она
// отрабатывалась на C. Go выбран потому, что запуск идёт на Windows, а
// разработка на macOS: кросс-компиляция здесь одна команда и даёт бинарник
// без зависимостей (см. build.sh).
//
// ТОЧНОСТЬ: ЧТО НАДО ЗНАТЬ ПРО ТАЙМЕР В GO.
//
// time.Now() в Go использует монотонные часы платформы, и разрешение у них
// РАЗНОЕ:
//
//	Linux    clock_gettime(CLOCK_MONOTONIC)   ~1 нс, точность высокая
//	macOS    mach_absolute_time               ~40 нс
//	Windows  QueryPerformanceCounter          ~100 нс (частота QPC обычно
//	                                          10 МГц), НО системный таймер
//	                                          планировщика 15.6 мс
//
// Для RTT в единицы микросекунд разрешение QPC (~100 нс) даёт погрешность
// порядка 2-5%. Это приемлемо, но КАЛИБРОВКА ОБЯЗАТЕЛЬНА -- программа меряет
// гранулярность при старте и печатает её отдельной строкой, чтобы граница
// собственной погрешности была видна, а не подразумевалась.
//
// ЧЕГО ЗДЕСЬ НЕТ: вычитания "накладных расходов" из RTT. Оверхед таймера
// печатается справочно, но не вычитается -- вызовы Write/Read это неотделимая
// часть измеряемого пути, а не аддитивная поправка.
//
// ОТЛИЧИЕ ОТ C-ВЕРСИИ: нет --cpu и --rt (привязки к ядру и SCHED_FIFO).
// В Go горутина мигрирует между потоками ОС, и runtime.LockOSThread() даёт
// только привязку к потоку, не к ядру CPU. Поэтому хвосты p99/p99.9 здесь
// шумнее, чем у C-версии на Linux с --cpu --rt. Медиана и min от этого не
// страдают, а именно они интересны для сравнения с бюджетом задержки.
//
// Сборка под Windows с macOS:
//
//	GOOS=windows GOARCH=amd64 go build -o ppclient.exe .
//
// Запуск:
//
//	ppclient.exe -host 10.1.212.153 -port 7001 -bytes 64 -count 100000
package main

import (
	"encoding/binary"
	"encoding/csv"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"runtime"
	"sort"
	"strconv"
	"time"
)

// Максимум, который принимает ядро: PP_MAX_WORDS(64) * 64 байта.
// Больше ядро усечёт, и эхо придёт короче отправленного -- клиент это
// заметит как ошибку чтения, но лучше не давать отправить.
const maxMsgBytes = 4096

// МАРКЕР, ПО КОТОРОМУ ЖЕЛЕЗО УЗНАЁТ НАШ ПАКЕТ.
//
// На axis_net_* идёт весь трафик стека, и врезка времени защёлкнулась бы на
// первом же ARP или ACK. Фильтр в железе (net_frame_filter.v) отличает наш
// кадр по двум признакам: длине в 512-битных словах и вот этой константе в
// payload.
//
// ПОЧЕМУ КОНСТАНТУ ПИШЕТ КЛИЕНТ, А НЕ ЯДРО. У probe-ядра пакет генерировало
// само ядро и маркер вписывало в исходящий кадр. Здесь ядро -- эхо: оно
// копирует payload клиента как есть (pp_echo: payload[wordCount] =
// rx_word.data). Значит маркер приходит от клиента -- и это лучше, а не
// хуже: он виден в ОБЕ стороны, и на axis_net_rx, и на axis_net_tx, потому
// что эхо его сохраняет. У probe на входящем кадре маркера не было вовсе.
//
// СМЕЩЕНИЕ 4..9 ФИКСИРОВАНО. Заголовки перед payload -- Ethernet 14 + IP 20
// + TCP 20 = 54 байта, и это неизменно: опции TCP стек добавляет только в
// SYN. Значит payload[4..9] попадает на байты 58..63 кадра, то есть на биты
// 464..511 ПЕРВОГО 512-битного слова -- при любом размере сообщения.
//
// Байты 0..3 отданы под номер сообщения: он меняется каждый пакет, поэтому
// как константу его сравнить нельзя. Заодно он помогает при разборе
// захвата -- видно, какой именно пакет на экране.
//
// ПОРЯДОК БАЙТ ЗДЕСЬ ОБРАТНЫЙ К HEX-ЗАПИСИ, И ЭТО НЕ ОПЕЧАТКА.
//
// Фильтр сравнивает tdata[511:464] == 48'h5A3C96E1B7D2. В AXI-Stream байт k
// слова лежит в битах [8k+7:8k], поэтому старший hex-байт (0x5A) попадает в
// старшие биты 511..504 -- то есть в байт кадра 63, а он равен payload[9].
// Младший hex-байт (0xD2) оказывается в payload[4].
//
//	payload[4]=D2  [5]=B7  [6]=E1  [7]=96  [8]=3C  [9]=5A
//
// Проверено раскладкой по битам, и то же самое делает probe-ядро:
// word.data(79,32) = 0x5A3C96E1B7D2 кладёт 0xD2 в payload[4]
// (hls_echo_probe_dual_krnl.cpp:457). Первая версия этого клиента писала
// прямой порядок -- фильтр не узнал бы ни одного кадра, а симптом был бы
// обманчивым: count_drop растёт, count_ours ноль, то есть неотличимо от
// "порог длины завышен".
//
// Значение должно совпадать с EPD_MARKER в net_frame_filter.v.
var marker = [6]byte{0xD2, 0xB7, 0xE1, 0x96, 0x3C, 0x5A}

// Минимальный размер сообщения: 4 байта номера + 6 байт маркера.
// Меньше -- маркер не влезет, железо не узнает пакет, и врезка защёлкнется
// на чужом кадре. Молча отправить такое хуже, чем отказаться.
const minMsgBytes = 10

func main() {
	host := flag.String("host", "", "board IP (required)")
	port := flag.Int("port", 7001, "TCP port")
	msgBytes := flag.Int("bytes", 64, "message size, 1..4096")
	count := flag.Int("count", 10000, "messages to measure")
	warmup := flag.Int("warmup", 1000, "warmup (excluded from stats)")
	verifyAll := flag.Bool("verify", false, "verify EVERY echo (default: warmup only)")
	csvPath := flag.String("csv", "", "raw samples file (empty = none)")
	timeout := flag.Duration("timeout", 5*time.Second, "connect and read timeout")
	flag.Parse()

	if *host == "" {
		fmt.Fprintln(os.Stderr, "error: -host required")
		flag.Usage()
		os.Exit(2)
	}
	if *msgBytes < minMsgBytes || *msgBytes > maxMsgBytes {
		fmt.Fprintf(os.Stderr, "error: -bytes must be %d..%d (%d = marker, %d = PP_MAX_WORDS*64)\n",
			minMsgBytes, maxMsgBytes, minMsgBytes, maxMsgBytes)
		os.Exit(2)
	}
	// 32 байта payload -- порог, ниже которого наш кадр укладывается в ОДНО
	// 512-битное слово (54 байта заголовков + 32 = 86 < 64*2? нет: 86 байт =
	// два слова). Считаем точно: кадр = 54 + msgBytes байт, слов =
	// ceil(кадр/64). При msgBytes=10 это ceil(64/64) = 1 слово -- ровно
	// столько же, сколько у чистого ACK, и признак длины перестаёт работать.
	// Остаётся только маркер, а он на односоловном кадре читается с шины
	// напрямую (net_frame_filter это умеет) -- то есть фильтр всё ещё верен,
	// но запас надёжности меньше. Предупреждаем, а не запрещаем.
	if frameWords(*msgBytes) < 2 {
		fmt.Fprintf(os.Stderr, "WARNING: %d bytes -> %d-word frame, same as ACK/ARP;\n",
			*msgBytes, frameWords(*msgBytes))
		fmt.Fprintln(os.Stderr, "  hardware filter falls back to the marker alone. Use >=11 bytes.")
	}
	if *count < 1 {
		fmt.Fprintln(os.Stderr, "error: -count must be > 0")
		os.Exit(2)
	}

	// Привязка горутины к потоку ОС. Не даёт привязки к ядру CPU (её в Go нет
	// без cgo), но убирает миграцию горутины между потоками -- один источник
	// шума меньше.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	zeroFrac, gran, ovh := calibrateClock()

	// Таймер одной строкой. Числа нужны: без них "RTT 3 мкс" не отличить
	// от "таймер квантует по 1 мкс и мы видим 3 отсчёта". Предупреждения --
	// только когда есть о чём предупреждать.
	fmt.Printf("timer: gran %dns, overhead %dns, %.0f%% zero-diffs (%s)\n",
		gran, ovh, zeroFrac*100, runtime.GOOS)
	if zeroFrac > 0.9 {
		fmt.Println("WARNING: timer too coarse for microsecond RTT")
	} else if gran > 200 {
		fmt.Printf("WARNING: %dns quantum = ~%.0f%% error at 3us RTT\n",
			gran, 100.0*float64(gran)/3000.0)
	}

	addr := net.JoinHostPort(*host, strconv.Itoa(*port))

	conn, err := net.DialTimeout("tcp", addr, *timeout)
	if err != nil {
		// Одна строка: что случилось и куда смотреть. Расшифровка кодов
		// ошибок -- в README, она не меняется от прогона к прогону.
		fmt.Fprintf(os.Stderr, "connect %s: %v\n", addr, err)
		fmt.Fprintln(os.Stderr, "check portState via pp_dual_dump")
		os.Exit(1)
	}
	defer conn.Close()

	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		fmt.Fprintln(os.Stderr, "error: not a TCP connection")
		os.Exit(1)
	}
	// КРИТИЧНО: без этого алгоритм Нейгла придержит мелкие пакеты до
	// подтверждения предыдущего, и вместо задержки сети мы измерим Нейгла.
	if err := tcp.SetNoDelay(true); err != nil {
		// Не фатально, но тогда мы измерим Нейгла, а не сеть.
		fmt.Fprintf(os.Stderr, "WARNING: TCP_NODELAY failed (%v) -- Nagle will skew results\n", err)
	}

	fmt.Printf("%s: %d bytes x %d (+%d warmup)\n", addr, *msgBytes, *count, *warmup)

	tx := make([]byte, *msgBytes)
	rx := make([]byte, *msgBytes)
	for i := range tx {
		tx[i] = byte(i & 0xFF)
	}
	// Маркер поверх заполнения. Ставится ОДИН РАЗ: содержимое буфера между
	// сообщениями не меняется, а номер обновляется в цикле.
	copy(tx[4:10], marker[:])

	samples := make([]int64, 0, *count)
	mismatches := 0
	total := *warmup + *count

	for i := 0; i < total; i++ {
		if err := conn.SetDeadline(time.Now().Add(*timeout)); err != nil {
			fmt.Fprintf(os.Stderr, "SetDeadline: %v\n", err)
			break
		}

		// Номер сообщения в байты 0..3, big-endian -- чтобы в Wireshark
		// читалось слева направо. Пишется ДО t0: это часть подготовки
		// данных, а не измеряемого пути.
		binary.BigEndian.PutUint32(tx[0:4], uint32(i))

		t0 := time.Now()

		if _, err := conn.Write(tx); err != nil {
			fmt.Fprintf(os.Stderr, "send failed after %d msgs: %v\n", i, err)
			break
		}
		// ReadFull: TCP может отдать эхо частями, и без дочитывания
		// RTT получился бы меньше настоящего.
		if _, err := io.ReadFull(conn, rx); err != nil {
			// Таблица значений ppState была здесь и оказалась шумом: она не
			// зависит от прогона и живёт в README. Клиент печатает ФАКТ --
			// сколько сообщений прошло до отказа.
			fmt.Fprintf(os.Stderr, "no echo after %d msgs: %v\n", i, err)
			if i == 0 {
				fmt.Fprintln(os.Stderr, "connected but silent -- read ppState via pp_dual_dump")
			}
			break
		}

		t1 := time.Now()

		// Сверка ВНЕ измеряемого интервала: сравнение больших сообщений
		// вытесняет данные из кэша и добавляет шум СЛЕДУЮЩЕМУ сэмплу.
		// Поэтому по умолчанию сверяем только прогрев.
		if *verifyAll || i < *warmup {
			// Сравниваем ЦЕЛИКОМ, включая номер: эхо обязано вернуть ровно
			// то, что мы отправили, вместе с номером. Расхождение в номере
			// означало бы, что вернулся ответ на другой пакет -- это тоже
			// дефект, и прятать его нельзя.
			if !equalBytes(tx, rx) {
				mismatches++
			}
		}

		if i >= *warmup {
			samples = append(samples, t1.Sub(t0).Nanoseconds())
		}
	}

	if len(samples) == 0 {
		fmt.Fprintln(os.Stderr, "no samples collected")
		os.Exit(1)
	}

	report(samples, *msgBytes, mismatches, *verifyAll)

	if *csvPath != "" {
		if err := writeCSV(*csvPath, samples); err != nil {
			fmt.Fprintf(os.Stderr, "csv write failed: %v\n", err)
		} else {
			fmt.Printf("csv        : %s\n", *csvPath)
		}
	}
}

// frameWords -- сколько 512-битных слов займёт кадр с payload из n байт.
//
// Кадр = Ethernet 14 + IP 20 + TCP 20 + payload. Шина 64 байта на слово.
// Нужно, чтобы предупредить, когда наш кадр становится односоловным и
// перестаёт отличаться от ACK по длине.
func frameWords(n int) int {
	const headers = 14 + 20 + 20
	return (headers + n + 63) / 64
}

// equalBytes без reflect и bytes.Equal -- чтобы было видно, что сравнение
// простое и не аллоцирует.
func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// calibrateClock меряет собственную погрешность измерителя.
//
// Три числа, и каждое отвечает на свой вопрос:
//
//	zeroFrac -- доля пар вызовов с НУЛЕВОЙ разницей. Близко к 1 значит,
//	            что таймер не различает соседние моменты, и измерять
//	            микросекунды нечем.
//	gran     -- минимальная НЕНУЛЕВАЯ разница: шаг квантования.
//	ovh      -- медиана разницы пары вызовов: оверхед самого вызова.
//
// Без этого нельзя отличить "задержка 3 мкс" от "таймер квантует по 1 мкс
// и мы видим 3 отсчёта". В C-версии на macOS измерено: CLOCK_MONOTONIC даёт
// 97% нулевых разниц, то есть при RTT в микросекунды это был бы мусор;
// CLOCK_MONOTONIC_RAW на той же машине -- 42 нс.
func calibrateClock() (zeroFrac float64, gran, ovh int64) {
	const n = 20000

	diffs := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		a := time.Now()
		b := time.Now()
		diffs = append(diffs, b.Sub(a).Nanoseconds())
	}
	sort.Slice(diffs, func(i, j int) bool { return diffs[i] < diffs[j] })

	ovh = diffs[len(diffs)/2]

	zeros := 0
	gran = 0
	for _, d := range diffs {
		if d == 0 {
			zeros++
		} else if gran == 0 {
			gran = d
		}
	}
	return float64(zeros) / float64(n), gran, ovh
}

func percentile(sorted []int64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if len(sorted) == 1 {
		return float64(sorted[0])
	}
	// Линейная интерполяция между соседними отсчётами: при p99.9 и 10000
	// сэмплов округление до целого индекса дало бы заметный сдвиг.
	idx := p / 100.0 * float64(len(sorted)-1)
	lo := int(math.Floor(idx))
	hi := int(math.Ceil(idx))
	if lo == hi {
		return float64(sorted[lo])
	}
	frac := idx - float64(lo)
	return float64(sorted[lo])*(1-frac) + float64(sorted[hi])*frac
}

func report(samples []int64, msgBytes, mismatches int, verifyAll bool) {
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })

	var sum float64
	for _, s := range samples {
		sum += float64(s)
	}
	mean := sum / float64(len(samples))

	var varsum float64
	for _, s := range samples {
		d := float64(s) - mean
		varsum += d * d
	}
	sd := 0.0
	if len(samples) > 1 {
		sd = math.Sqrt(varsum / float64(len(samples)-1))
	}

	p50 := percentile(samples, 50)

	// Выбросы считаем относительно медианы: больше 2x -- обычно планировщик
	// или прерывание, а не сеть.
	outliers := 0
	for _, s := range samples {
		if float64(s) > 2.0*p50 {
			outliers++
		}
	}

	line := func(label string, ns float64) {
		fmt.Printf("%-11s: %9.0f ns  (%7.3f us)\n", label, ns, ns/1000.0)
	}

	if mismatches > 0 {
		// Единственное, что стоит крика: эхо не совпало с отправленным.
		// Это дефект ядра, и он делает измерение бессмысленным.
		fmt.Printf("*** %d MISMATCHES -- echo differs from sent data\n", mismatches)
	}
	fmt.Printf("\n%d samples, %d bytes", len(samples), msgBytes)
	if verifyAll {
		fmt.Printf(", all verified")
	}
	fmt.Println()
	line("min", float64(samples[0]))
	line("p50", p50)
	line("p90", percentile(samples, 90))
	line("p99", percentile(samples, 99))
	line("p99.9", percentile(samples, 99.9))
	line("max", float64(samples[len(samples)-1]))
	line("mean", mean)
	line("stddev", sd)
	fmt.Printf("outliers   : %d (%.2f%%, >2x p50)\n",
		outliers, 100.0*float64(outliers)/float64(len(samples)))
	fmt.Printf("one-way    ~ %.3f us (p50/2, if symmetric)\n", p50/2000.0)
}

func writeCSV(path string, samples []int64) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()

	if err := w.Write([]string{"sample", "rtt_ns"}); err != nil {
		return err
	}
	for i, s := range samples {
		if err := w.Write([]string{strconv.Itoa(i), strconv.FormatInt(s, 10)}); err != nil {
			return err
		}
	}
	return w.Error()
}
