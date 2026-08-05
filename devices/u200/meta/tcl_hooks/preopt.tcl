puts "BEGIN: PLATFORM_PRE_OPT_TCL"

# ------------------------------------------------------------------------------------------------------------------------------------------------
# ulp/preopt.tcl
# ------------------------------------------------------------------------------

if {[llength [get_pins -hierarchical -filter {NAME =~ *memory_subsystem/inst/DDR4_MEM* && IS_TIED==TRUE}]]} {
  puts "Possible DDR4_MEM [get_pins -hierarchical -filter {NAME =~ *memory_subsystem/inst/DDR4_MEM* && IS_TIED==TRUE}]"
  set_property DONT_TOUCH 0 [get_nets -segments -of [get_pins -hierarchical -filter {NAME =~ *memory_subsystem/inst/DDR4_MEM* && IS_TIED==TRUE}]]
  disconnect_net -net [get_nets -hierarchical -filter {NAME =~ "*/<const0>"}] -objects [get_pins -hierarchical -filter {NAME =~ *memory_subsystem/inst/DDR4_MEM* && IS_TIED==TRUE}]
} else {
  puts "INFO: could not find DDR4_MEM nets to disconnnect."
}

set partition_path level0_i/ulp

# #######################################################################
# WARNING: WORKAROUND!
# #######################################################################
#
# These constraints are added as a workaround to CR-1038346
# Remove these constraints when CR is resolved.
#
# Error codes: ERROR: [VPL 30-1112]
#
# The problem is that the XSA cannot register the parent PBLOCKS in the EARLY XDC processing stage and only as NORMAL. This creates a race condition where the
# constraints for the parent and child processing occurs. They cannot be moved to LATE since that is where the constraints of the MSS happen. That would just move the
# race condition from the NORMAL phase to the LATE phase.
#for {set i 0} {$i < 4} {incr i} {
#  set idx [format %.2d $i]
#  add_cells_to_pblock [get_pblocks pblock_dynamic_SLR${i}] [get_cells -hierarchical -filter "NAME =~ $partition_path/*ict_axi_ctrl_user_${idx}"]
#  add_cells_to_pblock [get_pblocks pblock_dynamic_SLR${i}] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/plram_mem${idx}"] -quiet
#  add_cells_to_pblock [get_pblocks pblock_dynamic_SLR${i}] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/plram_mem${idx}_bram"] -quiet
#
#  # JUSTIFICATION: CR-1058924
#  # Per SLR reset distribution pipelines require some additional placement assistance to reduce the likelihood of unrouted nets.
#  # This placement directive is temporary and should be removed with upcoming enhancements to UCS per-SLR constraint generation.
#  add_cells_to_pblock [get_pblocks pblock_dynamic_SLR${i}] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs*ip_pipereg_*_slr${i}_03"]
#}
# Explicity define pblock instead of using loop variable.
#add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/*ict_axi_ctrl_user_03"]
#add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/plram_mem03"] -quiet
#add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/plram_mem03_bram"] -quiet

# JUSTIFICATION: CR-1058924
# Per SLR reset distribution pipelines require some additional placement assistance to reduce the likelihood of unrouted nets.
# This placement directive is temporary and should be removed with upcoming enhancements to UCS per-SLR constraint generation.
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs*fanout_aresetn*_slr2_4"]
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR1] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs*fanout_aresetn*_slr1_4"]
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs*fanout_aresetn*_slr0_4"]


add_cells_to_pblock [get_pblocks pblock_dynamic_SLR0] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/psr_ddr4_mem00"] -quiet
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR1] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/psr_ddr4_mem01"] -quiet
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/psr_ddr4_mem02"] -quiet

add_cells_to_pblock [get_pblocks pblock_dynamic_SLR0] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/ddr4_mem00_ctrl_cc"] -quiet
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR1] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/ddr4_mem01_ctrl_cc"] -quiet
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/ddr4_mem02_ctrl_cc"] -quiet

add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/ddr4_mem02_ctrl_cc"] -quiet
add_cells_to_pblock [get_pblocks pblock_dynamic_SLR2] [get_cells -hierarchical -filter "NAME =~ $partition_path/*memory_subsystem/inst/memory/ddr4_mem02_ctrl_cc"] -quiet


# JUSTIFICATION:
# Assist tool in placement of reset fanout placement.
create_pblock pblock_u200_ucs_fanout_slr0
resize_pblock pblock_u200_ucs_fanout_slr0 -add CLOCKREGION_X0Y5:CLOCKREGION_X1Y9
set_property PARENT pblock_dynamic_region [get_pblocks pblock_u200_ucs_fanout_slr0]

add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/aclk_kernel_00_hierarchy/fanout_aresetn_kernel_00/fanout_aresetn_kernel_00_slr0_2"]
add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/aclk_kernel_01_hierarchy/fanout_aresetn_kernel_01/fanout_aresetn_kernel_01_slr0_2"]
add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/fanout_aresetn_ctrl/fanout_aresetn_ctrl_slr0_2"]
add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/fanout_aresetn_pcie/fanout_aresetn_pcie_slr0_2"]
add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/aclk_kernel_00_hierarchy/fanout_aresetn_kernel_00/fanout_aresetn_kernel_00_slr0_3"]
add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/aclk_kernel_01_hierarchy/fanout_aresetn_kernel_01/fanout_aresetn_kernel_01_slr0_3"]
add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/fanout_aresetn_ctrl/fanout_aresetn_ctrl_slr0_3"]
add_cells_to_pblock [get_pblocks pblock_u200_ucs_fanout_slr0] [get_cells -hierarchical -filter "NAME =~ $partition_path/ss_ucs/inst/fanout_aresetn_pcie/fanout_aresetn_pcie_slr0_3"]

puts "END: PLATFORM_PRE_OPT_TCL"
