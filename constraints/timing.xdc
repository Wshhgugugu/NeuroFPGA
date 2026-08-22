# ============================================================================
# timing.xdc — 时钟域与时序约束 (Smart Zynq SP2, XC7Z020-CLG484)
#   时钟: sys 50MHz / cam_pclk ~56MHz / proc 180MHz (MMCM) / pix 75MHz
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

# proc -> cfg: mcu8 桥状态 2FF 同步入口 (SOFT_CTRL=2; canny/snn 状态为准静态)
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *u_mcu_bridge/st_p1_reg*} -quiet]

# cfg -> proc: SNN 活动写口 (act_wr 两级同步限通, idx/wdata 值稳定随行)
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *act_wr_p1_reg*} -quiet]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *act_idx_p2_reg*} -quiet]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *act_wdata_p2_reg*} -quiet]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *u_snn/act_reg*} -quiet]
# cfg -> proc: SNN 阈值 (值稳定型)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *snn_vth_p2r*} -quiet]

# proc -> pix: 帧存写页选择 2FF 同步入口 (framebuf_pp)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *u_fb/wr_sel_p1_reg*} -quiet]

# cfg -> pix: mode_switch 两拍同步入口 (值稳定型, 消隐期采样)
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *u_mode/s1_reg*} -quiet]

# proc -> pix/cfg: SNN 尖峰计数读回 (准静态计数器, 30Hz 更新, 撕裂仅影响
# 热图显示的单行刷新; CPU 轮询读取期间值稳定)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_snn/spike_cnt_reg*} -quiet]
