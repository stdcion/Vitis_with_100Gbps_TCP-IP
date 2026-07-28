/**********
Клиент-измеритель для hls_pingpong_krnl.

Подключается к FPGA по TCP, шлёт сообщения фиксированного размера и
меряет RTT каждого: отправил -> получил эхо обратно.

Это УРОВЕНЬ C методики: полный путь
    приложение -> NIC -> провод -> CMAC -> стек -> ядро ->
    стек -> CMAC -> провод -> NIC -> приложение

ТОЧНОСТЬ ИЗМЕРЕНИЯ. Три вещи, которые здесь сделаны намеренно:

  1. CLOCK_MONOTONIC_RAW вместо CLOCK_MONOTONIC.
     CLOCK_MONOTONIC подстраивается NTP и на некоторых системах имеет
     разрешение 1 мкс (измерено: на macOS clock_getres даёт 1000 нс,
     97% пар последовательных вызовов дают нулевую разницу). При RTT
     в единицы микросекунд это погрешность ±20%. RAW не корректируется
     и на той же машине даёт разрешение 42 нс.

  2. Привязка к одному CPU (--cpu) и SCHED_FIFO (--rt).
     Без этого планировщик мигрирует процесс между ядрами, и хвосты
     (p99/p99.9) показывают шум планировщика, а не задержку сети.

  3. Калибровка оверхеда таймера при старте.
     Печатается отдельной строкой, чтобы была видна граница
     собственной погрешности измерителя.

ЧЕГО ЗДЕСЬ НЕТ: вычитания «накладных расходов» из RTT. Оверхед
таймера печатается справочно, но не вычитается — сисколлы send/recv
это неотделимая часть измеряемого пути, а не аддитивная поправка.

Сборка:
    gcc -O2 -o pingpong_client pingpong_client.c

Запуск:
    ./pingpong_client <fpga_ip> <port> <msg_bytes> <count> [warmup] [опции]

Опции:
    --cpu N     привязать процесс к CPU N (Linux)
    --rt        SCHED_FIFO приоритет 80 (Linux, нужен root или CAP_SYS_NICE)
    --verify    сверять содержимое эха (по умолчанию только на warmup)
    --csv FILE  куда писать сырые сэмплы (по умолчанию rtt_ns.csv)

Пример максимально точного запуска:
    sudo ./pingpong_client 192.168.1.10 5001 64 100000 5000 --cpu 2 --rt

Дополнительно для стабильных хвостов (вне этой программы):
    - отключить C-states и turbo в BIOS
    - изолировать ядро: isolcpus=2 nohz_full=2 rcu_nocbs=2 в cmdline
    - governor: cpupower frequency-set -g performance
**********/
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <stdint.h>
#include <math.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#ifdef __linux__
#include <sched.h>
#include <sys/resource.h>
#endif

/* CLOCK_MONOTONIC_RAW есть в Linux и macOS; на прочих — откат */
#ifdef CLOCK_MONOTONIC_RAW
#define PP_CLOCK CLOCK_MONOTONIC_RAW
#define PP_CLOCK_NAME "CLOCK_MONOTONIC_RAW"
#else
#define PP_CLOCK CLOCK_MONOTONIC
#define PP_CLOCK_NAME "CLOCK_MONOTONIC (RAW недоступен!)"
#endif

static int cmp_u64(const void *a, const void *b) {
    unsigned long long x = *(const unsigned long long *)a;
    unsigned long long y = *(const unsigned long long *)b;
    return (x > y) - (x < y);
}

static double pct(unsigned long long *sorted, size_t n, double p) {
    if (n == 0) return 0.0;
    double idx = (p / 100.0) * (n - 1);
    size_t lo = (size_t)idx;
    size_t hi = lo + 1 < n ? lo + 1 : lo;
    double frac = idx - lo;
    return sorted[lo] + frac * (sorted[hi] - sorted[lo]);
}

static inline unsigned long long now_ns(void) {
    struct timespec t;
    clock_gettime(PP_CLOCK, &t);
    return (unsigned long long)t.tv_sec * 1000000000ULL +
           (unsigned long long)t.tv_nsec;
}

/* Полное чтение n байт */
static int read_full(int fd, char *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, buf + got, n - got, 0);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

/*
 * Разрешение таймера и стоимость его вызова.
 *
 * res_ns   — что сообщает clock_getres
 * ovh_ns   — медиана разницы двух последовательных вызовов; это нижняя
 *            граница того, что вообще можно измерить
 * gran_ns  — минимальная НЕнулевая разница; если она заметно больше
 *            ovh_ns, таймер квантует (см. п.1 в шапке)
 */
