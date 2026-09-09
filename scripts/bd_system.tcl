# bd_system.tcl — 薄壳 BD: PS7 + SmartConnect (+ AXI DMA)   [SoC 蓝图 D2/D6]
#   被 build_soc.tcl source; 也可单独在 Vivado 工程里 source 后 write_bd_tcl 回写。
#   板级参数 (已按 E:/AMD_FPGA/Projects/硬件配置文档 SmartZynq_SP2_20240115.pdf 与
#   Petalinux 教程 p8-p9 实填):
#     DDR3  : MT41K256M16 RE-125 (板上为 TW-107, 教程用 RE-125 预设), 单颗 16 位, 512MB
#     PS_CLK: 33.333MHz 晶振 (F7)
#     UART  : FT2232H 接的是 **PL 引脚** L17(ZYNQ_TX)/M17(ZYNQ_RX) -> PS UART0 走 EMIO
#             再由 soc_top 引到这两个脚 (constraints/soc.xdc)
#     SD    : TF 卡 -> SD0 (MIO40-45, Zynq 标准位; 教程默认, 上板核对一次)
#     QSPI  : W25Q128 -> MIO1-6 单片
#     ETH   : RTL8211E 千兆 PHY 接 PL 侧 (EMIO RGMII 需 PL 逻辑), 本阶段不启用
#     LCD 240x240: PL SPI, 与本设计显示链另议; HDMI: PL bank 33/34
set bd_name system
create_bd_design $bd_name

# ---------------- PS7 ----------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART0_UART0_IO {EMIO} \
    CONFIG.PCW_UART0_BAUD_RATE {115200} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
    CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE {1} \
    CONFIG.PCW_UIPARAM_DDR_ENABLE {1} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
    CONFIG.PCW_UIPARAM_DDR_ECC {Disabled} \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
] $ps
# UART0 经 EMIO 外引 (soc_top 接到 PL 脚 L17/M17)
create_bd_port -dir O UART_TX
create_bd_port -dir I UART_RX
connect_bd_net [get_bd_ports UART_TX] [get_bd_pins ps7/UART0_TX]
connect_bd_net [get_bd_ports UART_RX] [get_bd_pins ps7/UART0_RX]
# DDR/MIO 固定引脚外引
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} $ps

# ---------------- FCLK0 域同步复位 (proc_sys_reset) ----------------
# 给 DMA/SmartConnect 用, 消 "接了异步复位源" 警告; 对外仍引 FCLK_RESET0_N
# 给 soc_top 的 PL 复位同步器 (它自己再做 2FF)
set psr [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_fclk0]
connect_bd_net [get_bd_pins rst_fclk0/slowest_sync_clk] [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins rst_fclk0/ext_reset_in]     [get_bd_pins ps7/FCLK_RESET0_N]

# ---------------- 外部 PL 时钟 (cfg 50MHz 给 GP0 互连) ----------------
create_bd_port -dir I -type clk -freq_hz 50000000 PL_ACLK
set_property CONFIG.ASSOCIATED_RESET {} [get_bd_ports PL_ACLK]

# ---------------- GP0 -> SmartConnect -> M_AXI_PL (AXI4-Lite 外引) ----------------
set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_gp0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {2}] $sc
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins sc_gp0/S00_AXI]
connect_bd_net [get_bd_pins ps7/M_AXI_GP0_ACLK] [get_bd_ports PL_ACLK]
connect_bd_net [get_bd_pins sc_gp0/aclk]  [get_bd_ports PL_ACLK]
connect_bd_net [get_bd_pins sc_gp0/aclk1] [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins sc_gp0/aresetn] [get_bd_pins rst_fclk0/peripheral_aresetn]

set m_axi [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_PL]
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.DATA_WIDTH {32} CONFIG.ADDR_WIDTH {32}] $m_axi
connect_bd_intf_net [get_bd_intf_pins sc_gp0/M00_AXI] $m_axi

