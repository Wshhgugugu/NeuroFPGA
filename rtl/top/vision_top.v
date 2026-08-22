`timescale 1ns/1ps
// ============================================================================
// vision_top — Sim_GPU 视觉加速系统顶层
//
//   数据面: OV5640 (DVP, PCLK 域) -> fifo_async (CDC) -> canny_top (proc 域)
//           -> [gray/edge 双帧存] -> color_map + vga_timing (pix 域) -> hdmi_tx
//   控制面: vexriscv_wrapper (软 FSM/VexRiscv) -> axi_crossbar_wrap 寄存器堆
//   SNN   : 8x8 池化的边缘活动 -> snn_top -> 尖峰计数 (寄存器可读)
//
//   时钟: 板载 50MHz -> MMCM: proc 150MHz / pix 74.25MHz / tmds 371.25MHz;
//         cfg 域 = 50MHz; PCLK (W17) = 摄像头像素时钟 (BUFG 后入)
//   参数 IMG_W/H 可在仿真中缩小 (tb_vision_top 用 64x64)
// ============================================================================
module vision_top #(
    parameter integer IMG_W    = 640,
    parameter integer IMG_H    = 480,
    parameter integer MAX_PASS = 64,
    parameter integer NNEU     = 16,
    parameter integer NCHAN    = 1,      // 并行处理核数 (每路独立 Canny 流水线)
    parameter         GRAY_EN  = 1,      // 1=1/4 分辨率灰度帧存 (显示模式0/1 背景)
    // MMCM: proc = 50MHz * MULT / DIV0 (180MHz=22.5/6.25; 165MHz=19.8/6)
    parameter real    CLK_MULT  = 22.5,
    parameter real    CLK_DIV0  = 6.25,
    parameter integer CLK_DIV1  = 15,      // pix = VCO/CLK_DIV1 (75MHz@VCO1125)
    parameter         SOFT_CTRL = 1     // 1=软控制面 (无需 VexRiscv 网表)
)(
    // 板载时钟/复位
    input  wire sys_clk,        // 50MHz
    input  wire rst_n_btn,      // 按键 (低有效)

    // OV5640 DVP (通道 0; 多通道时其余通道经 sim 旁路注入)
    input  wire pclk,           // 摄像头像素时钟 (时钟专用脚 W17)
    input  wire cam_href,
    input  wire cam_vsync,
    input  wire [7:0] cam_data,

    // SCCB
    output wire sccb_scl,
    inout  wire sccb_sda,

    // 摄像头电源控制
    output wire cam_rst_n,
    output wire cam_pwdn,

    // 显示 (TMDS 编码码字输出; 本板无 HDMI, 板级适配层走 LCD)
    output wire [9:0] tmds_r, tmds_g, tmds_b, tmds_clk,
    output wire       hdmi_hs, hdmi_vs, hdmi_de,

    // 状态 LED
    output wire [1:0] led,

    // 仿真用: 灰度输入流入口 (每通道独立; 通道 0 与 DVP 并联, 综合时置 0)
    input  wire [NCHAN-1:0]     sim_s_valid,
    input  wire [NCHAN-1:0]     sim_s_sof,
    input  wire [NCHAN*8-1:0]   sim_s_data,
    output wire [NCHAN-1:0]     sim_e_valid,
    output wire [NCHAN-1:0]     sim_e_edge,
    output wire [NCHAN-1:0]     sim_e_eof
);

    // ------------------------------------------------------------------
    // 复位: 异步按键, 各域同步释放
    // ------------------------------------------------------------------
    wire rst_n_cfg_raw = rst_n_btn;

    sync_2ff u_rst_cfg (.clk(sys_clk), .rst_n(rst_n_cfg_raw), .d_in(1'b1), .q_out());

    // ------------------------------------------------------------------
    // 时钟 (综合时接 MMCM; 仿真简化为系统时钟直通以保持单域可控)
    // ------------------------------------------------------------------
`ifdef SIMPLIFIED_CLK
    wire clk_proc = sys_clk;
    wire clk_pix  = sys_clk;
    wire clk_cfg  = sys_clk;
    wire mmcm_lock = 1'b1;
