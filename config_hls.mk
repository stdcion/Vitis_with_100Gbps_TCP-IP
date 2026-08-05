VIVADO := $(XILINX_VIVADO)/bin/vivado
$(TEMP_DIR)/${KRNL_1}.xo: kernel/network_krnl/network_krnl.xml kernel/network_krnl/package_network_krnl.tcl scripts/gen_xo.tcl kernel/network_krnl/src/hdl/*.sv
	mkdir -p $(TEMP_DIR)
	$(VIVADO) -mode batch -source scripts/gen_xo.tcl -tclargs $(TEMP_DIR)/${KRNL_1}.xo ${KRNL_1} $(TARGET) $(DEVICE) $(XSA) kernel/network_krnl/network_krnl.xml kernel/network_krnl/package_network_krnl.tcl

$(TEMP_DIR)/${KRNL_2}.xo: kernel/user_krnl/${KRNL_2}/src/hls/*.cpp
	mkdir -p $(TEMP_DIR)
	$(VPP) $(CLFLAGS) -c -k ${KRNL_2} -o $(TEMP_DIR)/${KRNL_2}.xo --input_files kernel/user_krnl/${KRNL_2}/src/hls/*.cpp


# Правило для ${KRNL_3} (= cmac_krnl) живёт в Makefile, а не здесь: только там
# оно умеет QSFP_IDX (7-й аргумент gen_xo.tcl и имя .xo под порт). Здесь была
# копия без QSFP_IDX, и оба определения целили в $(TEMP_DIR)/cmac_krnl.xo —
# make печатал "overriding recipe for target". Работало лишь потому, что
# include (Makefile:81) идёт раньше, и побеждало правило из Makefile.
