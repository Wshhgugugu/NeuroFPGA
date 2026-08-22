# build.tcl — 非工程模式综合+实现+报告 (vivado -mode batch -source)
# Phase 8 时序收敛流程: synth -> opt -> place -> phys_opt -> route
#   -> 时序/利用率/CDC 报告
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
  rtl/riscv/vexriscv_wrapper.v rtl/top/vision_top.v]

read_verilog -sv $rtl_files
read_xdc constraints/pins.xdc
read_xdc constraints/timing.xdc
read_xdc constraints/io_standard.xdc

synth_design -top vision_top -part xc7z020clg484-1 \
    -include_dirs [list $proj_root/rtl/sensor $proj_root/mem]

# 资源报告
report_utilization -file out/utilization.rpt
report_utilization -hierarchical -file out/util_hier.rpt

opt_design
place_design
phys_opt_design
route_design

# 时序 / CDC / DRC 报告
report_timing_summary -file out/timing_summary.rpt
report_cdc -file out/cdc.rpt
report_drc -file out/drc.rpt
report_methodology -file out/methodology.rpt

# WNS/TNS 摘要
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]]
set tns [get_property TNS [get_timing_paths -max_paths 1 -nworst 1 -quiet] -quiet]
puts "RESULT: WNS = $wns ns"
report_timing_summary -delay_type max -max_paths 10 -file out/worst_paths.rpt

# 不产比特流 (上板前还需 ILA/引脚复查)
write_checkpoint -force out/vision_top_routed.dcp
puts "BUILD DONE"
