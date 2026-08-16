# Setup.tcl — 使用绝对路径

set proj_root "E:/AMD_FPGA/Projects/Sim_GPU - Copy"

# ========== Design Sources ==========
add_files ${proj_root}/rtl/top/vision_top.v

add_files ${proj_root}/rtl/sensor/ov5640_ctrl.v
add_files ${proj_root}/rtl/sensor/sccb_master.v

add_files ${proj_root}/rtl/img_proc/gaussian_5x5.v
add_files ${proj_root}/rtl/img_proc/scharr_3x3.v
add_files ${proj_root}/rtl/img_proc/median_3x3.v
add_files ${proj_root}/rtl/img_proc/gradient_mag_dir.v
add_files ${proj_root}/rtl/img_proc/nms.v
add_files ${proj_root}/rtl/img_proc/double_threshold.v
add_files ${proj_root}/rtl/img_proc/hysteresis.v
add_files ${proj_root}/rtl/img_proc/canny_top.v

add_files ${proj_root}/rtl/common/line_buffer.v
add_files ${proj_root}/rtl/common/fifo_async.v
add_files ${proj_root}/rtl/common/sync_2ff.v

add_files ${proj_root}/rtl/display/hdmi_tx.v
add_files ${proj_root}/rtl/display/vga_timing.v
add_files ${proj_root}/rtl/display/color_map.v

add_files ${proj_root}/rtl/interconnect/axi_crossbar_wrap.v
add_files ${proj_root}/rtl/interconnect/mode_switch.v

# ========== Constraints ==========
add_files -fileset constrs_1 ${proj_root}/constraints/pins.xdc
add_files -fileset constrs_1 ${proj_root}/constraints/timing.xdc
add_files -fileset constrs_1 ${proj_root}/constraints/io_standard.xdc

# ========== Simulation Sources ==========
add_files -fileset sim_1 ${proj_root}/sim/tb/tb_vision_top.sv
add_files -fileset sim_1 ${proj_root}/sim/tb/tb_scharr.sv

add_files -fileset sim_1 ${proj_root}/sim/stimulus/test_image_64x64.hex
add_files -fileset sim_1 ${proj_root}/sim/stimulus/test_edge_case.hex

# ========== Utility Sources ==========
add_files -fileset utils_1 ${proj_root}/scripts/golden_model.py
add_files -fileset utils_1 ${proj_root}/scripts/gen_test_image.py
add_files -fileset utils_1 ${proj_root}/mem/weights_snn.coe
add_files -fileset utils_1 ${proj_root}/mem/gamma_table.coe

# ========== Include 路径 ==========
set_property include_dirs [list ${proj_root}/rtl/sensor] [current_fileset]

puts "✅ All sources added successfully!"