`else
    // MMCME2_BASE: 50MHz -> VCO(50*CLK_MULT) -> proc(VCO/CLK_DIV0) / 75MHz pix
    // (默认 180MHz: VCO 1125 = 50*22.5, /6.25; 4 核布局拥挤时 165MHz: 19.8/6)
    wire mmcm_lock;
    wire clk_proc, clk_pix;
    wire clk_mmcm_fb;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKFBOUT_MULT_F   (CLK_MULT),     // VCO = 50 * CLK_MULT
        .CLKFBOUT_PHASE    (0.0),
        .CLKIN1_PERIOD      (20.0),    // 50MHz
        .CLKOUT0_DIVIDE_F   (CLK_DIV0),    // proc 时钟
        .CLKOUT0_DUTY_CYCLE (0.5),
        .CLKOUT0_PHASE      (0.0),
        .CLKOUT1_DIVIDE     (CLK_DIV1),    // pix 时钟
        .CLKOUT1_DUTY_CYCLE (0.5),
        .CLKOUT1_PHASE      (0.0),
        .CLKOUT2_DIVIDE     (1),
        .CLKOUT3_DIVIDE     (1),
        .CLKOUT4_DIVIDE     (1),
        .CLKOUT5_DIVIDE     (1),
        .CLKOUT6_DIVIDE     (1),
        .DIVCLK_DIVIDE      (1),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKOUT0  (clk_proc),
        .CLKOUT1  (clk_pix),
        .CLKOUT2  (), .CLKOUT3  (), .CLKOUT4  (), .CLKOUT5  (), .CLKOUT6  (),
.CLKFBOUT (clk_mmcm_fb), .CLKFBIN  (clk_mmcm_fb),
        .CLKIN1   (sys_clk), .LOCKED (mmcm_lock), .PWRDWN (1'b0),
        .RST      (~rst_n_btn)
    );
    wire clk_cfg = sys_clk;
`endif

    wire rst_n_proc, rst_n_pix;
    sync_2ff u_rp (.clk(clk_proc), .rst_n(rst_n_cfg_raw && mmcm_lock), .d_in(1'b1), .q_out(rst_n_proc));
    sync_2ff u_rx (.clk(clk_pix),  .rst_n(rst_n_cfg_raw && mmcm_lock), .d_in(1'b1), .q_out(rst_n_pix));

    // ------------------------------------------------------------------
    // 传感器控制 + 采集 (cfg 域配置, pclk 域采集)
    // ------------------------------------------------------------------
    wire [15:0] chip_id;
    wire id_ok, cfg_done, cfg_ack_err;
    wire        px_v;   // pclk 域灰度流
    wire [7:0]  px_d;
    wire        px_last, px_user;

    ov5640_ctrl #(
        .IMG_W(IMG_W), .IMG_H(IMG_H),
        .CFG_CLK_FREQ(50_000_000), .CHECK_CHIP_ID(1)
    ) u_cam (
        .cfg_clk(clk_cfg), .cfg_rst_n(rst_n_cfg_raw),
        .chip_id(chip_id), .id_ok(id_ok), .cfg_done(cfg_done),
        .cfg_ack_err(cfg_ack_err),
        .scl(sccb_scl), .sda(sccb_sda),
        .cam_rst_n(cam_rst_n), .cam_pwdn(cam_pwdn),
        .pclk(pclk), .pclk_rst_n(rst_n_cfg_raw && cfg_done),
        .vsync(cam_vsync), .href(cam_href), .data_in(cam_data),
        .m_axis_tvalid(px_v), .m_axis_tdata(px_d),
        .m_axis_tlast(px_last), .m_axis_tuser(px_user), .m_axis_tready(1'b1)
    );

    // ------------------------------------------------------------------
    // NCHAN 路并行处理链: [采集旁路] -> CDC FIFO -> 读侧 -> canny_top
    // 通道 0 复用 ov5640_ctrl 输出 (DVP 实采集), 其余通道纯 sim 注入
    // ------------------------------------------------------------------
    // 配置跨域寄存器 (声明前置: generate 内引用须在声明后)
    reg [11:0] th_hi_p1, th_hi_p2, th_lo_p1, th_lo_p2;

    // 直方图统计流 (ch0 NMS 幅值, proc 域; 声明前置供 generate 引用)
    wire        hist_stat_v;
    wire [11:0] hist_stat_mag;

    wire [NCHAN-1:0] e_valid_v, e_edge_v, e_sof_v, e_eol_v, e_eof_v;
    wire [NCHAN-1:0] canny_busy_v;

    // 通道 0 输入像素流导出 (灰度帧存用)
    wire        ch0_pix_v, ch0_pix_sof, ch0_pix_eol;
    wire [7:0]  ch0_pix_d;
    assign ch0_pix_v   = g_chan[0].ch_s_valid_p;
    assign ch0_pix_d   = g_chan[0].ch_s_data_p;
    assign ch0_pix_sof = g_chan[0].ch_s_sof_p;
    assign ch0_pix_eol = g_chan[0].ch_rd_cnt == IMG_W[10:0]-1 &&
                         g_chan[0].ch_do_rd;

    genvar gc;
    generate
        for (gc = 0; gc < NCHAN; gc = gc + 1) begin : g_chan
            localparam integer CHW = IMG_W;
            localparam integer CHH = IMG_H;

            // 采集旁路: 通道 0 与 DVP 并联
            wire [7:0] ch_eff_d = sim_s_valid[gc] ? sim_s_data[gc*8 +: 8]
                                                  : ((gc == 0) ? px_d : 8'd0);
            wire       ch_eff_v = sim_s_valid[gc] | ((gc == 0) ? px_v : 1'b0);

            // CDC: pclk -> proc
            wire ch_fifo_full, ch_fifo_empty;
            wire [7:0] ch_fifo_rdata;
            reg  ch_rd_gap;
            wire ch_do_rd = !ch_rd_gap && !ch_fifo_empty;

            fifo_async #(.DW(8), .AW(11)) u_cdc (
                .wclk(pclk), .wr_rst_n(rst_n_cfg_raw && cfg_done),
                .wr_en(ch_eff_v), .wdata(ch_eff_d),
                .full(ch_fifo_full), .prog_full(),
                .rclk(clk_proc), .rd_rst_n(rst_n_proc),
                .rd_en(ch_do_rd), .rdata(ch_fifo_rdata), .empty(ch_fifo_empty)
            );

            // 读侧: 空即停; 每 W 像素后强制 >=4 拍间隙 (窗口契约)
            reg [10:0] ch_rd_cnt;
            reg        ch_rd_sof_pending;
            reg        ch_s_valid_p;
            reg [7:0]  ch_s_data_p;
            reg [2:0]  ch_gap_cnt;
            reg        ch_s_sof_p;

            always @(posedge clk_proc or negedge rst_n_proc) begin
                if (!rst_n_proc) begin
                    ch_rd_cnt <= 0; ch_rd_gap <= 0; ch_rd_sof_pending <= 1;
                    ch_s_valid_p <= 0; ch_s_data_p <= 0;
                    ch_gap_cnt <= 0; ch_s_sof_p <= 0;
                end else begin
                    ch_s_valid_p <= 1'b0;
                    ch_s_sof_p   <= 1'b0;
                    if (ch_do_rd) begin
                        ch_s_valid_p <= 1'b1;
                        ch_s_data_p  <= ch_fifo_rdata;
                        ch_s_sof_p   <= ch_rd_sof_pending;
                        ch_rd_sof_pending <= 0;
                        if (ch_rd_cnt == IMG_W-1) begin
                            ch_rd_cnt <= 0;
                            ch_rd_gap <= 1'b1;      // 行尾: 进 >=4 拍间隙
                            ch_gap_cnt <= 0;
                        end else
                            ch_rd_cnt <= ch_rd_cnt + 1'b1;
                    end else if (ch_rd_gap) begin
                        if (ch_gap_cnt == 3) ch_rd_gap <= 0;
                        else                 ch_gap_cnt <= ch_gap_cnt + 1'b1;
                    end
                end
            end

            // Canny 流水线 (proc 域); ch0 统计口引到顶层 (直方图)
            wire        ch_stat_v;
            wire [11:0] ch_stat_mag;

            canny_top #(.IMG_W(IMG_W), .IMG_H(IMG_H), .MAX_PASS(MAX_PASS)) u_canny (
                .clk(clk_proc), .rst_n(rst_n_proc),
                .s_valid(ch_s_valid_p), .s_sof(ch_s_sof_p), .s_data(ch_s_data_p),
                .s_eol(1'b0), .s_eof(1'b0),
                .th_hi(th_hi_p2), .th_lo(th_lo_p2),
                .m_valid(e_valid_v[gc]), .m_edge(e_edge_v[gc]), .m_sof(e_sof_v[gc]),
                .m_eol(e_eol_v[gc]), .m_eof(e_eof_v[gc]),
                .stat_valid(ch_stat_v), .stat_mag(ch_stat_mag),
                .busy(canny_busy_v[gc])
            );

            if (gc == 0) begin : g_stat0
                assign hist_stat_v   = ch_stat_v;
                assign hist_stat_mag = ch_stat_mag;
            end
        end
    endgenerate

    wire e_valid = e_valid_v[0];    // SNN/显示/状态取通道 0 (多核聚合为扩展点)
    wire e_edge  = e_edge_v[0];
    wire e_sof   = e_sof_v[0];
    wire e_eol   = e_eol_v[0];
    wire e_eof   = e_eof_v[0];
    wire canny_busy = |canny_busy_v;

    // ------------------------------------------------------------------
    // 控制面 (cfg 域) — AXI 主选择:
    //   SOFT_CTRL=1: vexriscv_wrapper 内置 FSM
    //   SOFT_CTRL=2: mcu8 自研 8 位 CPU (自适应阈值闭环, 见 mem/prog_adaptive.asm)
    //   SOFT_CTRL=0: 预留 VexRiscv 网表
    // ------------------------------------------------------------------
    wire        m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
    wire [11:0] m_awaddr;
    wire [31:0] m_wdata;
    wire        m_arvalid, m_arready, m_rvalid, m_rready;
    wire [11:0] m_araddr;
    wire [31:0] m_rdata;

    // wrapper 主 (SOFT_CTRL=1)
    wire        fw_awvalid, fw_awready, fw_wvalid, fw_wready, fw_bvalid, fw_bready;
    wire [11:0] fw_awaddr;
    wire [31:0] fw_wdata;
    wire        fw_arvalid, fw_arready, fw_rvalid, fw_rready;
    wire [11:0] fw_araddr;
    wire [31:0] fw_rdata;

    // MCU 主 (SOFT_CTRL=2)
    wire        mu_awvalid, mu_awready, mu_wvalid, mu_wready, mu_bvalid, mu_bready;
    wire [11:0] mu_awaddr;
    wire [31:0] mu_wdata;
    wire        mu_arvalid, mu_arready, mu_rvalid, mu_rready;
    wire [11:0] mu_araddr;
    wire [31:0] mu_rdata;

    wire [7:0]  mcu_port_addr, mcu_port_out, mcu_port_in;
    wire        mcu_port_wr, mcu_port_rd;

    // 桥的状态输入 (proc 域, 桥内部 2FF 同步)
    wire snn_busy, snn_done;
    wire [1:0]  mode_raw;
    wire [11:0] th_hi, th_lo;
    wire signed [23:0] snn_vth;
    wire snn_act_wr, snn_run_start;
    wire [5:0] snn_act_idx;
    wire [7:0] hist_addr;
    wire [7:0] snn_act_wdata;
    (* keep = "true" *) wire [7:0] snn_cnt [0:NNEU-1];

    generate
        if (SOFT_CTRL == 2) begin : g_mcu_ctrl
            mcu8 #(.PROG("mem/prog_adaptive.hex")) u_mcu8 (
                .clk(clk_cfg), .rst_n(rst_n_cfg_raw),
                .port_addr(mcu_port_addr), .port_out(mcu_port_out),
                .port_in(mcu_port_in), .port_wr(mcu_port_wr), .port_rd(mcu_port_rd),
                .halted(), .active()
            );
            axi_mcu_bridge u_mcu_bridge (
                .clk(clk_cfg), .rst_n(rst_n_cfg_raw),
                .port_addr(mcu_port_addr), .port_out(mcu_port_out),
                .port_wr(mcu_port_wr), .port_in(mcu_port_in),
                .m_awvalid(mu_awvalid), .m_awaddr(mu_awaddr), .m_awready(mu_awready),
                .m_wvalid(mu_wvalid), .m_wdata(mu_wdata), .m_wready(mu_wready),
                .m_bvalid(mu_bvalid), .m_bready(mu_bready),
                .m_arvalid(mu_arvalid), .m_araddr(mu_araddr), .m_arready(mu_arready),
                .m_rvalid(mu_rvalid), .m_rdata(mu_rdata), .m_rready(mu_rready),
                .id_ok(id_ok), .cfg_done(cfg_done), .snn_done(snn_done),
                .snn_busy(snn_busy), .canny_busy(canny_busy)
            );
        end
    endgenerate

    vexriscv_wrapper #(.SOFT_CTRL(SOFT_CTRL)) u_cpu (
        .clk(clk_cfg), .rst_n(rst_n_cfg_raw),
        .m_awvalid(fw_awvalid), .m_awaddr(fw_awaddr), .m_awready(fw_awready),
        .m_wvalid(fw_wvalid), .m_wdata(fw_wdata), .m_wready(fw_wready),
        .m_bvalid(fw_bvalid), .m_bready(fw_bready),
        .m_arvalid(fw_arvalid), .m_araddr(fw_araddr), .m_arready(fw_arready),
        .m_rvalid(fw_rvalid), .m_rdata(fw_rdata), .m_rready(fw_rready)
    );

    // AXI 主 mux (常量选择, 综合期折叠)
    assign m_awvalid = (SOFT_CTRL == 2) ? mu_awvalid : fw_awvalid;
    assign m_awaddr  = (SOFT_CTRL == 2) ? mu_awaddr  : fw_awaddr;
    assign m_wvalid  = (SOFT_CTRL == 2) ? mu_wvalid  : fw_wvalid;
    assign m_wdata   = (SOFT_CTRL == 2) ? mu_wdata   : fw_wdata;
    assign m_bready  = (SOFT_CTRL == 2) ? mu_bready  : fw_bready;
    assign m_arvalid = (SOFT_CTRL == 2) ? mu_arvalid : fw_arvalid;
    assign m_araddr  = (SOFT_CTRL == 2) ? mu_araddr  : fw_araddr;
    assign m_rready  = (SOFT_CTRL == 2) ? mu_rready  : fw_rready;
    assign fw_awready = (SOFT_CTRL == 2) ? 1'b1 : m_awready;
    assign fw_wready  = (SOFT_CTRL == 2) ? 1'b1 : m_wready;
    assign fw_bvalid  = (SOFT_CTRL == 2) ? 1'b0 : m_bvalid;
    assign fw_arready = (SOFT_CTRL == 2) ? 1'b1 : m_arready;
    assign fw_rvalid  = (SOFT_CTRL == 2) ? 1'b0 : m_rvalid;
    assign mu_awready = (SOFT_CTRL == 2) ? m_awready : 1'b1;
    assign mu_wready  = (SOFT_CTRL == 2) ? m_wready  : 1'b1;
    assign mu_bvalid  = (SOFT_CTRL == 2) ? m_bvalid  : 1'b0;
    assign mu_arready = (SOFT_CTRL == 2) ? m_arready : 1'b1;
    assign mu_rvalid  = (SOFT_CTRL == 2) ? m_rvalid  : 1'b0;

    // 直方图 (proc 域): ch0 NMS 幅值 → 256 bin; cfg 域经寄存器堆读回
    // hist_addr (cfg→proc) 值稳定两拍; hist_data/done (proc→cfg) 准静态直采
    reg [7:0] hist_addr_p1, hist_addr_p2;
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin hist_addr_p1 <= 0; hist_addr_p2 <= 0; end
        else begin hist_addr_p1 <= hist_addr; hist_addr_p2 <= hist_addr_p1; end
    end
    wire [15:0] hist_data;
    wire        hist_done;

    hist_256 u_hist (
        .clk(clk_proc), .rst_n(rst_n_proc),
        .s_valid(hist_stat_v), .s_mag(hist_stat_mag),
        .s_sof(e_sof_v[0] && e_valid_v[0]), .s_eof(e_eof_v[0] && e_valid_v[0]),
        .rd_addr(hist_addr_p2), .rd_data(hist_data),
        .frame_done(hist_done)
    );

    axi_crossbar_wrap #(.NNEU(NNEU)) u_regs (
        .clk(clk_cfg), .rst_n(rst_n_cfg_raw),
        .s_awvalid(m_awvalid), .s_awaddr(m_awaddr), .s_awready(m_awready),
        .s_wvalid(m_wvalid), .s_wdata(m_wdata), .s_wready(m_wready),
        .s_bvalid(m_bvalid), .s_bready(m_bready),
        .s_arvalid(m_arvalid), .s_araddr(m_araddr), .s_arready(m_arready),
        .s_rvalid(m_rvalid), .s_rdata(m_rdata), .s_rready(m_rready),
        .mode_raw(mode_raw), .th_hi(th_hi), .th_lo(th_lo), .snn_vth(snn_vth),
        .snn_act_wr(snn_act_wr), .snn_act_idx(snn_act_idx),
        .snn_act_wdata(snn_act_wdata), .snn_run_start(snn_run_start),
        .hist_addr(hist_addr), .hist_data(hist_data), .hist_done(hist_done),
        .canny_busy(canny_busy), .snn_busy(snn_busy), .snn_done(snn_done),
        .snn_cnt(snn_cnt), .cfg_done(cfg_done), .id_ok(id_ok), .chip_id(chip_id)
    );

    // 配置跨域: cfg -> proc (值稳定型, 两拍)
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin th_hi_p1 <= 12'd600; th_hi_p2 <= 12'd600;
                              th_lo_p1 <= 12'd200; th_lo_p2 <= 12'd200; end
        else begin th_hi_p1 <= th_hi; th_hi_p2 <= th_hi_p1;
                   th_lo_p1 <= th_lo; th_lo_p2 <= th_lo_p1; end
    end

    // ------------------------------------------------------------------
    // SNN (proc 域): 通道 0 边缘活动 8x8 池化 -> act[64]
    // (多核聚合: 各通道独立活动表为扩展点, 当前取通道 0)
    // ------------------------------------------------------------------
    reg [9:0]  ep_x, ep_y;
    reg        ep_frame_done;
    reg [7:0]  act_mem [0:63];
    integer    zi;

    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin
            ep_x <= 0; ep_y <= 0; ep_frame_done <= 0;
            for (zi = 0; zi < 64; zi = zi + 1) act_mem[zi] <= 0;
        end else begin
            if (e_valid) begin
                if (e_edge && (ep_y >> 3) < 8)
                    act_mem[{ep_y[5:3], ep_x[5:3]}] <=
                        act_mem[{ep_y[5:3], ep_x[5:3]}] + 1'b1;
                if (e_eol) begin
                    ep_x <= 0;
                    ep_y <= (e_eof) ? 0 : ep_y + 1'b1;
                    if (e_eof) ep_frame_done <= 1'b1;
                end else
                    ep_x <= ep_x + 1'b1;
            end
        end
    end

    // cfg -> proc: SNN 控制 (值稳定两拍; run 脉冲用电平化同步)
    reg snn_run_tgl_c, snn_run_tgl_p1, snn_run_tgl_p2, snn_run_tgl_p2d;
    always @(posedge clk_cfg or negedge rst_n_cfg_raw)
        if (!rst_n_cfg_raw) snn_run_tgl_c <= 0;
        else if (snn_run_start) snn_run_tgl_c <= ~snn_run_tgl_c;

    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin
            snn_run_tgl_p1 <= 0; snn_run_tgl_p2 <= 0; snn_run_tgl_p2d <= 0;
        end else begin
            snn_run_tgl_p1  <= snn_run_tgl_c;
            snn_run_tgl_p2  <= snn_run_tgl_p1;
            snn_run_tgl_p2d <= snn_run_tgl_p2;
        end
    end
    wire snn_run_p = snn_run_tgl_p2 != snn_run_tgl_p2d;   // 翻转检测 -> 脉冲

    reg act_wr_p1, act_wr_p2;
    reg [5:0] act_idx_p2; reg [7:0] act_wdata_p2;
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin
            act_wr_p1 <= 0; act_wr_p2 <= 0; act_idx_p2 <= 0; act_wdata_p2 <= 0;
        end else begin
            act_wr_p1 <= snn_act_wr; act_wr_p2 <= act_wr_p1;
            act_idx_p2 <= snn_act_idx; act_wdata_p2 <= snn_act_wdata;
        end
    end
    // 脉冲跨域: cfg 侧脉冲展宽为 8 拍电平, proc 侧沿检测
    reg [3:0] act_pulse_hold;
    always @(posedge clk_cfg or negedge rst_n_cfg_raw)
        if (!rst_n_cfg_raw)              act_pulse_hold <= 0;
        else if (snn_act_wr)             act_pulse_hold <= 4'hF;
        else if (|act_pulse_hold)        act_pulse_hold <= act_pulse_hold - 1;
    wire act_wr_eff = act_wr_p2 & (|act_pulse_hold);

    reg signed [23:0] snn_vth_p2r;
    always @(posedge clk_proc or negedge rst_n_proc)
        if (!rst_n_proc) snn_vth_p2r <= 24'sd8 <<< 16;
        else             snn_vth_p2r <= snn_vth;

    // 帧完 + SNN 空闲 -> 自动用本帧活动启动 (演示路径)
    wire snn_run_auto = ep_frame_done && !snn_busy && !snn_run_p;

    // dont_touch 实例级保护: 防止后综合优化把 SNN 计算链 (LIF/突触) 判为
    // 死逻辑挖空 (spike_cnt 经 AXI 读回是真实负载, 但 Vivado 仍会删)
    (* dont_touch = "true" *) snn_top #(.NIN(64), .NNEU(NNEU), .TSTEPS(64)) u_snn (
        .clk(clk_proc), .rst_n(rst_n_proc),
        .act_wr(act_wr_eff), .act_idx(act_idx_p2), .act_wdata(act_wdata_p2),
        .run_start(snn_run_p | snn_run_auto), .vth(snn_vth_p2r),
        .busy(snn_busy), .done(snn_done), .spike_cnt(snn_cnt)
    );

    // ------------------------------------------------------------------
    // 显示 (pix 域): 灰度/edge 经 CDC 后叠加; 本板输出 LCD (板级适配),
    // 仿真/规划输出为 hdmi 码字 + 同步 (proc->pix 视频流简化为直驱接口)
    // ------------------------------------------------------------------
    wire hs, vs, de, sof;
    wire [12:0] dsp_x, dsp_y;

    vga_timing u_vga (
        .clk(clk_pix), .rst_n(rst_n_pix),
        .hs(hs), .vs(vs), .de(de), .x(dsp_x), .y(dsp_y), .sof(sof));

    assign hdmi_hs = hs;
    assign hdmi_vs = vs;
    assign hdmi_de = de;

    // 模式切换 (消隐期)
    wire [1:0] mode_sync;
    mode_switch u_mode (
        .clk(clk_pix), .rst_n(rst_n_pix),
        .mode_raw(mode_raw), .vsync(vs), .mode(mode_sync));

    // ------------------------------------------------------------------
    // 显示链 (Phase 9): 通道 0 edge → 乒乓帧存 (proc→pix) → color_map
    // → hdmi_tx TMDS 码字。gray 不入帧存 (8bit 全分辨率乒乓需 134 BRAM
    // 超预算), 模式 0/1 的灰度背景为黑; 模式 1/2/3 完整可用。
    // snn_heat 为 proc 域计数器准静态直采 (撕裂仅影响热图一行内刷新)
    // ------------------------------------------------------------------
    // 写地址含 DSP 乘法 (y*W+x), 打一拍再进帧存 (时序收敛, 1 拍延迟无害)
    wire [19:0] fb_waddr_c = ep_y * IMG_W + ep_x;
    wire [19:0] fb_raddr   = dsp_y * IMG_W + dsp_x;
    wire        fb_rd;

    reg [19:0] fb_waddr_r;
    reg        fb_we_r, fb_wd_r, fb_fe_r;
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin
            fb_waddr_r <= 0; fb_we_r <= 0; fb_wd_r <= 0; fb_fe_r <= 0;
        end else begin
            fb_waddr_r <= fb_waddr_c;
            fb_we_r    <= e_valid_v[0];
            fb_wd_r    <= e_edge_v[0];
            fb_fe_r    <= e_eof_v[0];
        end
    end

    // 灰度 1/4 分辨率抽取 (输入流偶行偶列), 坐标跟踪与写流水对齐
    reg  [9:0] gr_x, gr_y;
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin
            gr_x <= 0; gr_y <= 0;
        end else begin
            if (ch0_pix_sof) begin gr_x <= 0; gr_y <= 0; end
            else if (ch0_pix_v) begin
                if (ch0_pix_eol) begin
                    gr_x <= 0;
                    gr_y <= gr_y + 1'b1;
                end else
                    gr_x <= gr_x + 1'b1;
            end
        end
    end

    // 写流水 (与 edge 写同级: 抽取条件 + 地址乘法都打一拍)
    wire        gwe_c = GRAY_EN && ch0_pix_v && !gr_x[0] && !gr_y[0];
    wire [16:0] gwaddr_c = (gr_y[8:1] * (IMG_W/2)) + gr_x[9:1];
    reg         gr_we_r;
    reg  [16:0] gr_waddr_r;
    reg  [7:0]  gr_wd_r;
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin
            gr_we_r <= 0; gr_waddr_r <= 0; gr_wd_r <= 0;
        end else begin
            gr_we_r    <= gwe_c;
            gr_waddr_r <= gwaddr_c;
            gr_wd_r    <= ch0_pix_d;
        end
    end
    // 灰度读地址 (显示 2x2 放大: 取 1/4 分辨率坐标)
    wire [16:0] gr_raddr = GRAY_EN ?
        (dsp_y[9:1] * (IMG_W/2)) + dsp_x[9:1] : 17'd0;
    wire [7:0]  fb_gray;

    framebuf_pp #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_fb (
        .wclk(clk_proc), .wrst_n(rst_n_proc),
        .we(fb_we_r), .waddr(fb_waddr_r), .wd(fb_wd_r),
        .w_frame_end(fb_fe_r),
        .gwe(gr_we_r), .gwaddr(gr_waddr_r), .gwd(gr_wd_r),
        .rclk(clk_pix), .rrst_n(rst_n_pix),
        .r_vs(vs), .raddr(fb_raddr), .rd(fb_rd),
        .graddr(gr_raddr), .grd(fb_gray)
    );

    wire [23:0] disp_rgb;
    wire        disp_de;

    color_map u_cmap (
        .clk(clk_pix), .rst_n(rst_n_pix),
        .mode(mode_sync), .gray(fb_gray), .edge_bit(fb_rd),
        .snn_heat(snn_cnt), .disp_y(dsp_y), .in_de(de),
        .rgb(disp_rgb), .out_de(disp_de));

    hdmi_tx u_tx (
        .clk_pix(clk_pix), .rst_n(rst_n_pix),
        .rgb(disp_rgb), .de(disp_de), .hs_sync(hs), .vs_sync(vs),
        .tmds_r_ch(tmds_r), .tmds_g_ch(tmds_g), .tmds_b_ch(tmds_b),
        .tmds_clk_word(tmds_clk),
        .bal_r(), .bal_g(), .bal_b());

    // ------------------------------------------------------------------
    assign sim_e_valid = e_valid_v;
    assign sim_e_edge  = e_edge_v;
    assign sim_e_eof   = e_eof_v;

    // LED: {cfg_done+id_ok, 通道 0 活动指示}
    // ------------------------------------------------------------------
    assign led = {cfg_done & id_ok, e_valid_v[0]};

endmodule
