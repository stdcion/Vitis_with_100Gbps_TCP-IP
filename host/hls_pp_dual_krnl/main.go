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

func main() {
	host := flag.String("host", "", "IP платы (обязательно)")
	port := flag.Int("port", 7001, "TCP-порт")
	msgBytes := flag.Int("bytes", 64, "размер сообщения, 1..4096")
	count := flag.Int("count", 10000, "сколько сообщений измерять")
	warmup := flag.Int("warmup", 1000, "прогрев (не входит в статистику)")
	verifyAll := flag.Bool("verify", false, "сверять КАЖДОЕ эхо (по умолчанию только прогрев)")
	csvPath := flag.String("csv", "", "файл для сырых сэмплов (пусто = не писать)")
	timeout := flag.Duration("timeout", 5*time.Second, "таймаут на соединение и чтение")
	flag.Parse()

	if *host == "" {
		fmt.Fprintln(os.Stderr, "ОШИБКА: не задан -host")
		flag.Usage()
		os.Exit(2)
	}
	if *msgBytes < 1 || *msgBytes > maxMsgBytes {
		fmt.Fprintf(os.Stderr, "ОШИБКА: -bytes должно быть 1..%d (PP_MAX_WORDS*64 в ядре)\n", maxMsgBytes)
		os.Exit(2)
	}
	if *count < 1 {
		fmt.Fprintln(os.Stderr, "ОШИБКА: -count должно быть > 0")
		os.Exit(2)
	}

	// Привязка горутины к потоку ОС. Не даёт привязки к ядру CPU (её в Go нет
	// без cgo), но убирает миграцию горутины между потоками -- один источник
	// шума меньше.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	zeroFrac, gran, ovh := calibrateClock()

	fmt.Printf("=== Измеритель ===\n")
	fmt.Printf("платформа      : %s/%s, Go %s\n", runtime.GOOS, runtime.GOARCH, runtime.Version())
	fmt.Printf("источник времени: %s\n", clockName())
	fmt.Printf("гранулярность  : %d ns (мин. ненулевая разница двух вызовов)\n", gran)
	fmt.Printf("оверхед вызова : %d ns (медиана пары вызовов)\n", ovh)
	if gran > 200 {
		fmt.Printf("  ВНИМАНИЕ: таймер квантует шагом ~%d ns -- RTT округляется\n", gran)
		fmt.Printf("  до этой величины. При RTT ~3000 ns это погрешность ~%.1f%%\n",
			100.0*float64(gran)/3000.0)
	}
	// Доля нулевых разниц -- прямой ответ на вопрос "годится ли таймер".
	// В C-версии на macOS CLOCK_MONOTONIC давал 97% нулей, то есть при RTT
	// в микросекунды показывал бы мусор. Если здесь близко к 100%, измерять
	// нечем и надо это видеть до запуска, а не после.
	fmt.Printf("нулевых разниц : %.1f%% пар вызовов", zeroFrac*100)
	if zeroFrac > 0.9 {
		fmt.Printf("  <-- ТАЙМЕР СЛИШКОМ ГРУБЫЙ ДЛЯ ЭТИХ ИЗМЕРЕНИЙ")
	}
	fmt.Println()
	fmt.Printf("привязка к CPU : нет (в Go недоступна без cgo -- хвосты p99 будут шумными)\n")
	fmt.Println()

	addr := net.JoinHostPort(*host, strconv.Itoa(*port))
	fmt.Printf("подключаюсь к %s ...\n", addr)

	conn, err := net.DialTimeout("tcp", addr, *timeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nСОЕДИНЕНИЕ НЕ УСТАНОВЛЕНО: %v\n\n", err)
		fmt.Fprintln(os.Stderr, "Что это значит:")
		fmt.Fprintln(os.Stderr, "  connection refused -> порт на плате НЕ открыт. Проверьте portState")
		fmt.Fprintln(os.Stderr, "                        через pp_dual_dump: 0 или 1 = listen не удался.")
		fmt.Fprintln(os.Stderr, "  timeout            -> SYN ушёл, ответа нет. То же молчание, что было")
		fmt.Fprintln(os.Stderr, "                        у dual_echo. Смотрите portState и ppState.")
		fmt.Fprintln(os.Stderr, "  no route to host   -> ARP не разрешился, проверьте адреса и линк.")
		os.Exit(1)
	}
	defer conn.Close()

	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		fmt.Fprintln(os.Stderr, "ОШИБКА: соединение не TCP")
		os.Exit(1)
	}
	// КРИТИЧНО: без этого алгоритм Нейгла придержит мелкие пакеты до
	// подтверждения предыдущего, и вместо задержки сети мы измерим Нейгла.
	if err := tcp.SetNoDelay(true); err != nil {
		fmt.Fprintf(os.Stderr, "ВНИМАНИЕ: TCP_NODELAY не установлен: %v\n", err)
		fmt.Fprintln(os.Stderr, "  Измерения будут искажены алгоритмом Нейгла.")
	}

	fmt.Printf("подключено. msg=%d байт, count=%d, warmup=%d\n\n",
		*msgBytes, *count, *warmup)

	tx := make([]byte, *msgBytes)
	rx := make([]byte, *msgBytes)
	for i := range tx {
		tx[i] = byte(i & 0xFF)
	}

	samples := make([]int64, 0, *count)
	mismatches := 0
	total := *warmup + *count

	for i := 0; i < total; i++ {
		if err := conn.SetDeadline(time.Now().Add(*timeout)); err != nil {
			fmt.Fprintf(os.Stderr, "SetDeadline: %v\n", err)
			break
		}

		t0 := time.Now()

		if _, err := conn.Write(tx); err != nil {
			fmt.Fprintf(os.Stderr, "\nОШИБКА ОТПРАВКИ после %d сообщений: %v\n", i, err)
			break
		}
		// ReadFull: TCP может отдать эхо частями, и без дочитывания
		// RTT получился бы меньше настоящего.
		if _, err := io.ReadFull(conn, rx); err != nil {
			fmt.Fprintf(os.Stderr, "\nЭХО НЕ ПРИШЛО после %d сообщений: %v\n", i, err)
			if i == 0 {
				fmt.Fprintln(os.Stderr, "\nНи одного эха. Соединение установлено, но ядро не отвечает.")
				fmt.Fprintln(os.Stderr, "Читайте ppState через pp_dual_dump -- он назовёт шаг, где встало:")
				fmt.Fprintln(os.Stderr, "  0 NOTIFY  уведомление до ядра не дошло")
				fmt.Fprintln(os.Stderr, "  2 RX      данные идут, но tlast не пришёл")
				fmt.Fprintln(os.Stderr, "  4 STATUS  стек не ответил на tx_meta -- TX-путь достигнут")
				fmt.Fprintln(os.Stderr, "  5 TX      слова не принимаются, backpressure")
			}
			break
		}

		t1 := time.Now()

		// Сверка ВНЕ измеряемого интервала: сравнение больших сообщений
		// вытесняет данные из кэша и добавляет шум СЛЕДУЮЩЕМУ сэмплу.
		// Поэтому по умолчанию сверяем только прогрев.
		if *verifyAll || i < *warmup {
			if !equalBytes(tx, rx) {
				mismatches++
			}
		}

		if i >= *warmup {
			samples = append(samples, t1.Sub(t0).Nanoseconds())
		}
	}

	if len(samples) == 0 {
		fmt.Fprintln(os.Stderr, "\nНи одного сэмпла не собрано.")
		os.Exit(1)
	}

	report(samples, *msgBytes, mismatches, *verifyAll, gran)

	if *csvPath != "" {
		if err := writeCSV(*csvPath, samples); err != nil {
			fmt.Fprintf(os.Stderr, "не удалось записать %s: %v\n", *csvPath, err)
		} else {
			fmt.Printf("\nсырые сэмплы: %s (%d строк)\n", *csvPath, len(samples))
		}
	}
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

