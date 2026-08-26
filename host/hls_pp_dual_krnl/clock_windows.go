//go:build windows

package main

// QueryPerformanceCounter напрямую -- потому что time.Now() на Windows для
// микросекунд не годится.
//
// ПРОГОН НА ПЛАТЕ 25.08 ПОКАЗАЛ:
//
//     timer: gran 0ns, overhead 0ns, 100% zero-diffs (windows)
//     WARNING: timer too coarse for microsecond RTT
//
// Сто процентов нулевых разниц -- то есть time.Now() не различает соседние
// моменты вообще. Мой комментарий в main.go утверждал, что Go на Windows
// использует QueryPerformanceCounter; это неверно. Go берёт системное время с
// разрешением ~0.5 мс (Windows 1803+) или ~16 мс на старых версиях, см.
// golang/go#67066 -- вопрос открыт до сих пор.
//
// 0.5 мс против RTT в единицы микросекунд -- измерять нечем: любое значение
// округлится до нуля или до 500 мкс.
//
// QPC даёт сотни наносекунд (частота обычно 10 МГц) и вызывается напрямую
// через syscall без cgo. Оверхед ~20-40 нс против 4.5 нс у time.Now, но при
// RTT в микросекунды это доли процента.

import (
	"syscall"
	"time"
	"unsafe"
)

var (
	kernel32                    = syscall.NewLazyDLL("kernel32.dll")
	procQueryPerformanceCounter = kernel32.NewProc("QueryPerformanceCounter")
	procQueryPerformanceFreq    = kernel32.NewProc("QueryPerformanceFrequency")

	qpcFreq  int64   // тиков в секунду
	qpcNsPer float64 // наносекунд на тик
)

func init() {
	var f int64
	r, _, _ := procQueryPerformanceFreq.Call(uintptr(unsafe.Pointer(&f)))
	if r != 0 && f > 0 {
		qpcFreq = f
		qpcNsPer = 1e9 / float64(f)
	}
}

// qpcTicks -- сырой счётчик. Ноль означает, что QPC недоступен (не бывает на
// Windows XP+, но проверить дешевле, чем делить на ноль).
func qpcTicks() int64 {
	var t int64
	r, _, _ := procQueryPerformanceCounter.Call(uintptr(unsafe.Pointer(&t)))
	if r == 0 {
		return 0
	}
	return t
}

// nowTicks -- момент времени в тиках QPC, если он есть; иначе откат на
// time.Now, чтобы программа не падала, а печатала предупреждение о таймере.
func nowTicks() int64 {
	if qpcFreq == 0 {
		return time.Now().UnixNano()
	}
	return qpcTicks()
}

// ticksToNs -- разница тиков в наносекундах.
func ticksToNs(d int64) int64 {
	if qpcFreq == 0 {
		return d // уже наносекунды из time.Now
	}
	return int64(float64(d) * qpcNsPer)
}

func clockName() string {
	if qpcFreq == 0 {
		return "time.Now (QPC unavailable!)"
	}
	return "QueryPerformanceCounter"
}
