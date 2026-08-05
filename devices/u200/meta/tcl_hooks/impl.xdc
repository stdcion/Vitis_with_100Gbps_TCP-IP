# ------------------------------------------------------------------------------------------------------------------------------------------------
# ulp/impl.xdc
# ------------------------------------------------------------------------------

set partition_path level0_i/ulp

###################################################
#
# ULP PBLOCK Constraints
#
###################################################

# Isolation Pblocks...
#-- X3Y4 
set pblock_ii_level0_pipe_SLR0_X3Y4 { LAGUNA_X12Y220:LAGUNA_X13Y239
                                      LAGUNA_X14Y220:LAGUNA_X15Y239
                                      SLICE_X100Y290:SLICE_X103Y299
                                      SLICE_X105Y290:SLICE_X105Y299
                                      SLICE_X108Y290:SLICE_X111Y299
                                      SLICE_X88Y290:SLICE_X89Y299
                                      SLICE_X91Y290:SLICE_X91Y299
                                      SLICE_X93Y290:SLICE_X94Y299
                                      SLICE_X97Y290:SLICE_X98Y299 }

#-- X4Y4 
set pblock_ii_level0_pipe_SLR0_X4Y4 { LAGUNA_X16Y220:LAGUNA_X17Y239
                                      LAGUNA_X18Y220:LAGUNA_X19Y239
                                      SLICE_X113Y290:SLICE_X114Y299
                                      SLICE_X117Y290:SLICE_X118Y299
                                      SLICE_X120Y290:SLICE_X120Y299
                                      SLICE_X123Y290:SLICE_X134Y299
                                      SLICE_X136Y290:SLICE_X136Y299
                                      SLICE_X138Y290:SLICE_X139Y299 }

#-- X3Y10 
set pblock_ii_level0_pipe_SLR2_X3Y10 { LAGUNA_X12Y480:LAGUNA_X13Y499
                                       LAGUNA_X14Y480:LAGUNA_X15Y499
                                       SLICE_X100Y600:SLICE_X103Y609
                                       SLICE_X105Y600:SLICE_X105Y609
                                       SLICE_X108Y600:SLICE_X111Y609
                                       SLICE_X88Y600:SLICE_X89Y609
                                       SLICE_X91Y600:SLICE_X91Y609
                                       SLICE_X93Y600:SLICE_X94Y609
                                       SLICE_X97Y600:SLICE_X98Y609 }

#-- X4Y10
set pblock_ii_level0_pipe_SLR2_X4Y10 { LAGUNA_X16Y480:LAGUNA_X17Y499
                                       LAGUNA_X18Y480:LAGUNA_X19Y499
                                       SLICE_X113Y600:SLICE_X114Y609
                                       SLICE_X117Y600:SLICE_X118Y609
                                       SLICE_X120Y600:SLICE_X120Y609
                                       SLICE_X123Y600:SLICE_X134Y609
                                       SLICE_X136Y600:SLICE_X136Y609
                                       SLICE_X138Y600:SLICE_X139Y609 }

#-- X5Y10
set pblock_ii_level0_pipe_SLR2_X5Y10 { LAGUNA_X20Y480:LAGUNA_X21Y499
                                       LAGUNA_X22Y480:LAGUNA_X23Y499
                                       SLICE_X142Y600:SLICE_X149Y609
                                       SLICE_X151Y600:SLICE_X151Y609
                                       SLICE_X153Y600:SLICE_X154Y609
                                       SLICE_X158Y600:SLICE_X159Y609
                                       SLICE_X162Y600:SLICE_X162Y609
                                       SLICE_X163Y600:SLICE_X164Y609
                                       SLICE_X166Y600:SLICE_X167Y609 }

#------------------------------------
# ULP
#------------------------------------

# SLR0
set pblock_dynamic_SLR0 [ create_pblock pblock_dynamic_SLR0 ]

resize_pblock $pblock_dynamic_SLR0 -add { CLOCKREGION_X0Y0:CLOCKREGION_X5Y4 }
resize_pblock $pblock_dynamic_SLR0 -remove $pblock_ii_level0_pipe_SLR0_X3Y4
resize_pblock $pblock_dynamic_SLR0 -remove $pblock_ii_level0_pipe_SLR0_X4Y4

# SLR2
set pblock_dynamic_SLR2 [ create_pblock pblock_dynamic_SLR2 ]