static void calibrate_clock(unsigned long long *res_ns,
                            unsigned long long *ovh_ns,
                            unsigned long long *gran_ns) {
    struct timespec r;
    clock_getres(PP_CLOCK, &r);
    *res_ns = (unsigned long long)r.tv_sec * 1000000000ULL +
              (unsigned long long)r.tv_nsec;

    enum { N = 20000 };
    static unsigned long long d[N];
    unsigned long long minNonZero = ~0ULL;
    for (int i = 0; i < N; i++) {
        unsigned long long a = now_ns();
        unsigned long long b = now_ns();
        d[i] = b - a;
        if (d[i] != 0 && d[i] < minNonZero) minNonZero = d[i];
    }
    qsort(d, N, sizeof(d[0]), cmp_u64);
    *ovh_ns  = d[N / 2];
    *gran_ns = (minNonZero == ~0ULL) ? 0 : minNonZero;
}

/* Привязка к CPU и realtime-приоритет. Возвращает 0, если применено. */
static int pin_cpu(int cpu) {
#ifdef __linux__
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        fprintf(stderr, "WARNING: sched_setaffinity(cpu=%d): %s\n",
                cpu, strerror(errno));
        return -1;
    }
    return 0;
#else
    (void)cpu;
    fprintf(stderr, "WARNING: --cpu игнорируется: доступно только на Linux\n");
    return -1;
#endif
}

static int set_realtime(void) {
#ifdef __linux__
    struct sched_param sp;
    memset(&sp, 0, sizeof(sp));
    sp.sched_priority = 80;
    if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0) {
        fprintf(stderr, "WARNING: SCHED_FIFO: %s "
                        "(нужен root или CAP_SYS_NICE)\n", strerror(errno));
        return -1;
    }
    return 0;
#else
    fprintf(stderr, "WARNING: --rt игнорируется: доступно только на Linux\n");
    return -1;
