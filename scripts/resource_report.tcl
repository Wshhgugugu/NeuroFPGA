# resource_report.tcl — 资源报告 (计划书 §. 脚本手册, batch 模式)
#   vivado -mode batch -source scripts/resource_report.tcl
set proj_root "E:/AMD_FPGA/Projects/Sim_GPU - Copy"
cd $proj_root

set rtl_files [list \
  rtl/common/sync_2ff.v rtl/common/fifo_async.v rtl/common/line_buffer.v \
  rtl/common/window_kxk.v \
  rtl/sensor/sccb_master.v rtl/sensor/ov5640_ctrl.v \
  rtl/img_proc/gaussian_5x5.v rtl/img_proc/scharr_3x3.v \
  rtl/img_proc/gradient_mag_dir.v rtl/img_proc/median_3x3.v \
  rtl/img_proc/nms.v rtl/img_proc/double_threshold.v \
  rtl/img_proc/hysteresis.v rtl/img_proc/canny_top.v \
  rtl/snn/lif_neuron.v rtl/snn/spike_encoder.v \
  rtl/snn/synapse_array.v rtl/snn/snn_top.v \
  rtl/display/vga_timing.v rtl/display/color_map.v rtl/display/hdmi_tx.v \
  rtl/interconnect/axi_crossbar_wrap.v rtl/interconnect/mode_switch.v \
  rtl/riscv/custom_alu.v rtl/riscv/instr_decoder_ext.v \
  rtl/riscv/vexriscv_wrapper.v rtl/top/vision_top.v]

read_verilog -sv $rtl_files
synth_design -top vision_top -part xc7z020clg484-1 \
    -include_dirs [list $proj_root/rtl/sensor $proj_root/mem] \
    -mode out_of_context

report_utilization -file out/resource_only_util.rpt
puts "RESOURCE REPORT DONE"
