/**********
TCP gateway host application.

Настраивает сетевое ядро (локальный IP/MAC) и запускает ядро гейтвея,
которое слушает listenPort и проксирует трафик на upstream-сервер.

Usage:
  ./host <XCLBIN> <server_ip> [<server_port> [<listen_port>]]

Пример:
  ./host ./gateway.xclbin 192.168.1.20 8080 5001
**********/
#include "xcl2.hpp"
#include <vector>
#include <chrono>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <cstdlib>
#include <sstream>
#include <iomanip>
#include <cstdint>

#define DATA_SIZE 62500000

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

// "192.168.1.20" -> 0xC0A80114 (первый октет в старшем байте)
uint32_t parseIpString(const std::string &input) {
    std::string s = input;
    std::string delimiter = ".";
    int ip[4] = {0, 0, 0, 0};
    size_t pos = 0;
    int i = 0;
    while ((pos = s.find(delimiter)) != std::string::npos && i < 3) {
        ip[i] = stoi(s.substr(0, pos));
        s.erase(0, pos + delimiter.length());
        i++;
    }
    ip[i] = stoi(s);
    return ip[3] | (ip[2] << 8) | (ip[1] << 16) | (ip[0] << 24);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cout << "Usage: " << argv[0]
                  << " <XCLBIN File> <server IP e.g. 192.168.1.20>"
                  << " [<server port>] [<listen port>]" << std::endl;
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
            OCL_CHECK(err, user_kernel = cl::Kernel(program, "hls_gateway_krnl", &err));
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

    // Настройка сетевого ядра
    OCL_CHECK(err, err = network_kernel.setArg(0, local_IP));
    OCL_CHECK(err, err = network_kernel.setArg(1, local_mac_addr));
    OCL_CHECK(err, err = network_kernel.setArg(2, local_IP));

    OCL_CHECK(err, cl::Buffer buffer_r1(context,
                                        CL_MEM_USE_HOST_PTR | CL_MEM_READ_WRITE,
                                        vector_size_bytes,
                                        network_ptr0.data(), &err));
    OCL_CHECK(err, cl::Buffer buffer_r2(context,
                                        CL_MEM_USE_HOST_PTR | CL_MEM_READ_WRITE,
                                        vector_size_bytes,
                                        network_ptr1.data(), &err));

    OCL_CHECK(err, err = network_kernel.setArg(3, buffer_r1));
    OCL_CHECK(err, err = network_kernel.setArg(4, buffer_r2));

    printf("enqueue network kernel...\n");
    OCL_CHECK(err, err = q.enqueueTask(network_kernel));
    OCL_CHECK(err, err = q.finish());

    // Параметры гейтвея
    uint32_t serverIpAddr = parseIpString(argv[2]);
    uint32_t serverPort = 8080;
    uint32_t listenPort = 5001;

    if (argc >= 4)
        serverPort = strtol(argv[3], NULL, 10);
    if (argc >= 5)
        listenPort = strtol(argv[4], NULL, 10);

    printf("listen port      : %d\n", listenPort);
    printf("upstream server  : %s (0x%08x)\n", argv[2], serverIpAddr);
    printf("upstream port    : %d\n", serverPort);

    // Аргументы ядра идут после 16 stream-портов
    OCL_CHECK(err, err = user_kernel.setArg(16, listenPort));
    OCL_CHECK(err, err = user_kernel.setArg(17, serverIpAddr));
    OCL_CHECK(err, err = user_kernel.setArg(18, serverPort));

    printf("enqueue gateway kernel...\n");
    auto start = std::chrono::high_resolution_clock::now();
    OCL_CHECK(err, err = q.enqueueTask(user_kernel));
    OCL_CHECK(err, err = q.finish());
    auto end = std::chrono::high_resolution_clock::now();
    double durationUs =
        (std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count() / 1000.0);
    printf("durationUs:%f\n", durationUs);

    std::cout << "EXIT recorded" << std::endl;
}
