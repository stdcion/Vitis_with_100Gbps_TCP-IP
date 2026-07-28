/**********
Host для hls_pingpong_krnl.

Настраивает сетевое ядро (локальный IP/MAC) и запускает echo-ядро,
которое дальше работает само. Никаких измерений здесь нет — задержку
меряет клиент (pingpong_client.c) с другой машины.

Ядро free-running (ap_ctrl_none), поэтому enqueueTask возвращается
сразу; ядро продолжает обслуживать подключения, пока карта запрограммирована.

Usage:
  ./host <XCLBIN> [<listen port>]
**********/
#include "xcl2.hpp"
#include <vector>
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
    if (!(ss >> value)) return 0;
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
    if (!(ss >> value)) return 0;
    return value;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cout << "Usage: " << argv[0]
                  << " <XCLBIN File> [<listen port>]" << std::endl;
        return EXIT_FAILURE;
    }

    std::string binaryFile = argv[1];
    uint32_t listenPort = 5001;
    if (argc >= 3) listenPort = strtol(argv[2], NULL, 10);

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
            OCL_CHECK(err, user_kernel = cl::Kernel(program, "hls_pingpong_krnl", &err));
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

    OCL_CHECK(err, err = network_kernel.setArg(0, local_IP));
    OCL_CHECK(err, err = network_kernel.setArg(1, local_mac_addr));
    OCL_CHECK(err, err = network_kernel.setArg(2, local_IP));

    OCL_CHECK(err, cl::Buffer buffer_r1(context, CL_MEM_USE_HOST_PTR | CL_MEM_READ_WRITE,
                                        vector_size_bytes, network_ptr0.data(), &err));
    OCL_CHECK(err, cl::Buffer buffer_r2(context, CL_MEM_USE_HOST_PTR | CL_MEM_READ_WRITE,
                                        vector_size_bytes, network_ptr1.data(), &err));
    OCL_CHECK(err, err = network_kernel.setArg(3, buffer_r1));
    OCL_CHECK(err, err = network_kernel.setArg(4, buffer_r2));

    printf("enqueue network kernel...\n");
    OCL_CHECK(err, err = q.enqueueTask(network_kernel));
    OCL_CHECK(err, err = q.finish());

    // Единственный аргумент ядра идёт после 16 stream-портов
    OCL_CHECK(err, err = user_kernel.setArg(16, listenPort));

    printf("enqueue pingpong kernel...\n");
    OCL_CHECK(err, err = q.enqueueTask(user_kernel));
    OCL_CHECK(err, err = q.finish());

    printf("\n");
    printf("Echo kernel is running, listening on port %d.\n", listenPort);
    printf("Measure latency from the client machine:\n");
    printf("    ./pingpong_client <this FPGA IP> %d 64 10000 1000\n", listenPort);
    printf("\n");

    std::cout << "EXIT recorded" << std::endl;
    return 0;
}
