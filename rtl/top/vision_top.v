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
    parameter         SOFT_CTRL = 1     // 1=软控制面 (无需 VexRiscv 网表)
)(
    // 板载时钟/复位
    input  wire sys_clk,        // 50MHz
    input  wire rst_n_btn,      // 按键 (低有效)

    // OV5640 DVP
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

    // 仿真用: 灰度输入流入口 (pclk 域旁路, 综合时置 0)
    input  wire sim_s_valid = 1'b0,
    input  wire sim_s_sof   = 1'b0,
    input  wire [7:0] sim_s_data = 8'd0,
    output wire sim_e_valid,
    output wire sim_e_edge,
    output wire sim_e_eof
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
    // MMCM: 50MHz in -> 150MHz (proc), 74.25MHz (pix) — 板级实现
    wire mmcm_lock;
    wire clk_proc, clk_pix;
    clk_wiz_vision u_mmcm (
        .clk_in1(sys_clk), .clk_out1(clk_proc), .clk_out2(clk_pix),
        .locked(mmcm_lock)
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

    // 仿真旁路
    wire eff_v = sim_s_valid | px_v;
    wire [7:0] eff_d = sim_s_valid ? sim_s_data : px_d;

    // ------------------------------------------------------------------
    // CDC: pclk -> proc (fifo_async, 计划 CDC 矩阵)
    // ------------------------------------------------------------------
    wire fifo_full, fifo_empty;
    wire [7:0] fifo_rdata;
    reg  rd_gap;                     // 前置声明 (实例端口引用)
    wire do_rd = !rd_gap && !fifo_empty;

    fifo_async #(.DW(8), .AW(11)) u_cdc_px (
        .wclk(pclk), .wr_rst_n(rst_n_cfg_raw && cfg_done),
        .wr_en(eff_v), .wdata(eff_d),
        .full(fifo_full), .prog_full(),
        .rclk(clk_proc), .rd_rst_n(rst_n_proc),
        .rd_en(do_rd), .rdata(fifo_rdata), .empty(fifo_empty)
    );

    // 读侧: 空即停; 输出行间隙契约 (每 W 像素后强制 >=4 空拍)
    reg [10:0] rd_cnt;
    reg        rd_sof_pending;
    reg        s_valid_p;
    reg [7:0]  s_data_p;

    reg [2:0] gap_cnt;
    reg       s_sof_p;
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin
            rd_cnt <= 0; rd_gap <= 0; rd_sof_pending <= 1;
            s_valid_p <= 0; s_data_p <= 0; gap_cnt <= 0; s_sof_p <= 0;
        end else begin
            s_valid_p <= 1'b0;
            s_sof_p   <= 1'b0;
            if (do_rd) begin
                s_valid_p <= 1'b1;
                s_data_p  <= fifo_rdata;
                s_sof_p   <= rd_sof_pending;
                rd_sof_pending <= 0;
                if (rd_cnt == IMG_W-1) begin
                    rd_cnt <= 0;
                    rd_gap <= 1'b1;      // 行尾: 进 >=4 拍间隙 (窗口契约)
                    gap_cnt <= 0;
                end else
                    rd_cnt <= rd_cnt + 1'b1;
            end else if (rd_gap) begin
                if (gap_cnt == 3) rd_gap <= 0;
                else              gap_cnt <= gap_cnt + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 控制面 (cfg 域)
    // ------------------------------------------------------------------
    wire        m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
    wire [11:0] m_awaddr;
    wire [31:0] m_wdata;
    wire        m_arvalid, m_arready, m_rvalid, m_rready;
    wire [11:0] m_araddr;
    wire [31:0] m_rdata;

    vexriscv_wrapper #(.SOFT_CTRL(SOFT_CTRL)) u_cpu (
        .clk(clk_cfg), .rst_n(rst_n_cfg_raw),
        .m_awvalid(m_awvalid), .m_awaddr(m_awaddr), .m_awready(m_awready),
        .m_wvalid(m_wvalid), .m_wdata(m_wdata), .m_wready(m_wready),
        .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arvalid(m_arvalid), .m_araddr(m_araddr), .m_arready(m_arready),
        .m_rvalid(m_rvalid), .m_rdata(m_rdata), .m_rready(m_rready)
    );

    wire [1:0]  mode_raw;
    wire [11:0] th_hi, th_lo;
    wire signed [23:0] snn_vth;
    wire snn_act_wr, snn_run_start;
    wire [5:0] snn_act_idx;
    wire [7:0] snn_act_wdata;
    wire canny_busy, snn_busy, snn_done;
    wire [7:0] snn_cnt [0:NNEU-1];

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
        .canny_busy(canny_busy), .snn_busy(snn_busy), .snn_done(snn_done),
        .snn_cnt(snn_cnt), .cfg_done(cfg_done), .id_ok(id_ok), .chip_id(chip_id)
    );

    // 配置跨域: cfg -> proc (值稳定型, 两拍)
    reg [11:0] th_hi_p1, th_hi_p2, th_lo_p1, th_lo_p2;
    always @(posedge clk_proc or negedge rst_n_proc) begin
        if (!rst_n_proc) begin th_hi_p1 <= 12'd600; th_hi_p2 <= 12'd600;
                              th_lo_p1 <= 12'd200; th_lo_p2 <= 12'd200; end
        else begin th_hi_p1 <= th_hi; th_hi_p2 <= th_hi_p1;
                   th_lo_p1 <= th_lo; th_lo_p2 <= th_lo_p1; end
    end

    // ------------------------------------------------------------------
    // Canny (proc 域)
    // ------------------------------------------------------------------
    wire e_valid, e_edge, e_sof, e_eol, e_eof;

    canny_top #(.IMG_W(IMG_W), .IMG_H(IMG_H), .MAX_PASS(MAX_PASS)) u_canny (
        .clk(clk_proc), .rst_n(rst_n_proc),
        .s_valid(s_valid_p), .s_sof(s_sof_p), .s_data(s_data_p),
        .s_eol(1'b0), .s_eof(1'b0),
        .th_hi(th_hi_p2), .th_lo(th_lo_p2),
        .m_valid(e_valid), .m_edge(e_edge), .m_sof(e_sof),
        .m_eol(e_eol), .m_eof(e_eof),
        .busy(canny_busy)
    );

    // ------------------------------------------------------------------
    // SNN (proc 域): 边缘活动 8x8 池化 (bin = (y/PH)*8 + x/PW) -> act[64]
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

    snn_top #(.NIN(64), .NNEU(NNEU), .TSTEPS(64)) u_snn (
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

    // (Canny 输出叠加与 color_map/hdmi_tx 的帧缓冲显示为 Phase 9 板级
    //  适配内容: proc->pix 需双时钟帧存; 仿真验证见 tb_display/tb_canny)

    assign tmds_r = 10'd0;
    assign tmds_g = 10'd0;
    assign tmds_b = 10'd0;
    assign tmds_clk = 10'b0000011111;

    // ------------------------------------------------------------------
    assign sim_e_valid = e_valid;
    assign sim_e_edge  = e_edge;
    assign sim_e_eof   = e_eof;

    // LED: {cfg_done+id_ok, 活动指示}
    // ------------------------------------------------------------------
    assign led = {cfg_done & id_ok, e_valid};

endmodule
