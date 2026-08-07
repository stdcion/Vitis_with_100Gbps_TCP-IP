# csim_shim — прогон тестбенчей ядер без Vitis HLS

277 строк заголовков, которые позволяют собрать и запустить тестбенч
HLS-ядра **обычным g++**, на машине без установленного Vitis HLS.

Зачем: отладка логики ядра без доступа к сборочной машине и без платы.
Тестбенчи в `kernel/user_krnl/*/src/hls/tb/` — это обычный C++, они дёргают
ядро по одному такту в цикле. Всё, чего им не хватает, — `ap_uint`, `ap_axiu`
и `hls::stream`.

## Как запустить

Ядро включает `communication.hpp` относительным путём на четыре уровня вверх
(`../../../../common/include/`), поэтому одного `-I` недостаточно — нужна
такая же глубина дерева. Проще всего собрать зеркало:

```bash
SHIM=$PWD/kernel/common/csim_shim
T=$(mktemp -d)/tree
mkdir -p $T/kernel/user_krnl/k/src/hls/tb $T/kernel/common
ln -s $PWD/kernel/common/include $T/kernel/common/include

K=hls_pingpong_krnl
cp kernel/user_krnl/$K/src/hls/$K.cpp        $T/kernel/user_krnl/k/src/hls/
cp kernel/user_krnl/$K/src/hls/tb/test_$K.cpp $T/kernel/user_krnl/k/src/hls/tb/

cd $T/kernel/user_krnl/k/src/hls
g++ -std=c++14 -I$SHIM -o /tmp/tb $K.cpp tb/test_$K.cpp && /tmp/tb
```

Проверено (2026-08-07): под шимом компилируются `hls_dual_echo_krnl`,
`hls_echo_krnl`, `hls_pingpong_krnl`, `hls_pingpong_probe_krnl`,
`hls_gateway_krnl`, `hls_ouch_krnl`; тестбенч `hls_pingpong_krnl` проходит все
11 сценариев.

## Границы применимости

Это **не** замена csim и тем более не замена cosim. Три вещи, о которых нужно
помнить, иначе выводы будут ложными:

**`full()` всегда false.** `hls::stream` здесь неограничен — ровно как в
настоящем csim. Значит любая проверка `full()` в ядре при таком прогоне
мёртвый код, и баги, зависящие от давления FIFO, так не ловятся. Для них нужен
`cosim_design` либо ограниченный по глубине режим шима.

**Состояние не сбрасывается между тестами.** Ядра держат его в
function-local `static`, поэтому сценарии, требующие чистого старта, надо
разносить по отдельным исполняемым файлам, а не цеплять в одном `main`.

**Тайминг не моделируется.** Такты считает тестбенч, вызывая ядро в цикле;
II, латентность конвейера и backpressure шим не воспроизводит. Синтезируемость
и II проверяются только `csynth_design` на сборочной машине.

## Что внутри

| Файл | Что даёт |
|---|---|
| `ap_int.h` | `ap_uint<W>` любой ширины: срезы `x(hi,lo)` на чтение и запись, биты `x[i]`, арифметика по модулю 2^W |
| `ap_axi_sdata.h` | `ap_axiu<W,0,0,0>` с полями `data`/`keep`/`strb`/`last` |
| `hls_stream.h` | `hls::stream` как очередь: `write`, `read`, `read(x)`, `empty`, `full` |
| `ap_fixed.h` | заглушка — ядра включают заголовок, но типы `ap_fixed` не используют |

Срез шире 64 бит падает на `assert`, а не считает молча неверно — в ядрах таких
обращений нет (они читают поля заголовков), но лучше узнать сразу.