resize_pblock $pblock_dynamic_SLR2 -add { CLOCKREGION_X0Y10:CLOCKREGION_X5Y14 }
resize_pblock $pblock_dynamic_SLR2 -remove $pblock_ii_level0_pipe_SLR2_X3Y10
resize_pblock $pblock_dynamic_SLR2 -remove $pblock_ii_level0_pipe_SLR2_X4Y10
resize_pblock $pblock_dynamic_SLR2 -remove $pblock_ii_level0_pipe_SLR2_X5Y10

# SLR1
set pblock_dynamic_SLR1 [ create_pblock pblock_dynamic_SLR1 ]
resize_pblock $pblock_dynamic_SLR1 -add { CLOCKREGION_X0Y5:CLOCKREGION_X2Y9 }


#------------------------------------
# PBlock Properties

set_property SNAPPING_MODE ON $pblock_dynamic_SLR0
set_property SNAPPING_MODE ON $pblock_dynamic_SLR1
set_property SNAPPING_MODE ON $pblock_dynamic_SLR2

set_property PARENT [get_pblocks pblock_dynamic_region] $pblock_dynamic_SLR0
set_property PARENT [get_pblocks pblock_dynamic_region] $pblock_dynamic_SLR1
set_property PARENT [get_pblocks pblock_dynamic_region] $pblock_dynamic_SLR2

# #######################################################################
# WARNING: WORKAROUND!
# #######################################################################
#
# These constraints are added as a workaround to CR-1038346
# Remove these constraints when CR is resolved.
#
# Error codes: ERROR: [VPL 30-1112]
#
#set_property CONTAIN_ROUTING   0 [get_pblocks pblock_dynamic_SLR0]
#set_property EXCLUDE_PLACEMENT 0 [get_pblocks pblock_dynamic_SLR0]
#set_property CONTAIN_ROUTING   0 [get_pblocks pblock_dynamic_SLR1]
#set_property EXCLUDE_PLACEMENT 0 [get_pblocks pblock_dynamic_SLR1]
#set_property CONTAIN_ROUTING   0 [get_pblocks pblock_dynamic_SLR2]
#set_property EXCLUDE_PLACEMENT 0 [get_pblocks pblock_dynamic_SLR2]

# --------------------------------------------------------------------
# JUSTIFICIATION:  Kernel interrupts are level triggered but may be
# may be driven by a flop on an arbitrary clock source within the kernel.
# The set_false_path suppresses false timing failures that would otherwise be reported.

set_false_path -through  [get_pins -hierarchical -filter "NAME=~$partition_path/blp_m_irq_kernel_00*"]

# JUSTIFICATION: Like the interrupt signals, the DDR calibration signal originates in asynchronous clock domains
# that differ from pipeline clock in the isolation interface but since the signal is largely static a false path is
# sufficient to resolve the subsequent timing failures.
set_false_path -through  [get_pins -hierarchical -filter "NAME=~$partition_path/blp_m_data_ddr*"]

# --------------------------------------------------------------------
# JUSTIFICATION: CR-1049759
#
# Prior platforms have experienced spreading of memory controller logic across SLR boundaries
# leading to timing closure problems.
#
# The constraints below force the memory controller instances to be locally placed in the correct SLRs.
set_property MIG_FLOORPLAN_MODE FULL [get_cells $partition_path/*memory_subsystem/inst/memory/ddr4_mem00] -quiet
set_property MIG_FLOORPLAN_MODE FULL [get_cells $partition_path/*memory_subsystem/inst/memory/ddr4_mem01] -quiet
set_property MIG_FLOORPLAN_MODE FULL [get_cells $partition_path/*memory_subsystem/inst/memory/ddr4_mem02] -quiet

# --------------------------------------------------------------------
# JUSTIFICATION:
# Need to assure the kernel clock generation gets high priority...
set_property HIGH_PRIORITY true [get_nets -of_objects [get_pins level0_i/ulp/ss_ucs/inst/aclk_kernel_00_hierarchy/clock_throttling_aclk_kernel_00/U0/ECCLK/O]]
set_property HIGH_PRIORITY true [get_nets -of_objects [get_pins level0_i/ulp/ss_ucs/inst/aclk_kernel_01_hierarchy/clock_throttling_aclk_kernel_01/U0/ECCLK/O]]
