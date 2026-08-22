# ============================================================================
# OV5640 (正点原子 ATK-MC5640-AF) + 板载LCD 引脚约束
# Smart Zynq SP2 (XC7Z020-CLG484)
#
# ===== 2026-07-15 v3 (30fps 双时钟架构) =====
# **接线变更: PCLK 从 Y21(5号位) 挪到 W17(26号位)**
#   W17 = IO_L13P_T2_MRCC_33 = 时钟专用脚的 **P 侧**, 可直接驱动 BUFG。
#   只有这样 PCLK 才能当真时钟用, 吃下 30fps 需要的 ~56MHz。
#
#   注意: 曾试过 AA18(18号位), 被 DRC 拒绝 [DRC PLIO-9]:
#     AA18 = IO_L12N_T1_MRCC_33 是差分对的 **N 侧**, 单端时钟输入只有 P 侧
#     能驱动时钟缓冲器。本 Bank 内 P 侧 + 空闲的时钟脚只有 W17。
#     (Y18 也是 P 侧 MRCC, 但被 D2 占用)
#
# 用户接线 (模块焊盘 -> FPGA 引脚):
#   VSYNC=V14  HREF=AB17  RST=W13   PWDN=U22
#   D0=Y13  D1=AB15  D2=Y18  D3=AA16  D4=AA19  D5=AB20  D6=AB21  D7=AA22
#   **PCLK=W17(26号位, 已从 Y21 挪过来)**   SCL=Y14  SDA=W18
#   FLASH(用户当NC)=V22 —— 模块 STROBE 输出, FPGA 侧不驱动, 故不约束。
#
# ATK-MC5640 板载 24MHz 有源晶振自供 XCLK, FPGA 不输出主时钟。
# ============================================================================

# ---- 系统时钟: 板载 PL 50MHz 晶振 (原理图 CLK=M19) ----
set_property PACKAGE_PIN M19 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk_50m [get_ports sys_clk]

# ---- 按键: KEY1(K21)=复位 (按下为低) ----
set_property PACKAGE_PIN K21 [get_ports rst_n_btn]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n_btn]

# ============================================================================
# 摄像头 PCLK —— 时钟专用脚 W17 (IO_L13P_T2_MRCC_33, P侧), 是真正的时钟
# 30fps 时 PCLK ≈ 55.6MHz (周期 18.0ns); 约束到 17ns(58.8MHz) 留裕量
# ============================================================================
set_property PACKAGE_PIN W17 [get_ports pclk]
set_property IOSTANDARD LVCMOS33 [get_ports pclk]
create_clock -period 17.000 -name cam_pclk [get_ports pclk]

# ---- OV5640 数据总线 D0..D7 ----
set_property PACKAGE_PIN Y13  [get_ports {cam_data[0]}]
set_property PACKAGE_PIN AB15 [get_ports {cam_data[1]}]
set_property PACKAGE_PIN Y18  [get_ports {cam_data[2]}]
set_property PACKAGE_PIN AA16 [get_ports {cam_data[3]}]
set_property PACKAGE_PIN AA19 [get_ports {cam_data[4]}]
set_property PACKAGE_PIN AB20 [get_ports {cam_data[5]}]
set_property PACKAGE_PIN AB21 [get_ports {cam_data[6]}]
set_property PACKAGE_PIN AA22 [get_ports {cam_data[7]}]

# ---- OV5640 同步/控制 ----
set_property PACKAGE_PIN AB17 [get_ports cam_href]
set_property PACKAGE_PIN V14  [get_ports cam_vsync]
set_property PACKAGE_PIN W13  [get_ports cam_rst_n]  ;# RESET 低有效
set_property PACKAGE_PIN U22  [get_ports cam_pwdn] ;# PWDN 高有效

# ---- OV5640 SCCB(I2C) ----
set_property PACKAGE_PIN Y14  [get_ports sccb_scl]
set_property PACKAGE_PIN W18  [get_ports sccb_sda]

set_property IOSTANDARD LVCMOS33 [get_ports {cam_data[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports cam_href]
set_property IOSTANDARD LVCMOS33 [get_ports cam_vsync]
set_property IOSTANDARD LVCMOS33 [get_ports cam_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports cam_pwdn]
set_property IOSTANDARD LVCMOS33 [get_ports sccb_scl]
set_property IOSTANDARD LVCMOS33 [get_ports sccb_sda]

set_property PULLUP true [get_ports sccb_sda]
set_property PULLUP true [get_ports sccb_scl]

# OV5640 复位后 DVP 引脚是三态的, 配置跑完(~120ms)前这些脚全是浮空的。
# 浮空脚会被相邻杜邦线串扰打得乱跳 —— PCLK 现在是**时钟**, 噪声会经 BUFG
# 灌进采集域。加内部下拉让它们在这段窗口里保持确定的低电平。
# (顶层还有第二道保险: 采集域复位一直拉到 cfg_done 才释放)
set_property PULLDOWN true [get_ports pclk]
set_property PULLDOWN true [get_ports cam_href]
set_property PULLDOWN true [get_ports cam_vsync]
set_property PULLDOWN true [get_ports {cam_data[*]}]


# ============================================================================
# 显示输出 (TMDS 码字总线, 板级适配层接入 LCD/HDMI 时更新)
# 备注: 本板 (SmartZynq SP2) 无 HDMI 连接器; Phase 9 板级适配走 ST7789 LCD
# ============================================================================
