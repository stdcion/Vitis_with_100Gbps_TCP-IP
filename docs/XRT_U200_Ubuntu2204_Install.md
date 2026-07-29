# Установка XRT + Alveo U200 shell на Ubuntu 22.04

Пошаговая инструкция по установке Xilinx Runtime (XRT) и deployment-платформы
(shell) для карты **Alveo U200** на **Ubuntu 22.04 LTS**, с флешем shell и запуском
хост-приложения.

Каждый шаг содержит блок **Проверка** — не переходи к следующему шагу, пока текущая
проверка не прошла.

---

## 0. Контекст и правило совместимости версий

Три компонента должны быть **из одной версии** (здесь — **2024.1**):

| Компонент                   | Роль                                              | Файл (пример)                                                   |
|-----------------------------|---------------------------------------------------|-----------------------------------------------------------------|
| XRT                         | рантайм + драйвер ядра (`xocl`, `xclmgmt`)        | `xrt_202410.2.17.319_22.04-amd64-xrt.deb`                       |
| Deployment platform (shell) | статическая PCIe/DMA-обвязка, прошивается в карту | `xilinx-u200-gen3x16-xdma_2024.1_2024_0522_2343-all.deb.tar.gz` |
| `.xclbin`                   | твой битстрим, собранный в Vitis                  | результат сборки проекта                                        |

> **Правило:** `shell на карте` ↔ `XRT` ↔ `платформа сборки .xclbin` — все из одной
> линии. Несовпадение → карта не примет битстрим (`mismatch`) или не поднимется.

Платформа в этом проекте: `xilinx_u200_gen3x16_xdma` (сборка в среде Vitis 2024.1).

---

## 1. Предварительные требования

### 1.1. BIOS хоста

В BIOS/UEFI материнской платы включи:

- **Above 4G Decoding** — обязательно (U200 экспонирует большие PCIe BAR).
- **Resizable BAR** — включить, если есть.
- Карта должна стоять в слоте **PCIe Gen3 x16**.

### 1.2. ОС и права

- Ubuntu 22.04 LTS (x86_64).
- Пользователь с `sudo`.
- Доступ в интернет для установки зависимостей.

### Проверка

```bash
# Обновить ОС
sudo apt-get update && sudo apt-get upgrade

# Версия Ubuntu — должно быть 22.04
lsb_release -a

# Архитектура — должно быть x86_64
uname -m

# Карта видна на шине PCIe (Xilinx Vendor ID = 10ee)
lspci -d 10ee:
```

Ожидаемо: `lspci -d 10ee:` выводит одну-две строки с Xilinx-устройством. Если пусто —
карта не определяется хостом (проверь посадку в слоте, питание, Above 4G Decoding).

---

## 2. Скачивание пакетов с сайта AMD

Требования:

1. **Xilinx Runtime** → `xrt_202410.2.17.319_22.04-amd64-xrt.deb`
2. **Deployment Target Platform** → `xilinx-u200-gen3x16-xdma_2024.1_2024_0522_2343-all.deb.tar.gz`

Положи оба файла в одну рабочую папку, например `~/alveo_install`, и перейди в неё:

```bash
mkdir -p ~/alveo_install && cd ~/alveo_install
```

### Проверка

```bash
ls -lh ~/alveo_install
```

Ожидаемо: видны оба файла, размеры примерно `~16 MB` (xrt) и `~38 MB` (tar.gz).

---

## 3. Установка зависимостей ядра

XRT собирает kernel-модули через DKMS — нужны заголовки текущего ядра.

```bash
sudo apt update
sudo apt install -y linux-headers-$(uname -r) dkms
```

### Проверка

```bash
# Заголовки установлены для текущего ядра
dpkg -l | grep "linux-headers-$(uname -r)"

# DKMS присутствует
dkms --version
```

Ожидаемо: строка с заголовками текущего ядра и версия DKMS.

---

## 4. Установка XRT

```bash
cd ~/alveo_install
sudo apt install -y ./xrt_202410.2.17.319_22.04-amd64-xrt.deb
```

