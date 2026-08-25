#!/bin/sh
# Кросс-сборка клиента. Запускать на macOS/Linux, бинарники годятся везде.
#
# Go статически линкует всё, что нужно (сетевой стек тут чистый Go, cgo не
# задействован), поэтому .exe работает на любой Windows без установки Go,
# runtime и DLL. Это и была причина выбрать Go: разработка на macOS, запуск
# на Windows у платы.
set -e
cd "$(dirname "$0")"

gofmt -l . | grep . && { echo "*** gofmt: есть неотформатированные файлы"; exit 1; } || true
go vet ./...

mkdir -p bin

echo "windows/amd64 ..."
GOOS=windows GOARCH=amd64 go build -trimpath -o bin/ppclient.exe .

echo "linux/amd64 ..."
GOOS=linux GOARCH=amd64 go build -trimpath -o bin/ppclient-linux .

echo "darwin/arm64 ..."
GOOS=darwin GOARCH=arm64 go build -trimpath -o bin/ppclient-macos .

echo
ls -lh bin/
echo
echo "Копировать на машину у платы: bin/ppclient.exe"
echo "Запуск (Windows, cmd или powershell):"
echo "  ppclient.exe -host 192.168.10.10 -port 7001 -bytes 64 -count 100000 -csv rtt.csv"
