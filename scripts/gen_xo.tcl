# /*******************************************************************************
# Copyright (c) 2018, Xilinx, Inc.
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without modification,
# are permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
# 
# 
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
# 
# 
# 3. Neither the name of the copyright holder nor the names of its contributors
# may be used to endorse or promote products derived from this software
# without specific prior written permission.
# 
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,THE IMPLIED 
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, 
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY 
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING 
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# *******************************************************************************/

# 8-й аргумент (qsfp_idx) необязателен: только cmac_krnl про него знает
# (выбор GT-квада в package_cmac_krnl.tcl), для network_krnl и остальных вызовов
# он просто не используется. Дефолт 0 сохраняет прежнее поведение 1:1.
if { $::argc != 7 && $::argc != 8 } {
    puts "ERROR: Program \"$::argv0\" requires 6 or 7 arguments!\n"
    puts "Usage: $::argv0 <xoname> <krnl_name> <target> <xpfm_path> <device> <xml_path> <package_tcl_path> \[qsfp_idx\]\n"
    exit
}

set xoname  [lindex $::argv 0]
set krnl_name [lindex $::argv 1]
set target    [lindex $::argv 2]
set xpfm_path [lindex $::argv 3]
set device    [lindex $::argv 4]
set xml_path [lindex $::argv 5]
set package_tcl_path [lindex $::argv 6]

if { $::argc == 8 } {
    set qsfp_idx [lindex $::argv 7]
} else {
    set qsfp_idx 0
}

# Suffix за qsfp_idx != 0 получает свой хвост, чтобы packaged_kernel_${suffix} и
# tmp_kernel_pack_${suffix} не пересекались с портом 0 и не затирали его на
# диске — сборки обоих портов должны уметь жить рядом одновременно.
set suffix "${krnl_name}_${target}_${device}"
if { $qsfp_idx != 0 } {
    set suffix "${suffix}_qsfp${qsfp_idx}"
}

puts "INFO: ${xoname} ${krnl_name} ${target} ${xpfm_path} ${device} qsfp_idx=${qsfp_idx}"

source -notrace ${package_tcl_path}

if {[file exists "${xoname}"]} {
    file delete -force "${xoname}"
}

# .xo нужен только Vitis-флоу (v++ -l), а тот собирает единственный порт.
# Для qsfp_idx != 0 упакованный IP называется иначе (cmac_krnl_qsfpN, см.
# package_cmac_krnl.tcl), и -kernel_name/kernel_xml с родовым именем ему уже
# не соответствуют. Vivado-флоу .xo не использует вовсе — он читает
# packaged_kernel_* напрямую, поэтому пропуск здесь ничего не ломает.
if { $qsfp_idx != 0 } {
    puts "INFO: qsfp_idx=${qsfp_idx} — .xo не пакуется (нужен только Vitis-флоу,"
    puts "      который собирает один порт). IP готов в ./packaged_kernel_${suffix},"
    puts "      его использует scripts/vivado/build_bd.tcl."
} else {
    package_xo -xo_path ${xoname} -kernel_name ${krnl_name} -ip_directory ./packaged_kernel_${suffix} -kernel_xml ${xml_path}
}