Если зависимости не разрешились:

```bash
sudo apt --fix-broken install
```

### Проверка

```bash
# Версия XRT
cat /opt/xilinx/xrt/version.json

# Kernel-модули собраны и загружены DKMS
dkms status | grep -i xrt

# Драйверы загружены в ядро
lsmod | grep -E "xocl|xclmgmt"

# Утилиты доступны после подключения окружения
source /opt/xilinx/xrt/setup.sh
which xbutil xbmgmt
```

Ожидаемо:

- `version.json` показывает версию `2.17.319` (2024.1).
- `dkms status` — статус `installed` для xrt.
- `lsmod` — присутствует хотя бы `xclmgmt` (модуль `xocl` может подгрузиться после
  флеша shell — это нормально).
- `which` находит `xbutil` и `xbmgmt`.

> Добавь в `~/.bashrc`, чтобы окружение подключалось автоматически:
> ```bash
> echo 'source /opt/xilinx/xrt/setup.sh' >> ~/.bashrc
> ```

---

## 5. Распаковка и установка deployment shell

Deployment-платформа поставляется как `.tar.gz` с несколькими `.deb` внутри.

```bash
cd ~/alveo_install
tar xzvf xilinx-u200-gen3x16-xdma_2024.1_2024_0522_2343-all.deb.tar.gz
```

Ожидаемое содержимое (4 пакета):

```
xilinx-u200-gen3x16-xdma-base_2-3498633_all.deb        # сам shell (base platform)
xilinx-u200-gen3x16-xdma-validate_2-3514848_all.deb    # validate-xclbin для проверки
xilinx-cmc-u200-u250_1.2.23-3395909_all.deb            # CMC firmware
xilinx-sc-fw-u200-u250_4.6.21-1.fd1b20d_all.deb        # SC (satellite controller) firmware
```

Проверь реальные имена (могут отличаться номерами сборки):

```bash
ls -1 *.deb
```

Установи **все четыре** одной командой — apt сам разрулит порядок и зависимости
(подставь реальные имена из вывода выше):

```bash
sudo apt install -y \
  ./xilinx-cmc-u200-u250_*.deb \
  ./xilinx-sc-fw-u200-u250_*.deb \
  ./xilinx-u200-gen3x16-xdma-base_*.deb \
  ./xilinx-u200-gen3x16-xdma-validate_*.deb
```

Если что-то не разрешилось:

```bash
sudo apt --fix-broken install
```

### Проверка

```bash
# Пакеты установлены
dpkg -l | grep -E "u200-gen3x16-xdma|cmc-u200|sc-fw-u200"

# Файлы платформы легли на диск
ls /opt/xilinx/firmware/u200/gen3x16-xdma/base/
```

Ожидаемо: 4 пакета в статусе `ii`, и в каталоге firmware присутствуют файлы shell
(`partition.xsabin` и т.п.).

> На этом шаге shell **ещё не в карте** — файлы просто установлены на хост. Флеш — далее.

---

## 6. Определение карты и её текущего статуса

```bash
source /opt/xilinx/xrt/setup.sh
xbmgmt examine
```

### Проверка / что смотреть

- Найди строку с **BDF** (Bus:Device.Function), например `0000:01:00.0` — он понадобится
  во всех следующих командах.
- Смотри блок **Flash** / **Platform**:
    - `Current` — что сейчас в карте (может быть старый shell или заводской `golden`).
    - если предлагается более новая base-платформа — значит флеш нужен.

Сохрани свой BDF в переменную для удобства (подставь реальный):

```bash
export BDF=0000:01:00.0
```

---

## 7. Флеш base shell в карту

Прошивает shell + SC/CMC firmware в flash карты.

```bash
xbmgmt program --base --device $BDF
```

- Процесс идёт несколько минут. **НЕ прерывай и не выключай питание во время флеша.**
- В конце попросит подтверждение — соглашайся (`y`).

### Проверка

Команда завершается сообщением об успехе и указанием, что нужен **cold reboot**.
Если появилась ошибка о несовпадении — вернись к разделу 0 (версии).

