# ============================================================================
# io_standard.xdc — 电气标准与配置 (Smart Zynq SP2, Bank 均 3.3V)
# ============================================================================
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# 上拉: SCCB 开漏总线
set_property PULLUP true [get_ports sccb_sda]
set_property PULLUP true [get_ports sccb_scl]

# 摄像头 DVP 复位后浮空: 内部下拉防串扰 (同已验证工程)
set_property PULLDOWN true [get_ports pclk]
set_property PULLDOWN true [get_ports cam_href]
set_property PULLDOWN true [get_ports cam_vsync]
set_property PULLDOWN true [get_ports {cam_data[*]}]

# ============================================================================
# 显示/仿真端口: 本板 (SP2) 无 HDMI, TMDS 码字总线在 Phase 9 板级适配层
# 接入 ST7789 LCD 时绑定引脚。此处仅定 IOSTANDARD 消除 NSTD-1;
# UCIO-1 (未绑定 PACKAGE_PIN) 为上板前已知项, 不阻塞本流程。
# ============================================================================
set_property IOSTANDARD LVCMOS33 [get_ports {tmds_r[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tmds_g[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tmds_b[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {tmds_clk[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_hs]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_vs]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_de]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sim_s_data[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports sim_s_valid]
set_property IOSTANDARD LVCMOS33 [get_ports sim_s_sof]
set_property IOSTANDARD LVCMOS33 [get_ports sim_e_valid]
set_property IOSTANDARD LVCMOS33 [get_ports sim_e_edge]
set_property IOSTANDARD LVCMOS33 [get_ports sim_e_eof]