# ---------------- 中断 ----------------
create_bd_port -dir I -type intr IRQ_F2P
set_property CONFIG.SENSITIVITY {LEVEL_HIGH} [get_bd_ports IRQ_F2P]
connect_bd_net [get_bd_ports IRQ_F2P] [get_bd_pins ps7/IRQ_F2P]

# ---------------- FCLK0 / RESET0 外引 ----------------
create_bd_port -dir O -type clk FCLK_CLK0
connect_bd_net [get_bd_ports FCLK_CLK0] [get_bd_pins ps7/FCLK_CLK0]
create_bd_port -dir O -type rst FCLK_RESET0_N
connect_bd_net [get_bd_ports FCLK_RESET0_N] [get_bd_pins ps7/FCLK_RESET0_N]

# ---------------- AXI DMA (M18): S_AXIS -> S2MM -> HP0 ----------------
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_sg_length_width {23} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {8} \
] $dma
# 控制口: SmartConnect 第二个 MI (FCLK0 域)
connect_bd_intf_net [get_bd_intf_pins sc_gp0/M01_AXI] [get_bd_intf_pins dma0/S_AXI_LITE]
# 数据口 -> HP0
set sc_hp [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_hp0]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $sc_hp
connect_bd_intf_net [get_bd_intf_pins dma0/M_AXI_S2MM] [get_bd_intf_pins sc_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma0/M_AXI_MM2S] [get_bd_intf_pins sc_hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_hp0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]
foreach c {dma0/s_axi_lite_aclk dma0/m_axi_s2mm_aclk dma0/m_axi_mm2s_aclk sc_hp0/aclk ps7/S_AXI_HP0_ACLK} {
    connect_bd_net [get_bd_pins $c] [get_bd_pins ps7/FCLK_CLK0]
}
connect_bd_net [get_bd_pins dma0/axi_resetn] [get_bd_pins rst_fclk0/peripheral_aresetn]
connect_bd_net [get_bd_pins sc_hp0/aresetn]  [get_bd_pins rst_fclk0/peripheral_aresetn]
# AXIS 外引 (来自 vision_top.m_axis_*; MM2S 出口 M19 再引)
set s_axis [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS]
set_property -dict [list CONFIG.TDATA_NUM_BYTES {8} CONFIG.HAS_TLAST {1} CONFIG.HAS_TKEEP {1}] $s_axis
connect_bd_intf_net $s_axis [get_bd_intf_pins dma0/S_AXIS_S2MM]
set_property CONFIG.ASSOCIATED_BUSIF {S_AXIS} [get_bd_ports FCLK_CLK0]
# DMA 中断也并进 PS (IRQ_F2P 位宽 2: [0]=vision irq [1]=s2mm)
set_property CONFIG.PCW_IRQ_F2P_INTR {1} $ps
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irq_cc]
set_property CONFIG.NUM_PORTS {3} $cc
delete_bd_objs [get_bd_nets -of_objects [get_bd_ports IRQ_F2P]]
connect_bd_net [get_bd_ports IRQ_F2P]      [get_bd_pins irq_cc/In0]
connect_bd_net [get_bd_pins dma0/s2mm_introut] [get_bd_pins irq_cc/In1]
connect_bd_net [get_bd_pins dma0/mm2s_introut] [get_bd_pins irq_cc/In2]
connect_bd_net [get_bd_pins irq_cc/dout]   [get_bd_pins ps7/IRQ_F2P]

# ---------------- 地址 ----------------
assign_bd_address
set_property offset 0x40000000 [get_bd_addr_segs {ps7/Data/SEG_M_AXI_PL_Reg}]
set_property range  4K         [get_bd_addr_segs {ps7/Data/SEG_M_AXI_PL_Reg}]
set_property offset 0x40400000 [get_bd_addr_segs {ps7/Data/SEG_dma0_Reg}]

validate_bd_design
save_bd_design