---

## 8. Cold reboot (обязательно)

Новый SC-firmware активируется только после **полного отключения питания**, а не
обычного `reboot`.

```bash
sudo shutdown -h now
```

Затем **физически включи** машину (или через IPMI/BMC полный power-cycle).

> Обычный `reboot` не переинициализирует satellite controller — shell будет числиться
> как не активированный. Только полное выключение.

---

## 9. Проверка после cold reboot

```bash
source /opt/xilinx/xrt/setup.sh
xbmgmt examine
```

### Проверка / что смотреть

- **Platform (Current) == Platform (Available)** — версии shell совпали.
- **SC Version (Current) == (Available)** — firmware SC активировался.
- Нет пометок `mismatch` / `not up-to-date`.

Ожидаемо: `xilinx_u200_gen3x16_xdma_...` в статусе актуального, без mismatch.

---

## 10. Финальный health-check (validate)

Проверяет весь стек (карта + shell + XRT + DMA) готовым validate-xclbin из
deployment-пакета.

```bash
source /opt/xilinx/xrt/setup.sh
xbutil validate --device $BDF
```

### Проверка

Ожидаемо: все тесты со статусом **PASSED** (проверка DMA, verify-kernel, bandwidth и т.д.).

Если какой-то тест `FAILED`:

- проверь Above 4G Decoding / Resizable BAR в BIOS (раздел 1.1);
- убедись, что был именно cold reboot (раздел 9);
- проверь совпадение версий (раздел 10).

---

## 11. Запуск хост-приложения проекта (iperf)

### 11.0. Как устроено приложение

- **client** — открывает TCP-соединения к `target IP` на порт **5001** и льёт трафик;
- **server** — сам слушает порт **5001** (для dual-режима);
- **clock** — таймер длительности теста.

Схема теста:

```
┌─────────────────────────┐  100G Ethernet  ┌──────────────────────────┐
│  FPGA U200 (iperf CLIENT)│ ───── TCP ─────>│  Хост-приёмник           │
│  IP  192.168.1.10        │   порт 5001     │  iperf -s -p 5001        │
│  MAC 00:0A:35:02:9D:E5   │                 │  IP 192.168.1.20         │
└─────────────────────────┘                 └──────────────────────────┘
        обе стороны — одна подсеть 192.168.1.0/24 (иначе ARP не разрешит MAC)
```


### 11.1. Запуск iperf-сервера на встречной машине

На хосте-приёмнике (его адрес будет `target IP`, здесь `192.168.1.20`) подними
**iperf версии 2** — ядро генерирует классический iperf2-совместимый поток,
с iperf3 совместимость не гарантирована:

```bash
sudo apt install -y iperf          # именно iperf (v2), НЕ iperf3
```

```bash
iperf -s -p 5001 -i 1
```

### 11.2. Запуск на FPGA-хосте

Сначала задай локальные IP/MAC карты (env читает `host.cpp`), затем запусти.
Имена артефактов — как собрано: бинарь `host`, битстрим `network.xclbin`.

```bash
source /opt/xilinx/xrt/setup.sh

export DEVICE_1_IP_ADDRESS_HEX_0=C0A8010A      # локальный IP FPGA = 192.168.1.10
export DEVICE_1_MAC_ADDRESS_0=000A35029DE5     # локальный MAC FPGA (подставь свой)
```

Аргументы: `<xclbin> <target_ip> <#connections> <seconds> <packetWord>`

```bash
./host ./network.xclbin 192.168.1.20 1 10 22
```

> **Пауза на ENTER.** После загрузки сетевого ядра `host.cpp` печатает
> `Press ENTER to continue after setting up ILA trigger...` и ждёт. Это окно для
> настройки ILA-триггера в Vivado (если отлаживаешь). Если ILA не используешь —
> просто нажми **Enter**, тест продолжится.

### Проверка

Ожидаемо в выводе **FPGA-хоста**:

- `Device[0]: program successful!` — `.xclbin` загрузился (нет version mismatch);
- строка `local IP:c0a8010a, local MAC addr:a35029de5` (твои значения);
- `enqueued network kernel`;
- после нажатия Enter — `enqueued user kernel`;
- одна или несколько строк `Connection successfully opened.`;
- в конце `durationUs:...` и `EXIT recorded`.

Ожидаемо в выводе **iperf-сервера** (приёмник): появляется установленное соединение
с `192.168.1.10` и растущий счётчик принятых мегабайт/пропускной способности.

Диагностика проблем:

| Симптом                                    | Вероятная причина                                    |
|--------------------------------------------|------------------------------------------------------|
| `Connection could not be opened.`          | нет iperf-сервера на 5001 / разные подсети / ARP     |
| Сервер молчит, соединений нет              | линк 100G не поднялся (проверь оптику/DAC, CMAC)      |
| `Failed to program device ... xclbin file` | несовпадение версии `.xclbin` и shell (разделы 0, 10)|
| нет `local IP`/`MAC` в выводе              | не заданы env-переменные (раздел 11.4)               |

---

## Приложение A. Полезные команды диагностики

```bash
source /opt/xilinx/xrt/setup.sh

xbutil examine                 # общий статус карты глазами пользователя
xbutil examine --device $BDF --report all
sudo xbmgmt examine            # статус со стороны management
dmesg | grep -iE "xocl|xclmgmt|xrt"   # сообщения драйвера в ядре
lspci -vd 10ee:                # PCIe BAR-регионы карты
```

## Приложение B. Типичные проблемы

| Симптом                                | Причина                                 | Решение                                 |
|----------------------------------------|-----------------------------------------|-----------------------------------------|
| `lspci -d 10ee:` пусто                 | Above 4G Decoding выкл / плохой контакт | BIOS (раздел 1.1), переустановить карту |
| `xbmgmt examine`: platform mismatch    | shell не совпал с XRT/xclbin            | ставить одну версию (раздел 0)          |
| SC version не обновился                | делали `reboot`, а не cold boot         | полное выключение питания (раздел 9)    |
| `xbutil validate` FAILED (DMA)         | BAR не прокинуты                        | Above 4G / Resizable BAR                |
| `Failed to program device with xclbin` | версия `.xclbin` ≠ версия shell         | пересобрать xclbin под 2024.1           |
| `xocl` не в `lsmod`                    | загружается после флеша shell           | сделать флеш + reboot, проверить снова  |

---

## Краткая шпаргалка (TL;DR)

```bash
cd ~/alveo_install
sudo apt update && sudo apt install -y linux-headers-$(uname -r) dkms

# XRT
sudo apt install -y ./xrt_202410.2.17.319_22.04-amd64-xrt.deb
source /opt/xilinx/xrt/setup.sh

# shell
tar xzvf xilinx-u200-gen3x16-xdma_2024.1_*-all.deb.tar.gz
sudo apt install -y ./xilinx-cmc-u200-u250_*.deb ./xilinx-sc-fw-u200-u250_*.deb \
  ./xilinx-u200-gen3x16-xdma-base_*.deb ./xilinx-u200-gen3x16-xdma-validate_*.deb

# флеш
export BDF=0000:01:00.0          # свой BDF из `sudo xbmgmt examine`
sudo xbmgmt program --base --device $BDF
sudo shutdown -h now             # COLD reboot!

# после включения
source /opt/xilinx/xrt/setup.sh
sudo xbmgmt examine              # версии совпадают, нет mismatch
xbutil validate --device $BDF    # PASSED

# запуск iperf-теста
# --- на приёмнике (192.168.1.20): ---
iperf -s -p 5001 -i 1            # iperf v2, НЕ iperf3
# --- на FPGA-хосте (192.168.1.10): ---
export DEVICE_1_IP_ADDRESS_HEX_0=C0A8010A     # 192.168.1.10
export DEVICE_1_MAC_ADDRESS_0=000A35029DE5    # свой MAC
./host ./network.xclbin 192.168.1.20 1 10 22  # <target_ip> <#conn> <sec> <packetWord>
# затем нажать ENTER на приглашении про ILA
```
