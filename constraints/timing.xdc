# ============================================================================
# timing.xdc — 时钟域与时序约束 (Smart Zynq SP2, XC7Z020-CLG484)
#   时钟: sys 50MHz / cam_pclk ~56MHz / proc 150MHz (MMCM) / pix 74.25MHz
# ============================================================================

# PCLK 与系统/派生时钟异步 (跨域: fifo_async + sync_2ff 白名单原语)
set_clock_groups -asynchronous     -group [get_clocks -include_generated_clocks sys_clk_50m]     -group [get_clocks cam_pclk]

# 摄像头源同步输入: 依靠 IOB 首级寄存 (ov5640_ctrl 已加 IOB=TRUE)
set_false_path -from [get_ports {cam_vsync cam_href cam_data[*]}]
set_false_path -from [get_ports rst_n_btn]

# 配置寄存器跨域 (cfg -> proc): 值稳定型, 已两拍同步
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *u_rp*} -quiet]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *th_hi_p1_reg*} -quiet]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *th_lo_p1_reg*} -quiet]

# SNN 活动脉冲跨域 (电平化)
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *snn_run_tgl_p1_reg*} -quiet]
