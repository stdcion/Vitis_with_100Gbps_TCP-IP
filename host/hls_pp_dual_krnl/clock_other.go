//go:build !windows

package main

// На Linux и macOS time.Now() использует монотонные часы платформы с
// разрешением ~1 нс и ~40 нс соответственно -- этого достаточно, отдельный
// счётчик не нужен.
//
// Отдельный файл, а не if runtime.GOOS: syscall-вызовы Windows не должны
// попадать в сборку под другие платформы даже мёртвым кодом.

import "time"

// БАЗОВАЯ ТОЧКА, А НЕ UnixNano. Первая версия возвращала
// time.Now().UnixNano() -- и разрешение упало с 41 нс до 1000 нс: UnixNano
// ОТБРАСЫВАЕТ монотонную часть (документация time: "t.UnixNano() ... strip the
// monotonic clock reading"). Sub от фиксированной базы её сохраняет.
var base = time.Now()

func nowTicks() int64         { return int64(time.Since(base)) }
func ticksToNs(d int64) int64 { return d }
func clockName() string       { return "time.Now (monotonic)" }
