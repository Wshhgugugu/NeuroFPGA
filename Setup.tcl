# Setup.tcl — Vivado 工程装配 (绝对路径, 在 Vivado TCL Console 内 source)
set proj_root "E:/AMD_FPGA/Projects/Sim_GPU - Copy"

# ========== Design Sources ==========
add_files [glob -nocomplain ${proj_root}/rtl/common/*.v ${proj_root}/rtl/common/*.sv]
add_files [glob -nocomplain ${proj_root}/rtl/sensor/*.v]
add_files [glob -nocomplain ${proj_root}/rtl/img_proc/*.v]
add_files [glob -nocomplain ${proj_root}/rtl/snn/*.v]
add_files [glob -nocomplain ${proj_root}/rtl/display/*.v]
add_files [glob -nocomplain ${proj_root}/rtl/interconnect/*.v]
add_files [glob -nocomplain ${proj_root}/rtl/riscv/*.v]
add_files ${proj_root}/rtl/top/vision_top.v
add_files ${proj_root}/rtl/sensor/ov5640_init_table.vh

# ========== Constraints ==========
add_files -fileset constrs_1 ${proj_root}/constraints/pins.xdc
add_files -fileset constrs_1 ${proj_root}/constraints/timing.xdc
add_files -fileset constrs_1 ${proj_root}/constraints/io_standard.xdc

# ========== Simulation Sources ==========
add_files -fileset sim_1 [glob -nocomplain ${proj_root}/sim/tb/*.sv]
add_files -fileset sim_1 [glob -nocomplain ${proj_root}/sim/stimulus/*.hex]

# ========== Utility / Memory ==========
add_files -fileset utils_1 [glob -nocomplain ${proj_root}/scripts/*.py]
add_files -fileset utils_1 ${proj_root}/mem/weights_snn.hex
add_files -fileset utils_1 ${proj_root}/mem/weights_snn.coe

# ========== Include 路径 ==========
set_property include_dirs [list ${proj_root}/rtl/sensor ${proj_root}/mem] [current_fileset]

# 内存初始化路径 (xsim 运行目录 = 工程根)
set_property -name {xsim.simulate.runtime} -value {1000ns} -objects [get_filesets sim_1] -quiet

puts "OK: all sources added (glob-based, resilient to new files)"
