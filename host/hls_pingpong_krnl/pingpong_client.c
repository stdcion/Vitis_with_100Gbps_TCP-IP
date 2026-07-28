/**********
Клиент-измеритель для hls_pingpong_krnl.

Подключается к FPGA по TCP, шлёт сообщения фиксированного размера и
меряет RTT каждого: отправил -> получил эхо обратно.

Это УРОВЕНЬ C методики: полный путь
    приложение -> NIC -> провод -> CMAC -> стек -> ядро ->
    стек -> CMAC -> провод -> NIC -> приложение

Сравните результат с внутренней задержкой ядра, которую печатает
host-приложение FPGA: разница = стек + CMAC + провод + хост клиента.

Сборка:
    gcc -O2 -o pingpong_client pingpong_client.c

Запуск:
    ./pingpong_client <fpga_ip> <port> <msg_bytes> <count> [warmup]

Пример:
    ./pingpong_client 192.168.1.10 5001 64 10000 1000

Для честных цифр:
    - закрепить процесс на ядре:  taskset -c 2 ./pingpong_client ...
    - поднять приоритет:          chrt -f 80 taskset -c 2 ./pingpong_client ...
    - отключить C-states и turbo в BIOS
**********/
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

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

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr,
                "Usage: %s <fpga_ip> <port> <msg_bytes> <count> [warmup]\n"
                "Example: %s 192.168.1.10 5001 64 10000 1000\n",
                argv[0], argv[0]);
        return 1;
    }

    const char *ip = argv[1];
    int port = atoi(argv[2]);
    size_t msg_bytes = (size_t)atoi(argv[3]);
    size_t count = (size_t)atoi(argv[4]);
    size_t warmup = argc >= 6 ? (size_t)atoi(argv[5]) : 100;

    if (msg_bytes == 0 || msg_bytes > 4096) {
        fprintf(stderr, "msg_bytes must be 1..4096\n");
        return 1;
    }

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
    printf("connected. msg=%zu bytes, count=%zu, warmup=%zu\n\n",
           msg_bytes, count, warmup);

    char *tx = malloc(msg_bytes);
    char *rx = malloc(msg_bytes);
    if (!tx || !rx) { fprintf(stderr, "oom\n"); return 1; }
    for (size_t i = 0; i < msg_bytes; i++) tx[i] = (char)(i & 0xFF);

    unsigned long long *samples = malloc(count * sizeof(unsigned long long));
    if (!samples) { fprintf(stderr, "oom\n"); return 1; }

    size_t total = warmup + count;
    size_t recorded = 0;
    size_t mismatches = 0;

    for (size_t i = 0; i < total; i++) {
        struct timespec t0, t1;

        clock_gettime(CLOCK_MONOTONIC, &t0);

        if (send(fd, tx, msg_bytes, 0) != (ssize_t)msg_bytes) {
            perror("send");
            break;
        }
        if (read_full(fd, rx, msg_bytes) < 0) {
            fprintf(stderr, "connection closed after %zu messages\n", i);
            break;
        }

        clock_gettime(CLOCK_MONOTONIC, &t1);

        if (memcmp(tx, rx, msg_bytes) != 0) mismatches++;

        if (i >= warmup) {
            unsigned long long ns =
                (unsigned long long)(t1.tv_sec - t0.tv_sec) * 1000000000ULL +
                (unsigned long long)(t1.tv_nsec - t0.tv_nsec);
            samples[recorded++] = ns;
        }
    }

    close(fd);

    if (recorded == 0) {
        fprintf(stderr, "no samples collected\n");
        return 1;
    }

    qsort(samples, recorded, sizeof(unsigned long long), cmp_u64);

    double sum = 0;
    for (size_t i = 0; i < recorded; i++) sum += (double)samples[i];

    printf("=== External RTT (application to application) ===\n");
    printf("samples    : %zu\n", recorded);
    printf("msg size   : %zu bytes\n", msg_bytes);
    if (mismatches) printf("MISMATCHES : %zu (echo data differs!)\n", mismatches);
    printf("\n");
    printf("min        : %8.0f ns  (%.3f us)\n", (double)samples[0], samples[0] / 1000.0);
    printf("p50        : %8.0f ns  (%.3f us)\n", pct(samples, recorded, 50), pct(samples, recorded, 50) / 1000.0);
    printf("p90        : %8.0f ns  (%.3f us)\n", pct(samples, recorded, 90), pct(samples, recorded, 90) / 1000.0);
    printf("p99        : %8.0f ns  (%.3f us)\n", pct(samples, recorded, 99), pct(samples, recorded, 99) / 1000.0);
    printf("p99.9      : %8.0f ns  (%.3f us)\n", pct(samples, recorded, 99.9), pct(samples, recorded, 99.9) / 1000.0);
    printf("max        : %8.0f ns  (%.3f us)\n", (double)samples[recorded - 1], samples[recorded - 1] / 1000.0);
    printf("mean       : %8.0f ns  (%.3f us)\n", sum / recorded, sum / recorded / 1000.0);

    FILE *f = fopen("rtt_ns.csv", "w");
    if (f) {
        fprintf(f, "rtt_ns\n");
        for (size_t i = 0; i < recorded; i++)
            fprintf(f, "%llu\n", samples[i]);
        fclose(f);
        printf("\nraw samples written to rtt_ns.csv (sorted)\n");
    }

    free(tx); free(rx); free(samples);
    return 0;
}
