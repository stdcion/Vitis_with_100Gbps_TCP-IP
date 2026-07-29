/**********
OUCH gateway host application.

Настраивает сетевое ядро (локальный IP/MAC) и запускает ядро
hls_ouch_krnl.

СТРОИТСЯ ПОЭТАПНО вместе с ядром. Сейчас ШАГ 1: ядро только открывает
listen-порт, поэтому хост задаёт лишь номер порта и разрешение работы.

Usage:
  ./host <XCLBIN> [<listen_port>]

Пример:
  ./host ./ouch.xclbin 7001
**********/
#include "xcl2.hpp"
#include <vector>
#include <chrono>
#include <thread>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <cstdlib>
#include <sstream>
#include <iomanip>
#include <cstdint>

#define DATA_SIZE 62500000

// ---------------------------------------------------------------
// Индексы аргументов ядра для setArg().
//
// setArg() адресует аргументы ПОЗИЦИЕЙ в сигнатуре ядра, считая с нуля
// и включая все stream-порты. Числа здесь обязаны совпадать с порядком
// аргументов в hls_ouch_krnl(). Ошибка не проявится ни при компиляции,
// ни при линковке — значение просто уедет в чужой регистр, и ядро
// будет вести себя необъяснимо.
//
// Поэтому: НЕ пишем числа в вызовах setArg, а держим их здесь, рядом
// друг с другом, и выводим один из другого.
//
// Правило добавления нового параметра:
//   1) в ядре вставить его МЕЖДУ listenPort и enable;
//   2) здесь добавить строку перед ARG_ENABLE;
//   3) ARG_ENABLE пересчитается сам.
// Так меняется ровно одно число, и то автоматически.
// ---------------------------------------------------------------
static const int NUM_STREAM_PORTS = 16;   // столько потоков в сигнатуре

static const int ARG_LISTEN_PORT  = NUM_STREAM_PORTS + 0;

// enable ВСЕГДА последний: выводим его из числа параметров, чтобы при
// добавлении новых индекс не пришлось править руками.
static const int NUM_SCALAR_PARAMS = 1;   // listenPort
static const int ARG_ENABLE = NUM_STREAM_PORTS + NUM_SCALAR_PARAMS;

uint32_t getIpEnv() {
    const char* env_var = getenv("DEVICE_1_IP_ADDRESS_HEX_0");
    if (env_var == NULL) {
        std::cerr << "DEVICE_1_IP_ADDRESS_HEX_0 is not set." << std::endl;
        return 0;
    }
    uint32_t value;
    std::stringstream ss;
    ss << std::hex << env_var;
    if (!(ss >> value)) {
        std::cerr << "Failed to parse IP address." << std::endl;
        return 0;
    }
    return value;
}

