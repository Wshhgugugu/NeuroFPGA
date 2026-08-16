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