#endif
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr,
                "Usage: %s <fpga_ip> <port> <msg_bytes> <count> [warmup] [опции]\n"
                "Опции: --cpu N  --rt  --verify  --csv FILE\n"
                "Пример: sudo %s 192.168.1.10 5001 64 100000 5000 --cpu 2 --rt\n",
                argv[0], argv[0]);
        return 1;
    }

    const char *ip = argv[1];
    int port = atoi(argv[2]);
    size_t msg_bytes = (size_t)atoi(argv[3]);
    size_t count = (size_t)atoi(argv[4]);
    /* warmup по умолчанию 2000: за 100 итераций TCP не выходит из slow
       start, а частотный governor не успевает поднять частоту */
    size_t warmup = 2000;
    int cpu = -1, want_rt = 0, verify_all = 0;
    const char *csv_path = "rtt_ns.csv";

    int argi = 5;
    if (argc >= 6 && argv[5][0] != '-') { warmup = (size_t)atoi(argv[5]); argi = 6; }
    for (; argi < argc; argi++) {
        if (!strcmp(argv[argi], "--cpu") && argi + 1 < argc) cpu = atoi(argv[++argi]);
        else if (!strcmp(argv[argi], "--rt")) want_rt = 1;
        else if (!strcmp(argv[argi], "--verify")) verify_all = 1;
        else if (!strcmp(argv[argi], "--csv") && argi + 1 < argc) csv_path = argv[++argi];
        else { fprintf(stderr, "неизвестная опция: %s\n", argv[argi]); return 1; }
    }

    if (msg_bytes == 0 || msg_bytes > 4096) {
        fprintf(stderr, "msg_bytes must be 1..4096 (PP_MAX_WORDS*64 в ядре)\n");
        return 1;
    }
    if (count == 0) { fprintf(stderr, "count must be > 0\n"); return 1; }

    /* Порядок важен: сначала приоритет и привязка, потом калибровка —
       чтобы калибровка измеряла те же условия, что и сам замер */
    int pinned = (cpu >= 0) ? (pin_cpu(cpu) == 0) : 0;
    int rt     = want_rt ? (set_realtime() == 0) : 0;

    unsigned long long res_ns, ovh_ns, gran_ns;
    calibrate_clock(&res_ns, &ovh_ns, &gran_ns);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    /* Критично: без TCP_NODELAY алгоритм Нейгла добавит задержку */
    int one = 1;
    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) < 0) {
        perror("TCP_NODELAY");
        return 1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        fprintf(stderr, "bad IP: %s\n", ip);
        return 1;
    }

    printf("connecting to %s:%d ...\n", ip, port);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return 1;
    }
    printf("connected. msg=%zu bytes, count=%zu, warmup=%zu\n",
           msg_bytes, count, warmup);

    printf("\n=== Измеритель ===\n");
    printf("clock          : %s\n", PP_CLOCK_NAME);
    printf("clock_getres   : %llu ns\n", res_ns);
    printf("вызов таймера  : %llu ns (медиана пары вызовов)\n", ovh_ns);
    printf("гранулярность  : %llu ns (мин. ненулевая разница)\n", gran_ns);
    if (gran_ns > 100)
        printf("  ВНИМАНИЕ: таймер квантует шагом ~%llu ns — RTT будет\n"
               "  округляться до этой величины\n", gran_ns);
    printf("CPU affinity   : %s\n", pinned ? "да" : "нет (хвосты будут шумными)");
    printf("SCHED_FIFO     : %s\n", rt ? "да" : "нет (хвосты будут шумными)");
    printf("\n");

    char *tx = malloc(msg_bytes);
    char *rx = malloc(msg_bytes);
    unsigned long long *samples = malloc(count * sizeof(unsigned long long));
    if (!tx || !rx || !samples) { fprintf(stderr, "oom\n"); return 1; }
    for (size_t i = 0; i < msg_bytes; i++) tx[i] = (char)(i & 0xFF);

    size_t total = warmup + count;
    size_t recorded = 0;
    size_t mismatches = 0;

    for (size_t i = 0; i < total; i++) {
        unsigned long long t0 = now_ns();

        if (send(fd, tx, msg_bytes, 0) != (ssize_t)msg_bytes) {
            perror("send");
            break;
        }
        if (read_full(fd, rx, msg_bytes) < 0) {
            fprintf(stderr, "connection closed after %zu messages\n", i);
            break;
        }

        unsigned long long t1 = now_ns();

        /* Сверка вне измеряемого интервала. По умолчанию только на
           warmup: memcmp на больших сообщениях вытесняет данные из L1
           и добавляет шум СЛЕДУЮЩЕМУ сэмплу. */
        if (verify_all || i < warmup) {
            if (memcmp(tx, rx, msg_bytes) != 0) mismatches++;
        }

        if (i >= warmup) samples[recorded++] = t1 - t0;
    }

    close(fd);

    if (recorded == 0) {
        fprintf(stderr, "no samples collected\n");
        return 1;
    }

    /* Среднее и СКО считаем до сортировки — порядок не важен, но
       выбросы считаем относительно медианы, поэтому сортируем сначала */
    qsort(samples, recorded, sizeof(unsigned long long), cmp_u64);

    double sum = 0.0;
    for (size_t i = 0; i < recorded; i++) sum += (double)samples[i];
    double mean = sum / recorded;

    double var = 0.0;
    for (size_t i = 0; i < recorded; i++) {
        double d = (double)samples[i] - mean;
        var += d * d;
    }
    double sd = (recorded > 1) ? sqrt(var / (recorded - 1)) : 0.0;

    double p50 = pct(samples, recorded, 50);
    /* Выбросы: больше 2x медианы — обычно это планировщик или прерывания */
    size_t outliers = 0;
    for (size_t i = 0; i < recorded; i++)
        if ((double)samples[i] > 2.0 * p50) outliers++;

    printf("=== External RTT (application to application) ===\n");
    printf("samples    : %zu\n", recorded);
    printf("msg size   : %zu bytes\n", msg_bytes);
    printf("verify     : %s\n", verify_all ? "все сообщения" : "только warmup");
    if (mismatches) printf("MISMATCHES : %zu (echo data differs!)\n", mismatches);
    printf("\n");
    printf("min        : %8.0f ns  (%.3f us)\n", (double)samples[0], samples[0] / 1000.0);
    printf("p50        : %8.0f ns  (%.3f us)\n", p50, p50 / 1000.0);
    printf("p90        : %8.0f ns  (%.3f us)\n", pct(samples, recorded, 90), pct(samples, recorded, 90) / 1000.0);
    printf("p99        : %8.0f ns  (%.3f us)\n", pct(samples, recorded, 99), pct(samples, recorded, 99) / 1000.0);
    printf("p99.9      : %8.0f ns  (%.3f us)\n", pct(samples, recorded, 99.9), pct(samples, recorded, 99.9) / 1000.0);
    printf("max        : %8.0f ns  (%.3f us)\n", (double)samples[recorded - 1], samples[recorded - 1] / 1000.0);
    printf("mean       : %8.0f ns  (%.3f us)\n", mean, mean / 1000.0);
    printf("stddev     : %8.0f ns  (%.3f us)\n", sd, sd / 1000.0);
    printf("outliers   : %zu (%.2f%%, > 2x p50)\n",
           outliers, 100.0 * outliers / recorded);
    printf("\n");
    printf("Односторонняя задержка ~ p50/2 = %.3f us (при симметричном пути)\n",
           p50 / 2000.0);
    printf("Погрешность измерителя ~ %llu ns (гранулярность таймера)\n", gran_ns);

    FILE *f = fopen(csv_path, "w");
    if (f) {
        fprintf(f, "rtt_ns\n");
        for (size_t i = 0; i < recorded; i++)
            fprintf(f, "%llu\n", samples[i]);
        fclose(f);
        printf("\nraw samples written to %s (sorted)\n", csv_path);
    }

    free(tx); free(rx); free(samples);
    return mismatches ? 2 : 0;
}