uint64_t getMacEnv() {
    const char* env_var = getenv("DEVICE_1_MAC_ADDRESS_0");
    if (env_var == NULL) {
        std::cerr << "DEVICE_1_MAC_ADDRESS_0 is not set." << std::endl;
        return 0;
    }
    uint64_t value;
    std::stringstream ss;
    ss << std::hex << env_var;
    if (!(ss >> value)) {
        std::cerr << "Failed to parse MAC address." << std::endl;
        return 0;
    }
    return value;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cout << "Usage: " << argv[0]
                  << " <XCLBIN File> [<listen port>]" << std::endl;
        return EXIT_FAILURE;
    }

    std::string binaryFile = argv[1];

    cl_int err;
    cl::CommandQueue q;
    cl::Context context;
    cl::Kernel user_kernel;
    cl::Kernel network_kernel;

    auto size = DATA_SIZE;
    auto vector_size_bytes = sizeof(int) * size;
    std::vector<int, aligned_allocator<int>> network_ptr0(size);
    std::vector<int, aligned_allocator<int>> network_ptr1(size);

    auto devices = xcl::get_xil_devices();
    auto fileBuf = xcl::read_binary_file(binaryFile);
    cl::Program::Binaries bins{{fileBuf.data(), fileBuf.size()}};
    int valid_device = 0;
    for (unsigned int i = 0; i < devices.size(); i++) {
        auto device = devices[i];
        OCL_CHECK(err, context = cl::Context({device}, NULL, NULL, NULL, &err));
        OCL_CHECK(err, q = cl::CommandQueue(context, {device},
                                            CL_QUEUE_PROFILING_ENABLE, &err));

        std::cout << "Trying to program device[" << i
                  << "]: " << device.getInfo<CL_DEVICE_NAME>() << std::endl;
        cl::Program program(context, {device}, bins, NULL, &err);
        if (err != CL_SUCCESS) {
            std::cout << "Failed to program device[" << i << "] with xclbin file!\n";
        } else {
            std::cout << "Device[" << i << "]: program successful!\n";
            OCL_CHECK(err, network_kernel = cl::Kernel(program, "network_krnl", &err));
            OCL_CHECK(err, user_kernel = cl::Kernel(program, "hls_ouch_krnl", &err));
            valid_device++;
            break;
        }
    }
    if (valid_device == 0) {
        std::cout << "Failed to program any device found, exit!\n";
        exit(EXIT_FAILURE);
    }

    uint32_t local_IP = getIpEnv();
    uint64_t local_mac_addr = getMacEnv();

    std::cout << std::hex << "local IP:" << local_IP
              << ", local MAC addr:" << local_mac_addr << std::dec << std::endl;

    // ---- Настройка сетевого ядра ----
    OCL_CHECK(err, err = network_kernel.setArg(0, local_IP));
    OCL_CHECK(err, err = network_kernel.setArg(1, local_mac_addr));
    OCL_CHECK(err, err = network_kernel.setArg(2, local_IP));

    cl::Buffer buffer_r1(context, CL_MEM_READ_WRITE | CL_MEM_USE_HOST_PTR,
                         vector_size_bytes, network_ptr0.data(), &err);
    cl::Buffer buffer_r2(context, CL_MEM_READ_WRITE | CL_MEM_USE_HOST_PTR,
                         vector_size_bytes, network_ptr1.data(), &err);

    OCL_CHECK(err, err = network_kernel.setArg(3, buffer_r1));
    OCL_CHECK(err, err = network_kernel.setArg(4, buffer_r2));

    printf("enqueue network kernel...\n");
    OCL_CHECK(err, err = q.enqueueTask(network_kernel));
    OCL_CHECK(err, err = q.finish());

    // ---- Параметры ядра ----
    uint32_t listenPort = 7001;
    if (argc >= 3)
        listenPort = strtol(argv[2], NULL, 10);

    printf("listen port : %d\n", listenPort);

    // ПОРЯДОК ЗАПИСИ ВАЖЕН: сначала все параметры, и только потом
    // enable.
    //
    // Ядро объявлено с ap_ctrl_none и, возможно, уже исполняет своё тело
    // (зависит от того, держит ли XRT его в reset до enqueueTask — не
    // проверено). Пока enable == 0, оно не трогает ни один порт, поэтому
    // гарантированно увидит уже записанные параметры. Выставить enable
    // раньше — значит рискнуть тем, что ядро запросит listen-порт по
    // нулевому регистру и защёлкнет состояние.
    OCL_CHECK(err, err = user_kernel.setArg(ARG_LISTEN_PORT, listenPort));

    // Разрешаем работу
    OCL_CHECK(err, err = user_kernel.setArg(ARG_ENABLE, (uint32_t)1));

    printf("enqueue ouch kernel...\n");
    OCL_CHECK(err, err = q.enqueueTask(user_kernel));
    OCL_CHECK(err, err = q.finish());

    // На этом шаге ядро только открыло listen-порт и больше ничего не
    // делает. Проверить можно с другой машины:
    //     nc -v <IP платы> 7001
    // Соединение должно устанавливаться (стек принимает подключение сам,
    // без участия ядра), а данные пока никуда не идут.
    printf("listening on port %d — kernel is running\n", listenPort);

    std::cout << "EXIT recorded" << std::endl;
    return EXIT_SUCCESS;
}