func clockName() string {
	switch runtime.GOOS {
	case "linux":
		return "clock_gettime(CLOCK_MONOTONIC), разрешение ~1 ns"
	case "darwin":
		return "mach_absolute_time, разрешение ~40 ns"
	case "windows":
		return "QueryPerformanceCounter, разрешение ~100 ns (QPC обычно 10 MHz)"
	default:
		return "монотонные часы платформы"
	}
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

func report(samples []int64, msgBytes, mismatches int, verifyAll bool, gran int64) {
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

	fmt.Printf("=== RTT приложение-приложение ===\n")
	fmt.Printf("сэмплов    : %d\n", len(samples))
	fmt.Printf("размер msg : %d байт\n", msgBytes)
	if verifyAll {
		fmt.Printf("сверка     : все сообщения\n")
	} else {
		fmt.Printf("сверка     : только прогрев\n")
	}
	if mismatches > 0 {
		fmt.Printf("РАСХОЖДЕНИЙ: %d -- ЭХО ОТЛИЧАЕТСЯ ОТ ОТПРАВЛЕННОГО!\n", mismatches)
		fmt.Printf("  Это дефект ядра, не измерителя. Смотрите pp_echo:\n")
		fmt.Printf("  keep последнего слова, границы payload[], txLength.\n")
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
	fmt.Printf("выбросы    : %d (%.2f%%, > 2x p50)\n",
		outliers, 100.0*float64(outliers)/float64(len(samples)))
	fmt.Println()
	fmt.Printf("Односторонняя задержка ~ p50/2 = %.3f us (если путь симметричен)\n", p50/2000.0)
	fmt.Printf("Погрешность измерителя ~ %d ns (гранулярность таймера)\n", gran)
	fmt.Println()
	fmt.Printf("ЧТО ВХОДИТ В ЭТО ЧИСЛО, а что нет:\n")
	fmt.Printf("  входит : сисколлы Write/Read, драйвер NIC, сама NIC, провод,\n")
	fmt.Printf("           CMAC, стек TOE в обе стороны, ядро pp_echo\n")
	fmt.Printf("  НЕ видно: сколько из этого ядро, а сколько стек. Для разбивки\n")
	fmt.Printf("           нужна врезка времени на axis_net (отдельный заход).\n")
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
