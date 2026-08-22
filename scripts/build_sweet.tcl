# build_sweet.tcl — 甜点配置综合: NCHAN=2 @180MHz + mcu8 CPU (SOFT_CTRL=2)
# 用法: vivado -mode batch -source scripts/build_sweet.tcl
set proj_root "E:/AMD_FPGA/Projects/Sim_GPU - Copy"
cd $proj_root

set rtl_files [list \
  rtl/common/sync_2ff.v rtl/common/fifo_async.v rtl/common/line_buffer.v \
  rtl/common/window_kxk.v \
  rtl/sensor/sccb_master.v rtl/sensor/ov5640_ctrl.v \
  rtl/img_proc/gaussian_5x5.v rtl/img_proc/scharr_3x3.v \
  rtl/img_proc/gradient_mag_dir.v rtl/img_proc/median_3x3.v \
  rtl/img_proc/nms.v rtl/img_proc/double_threshold.v \
  rtl/img_proc/hist_256.v rtl/img_proc/hysteresis.v rtl/img_proc/canny_top.v \
  rtl/snn/lif_neuron.v rtl/snn/spike_encoder.v \
  rtl/snn/synapse_array.v rtl/snn/snn_top.v \
  rtl/display/framebuf_pp.v rtl/display/vga_timing.v rtl/display/color_map.v rtl/display/hdmi_tx.v \
  rtl/interconnect/axi_crossbar_wrap.v rtl/interconnect/mode_switch.v \
  rtl/riscv/custom_alu.v rtl/riscv/instr_decoder_ext.v \
  rtl/riscv/vexriscv_wrapper.v rtl/cpu/mcu8.v rtl/cpu/axi_mcu_bridge.v \
  rtl/top/vision_top.v]

read_verilog -sv $rtl_files
read_xdc constraints/pins.xdc
read_xdc constraints/timing.xdc
read_xdc constraints/io_standard.xdc

synth_design -top vision_top -part xc7z020clg484-1 \
    -generic NCHAN=2 -generic SOFT_CTRL=2 \
    -generic CLK_MULT=20.4 -generic CLK_DIV0=6.0 -generic CLK_DIV1=13 \
    -include_dirs [list $proj_root/rtl/sensor $proj_root/mem]

report_utilization -file out/util_sweet.rpt

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design

report_timing_summary -file out/timing_sweet.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]]
puts "RESULT(SWEET): WNS = $wns ns"
write_checkpoint -force out/vision_top_sweet.dcp
puts "BUILD DONE"
