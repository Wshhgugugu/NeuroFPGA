`timescale 1ns/1ps
// ============================================================================
// canny_top — Canny 全链路集成
//   gaussian_5x5 -> scharr_3x3 -> gradient_mag_dir -> median_3x3
//   -> nms -> double_threshold -> hysteresis
//
//   输入: 8-bit 灰度流 (sof/eol/eof + 行间隙契约, 见 doc/architecture.md)
//   输出: 1-bit edge 流 (hysteresis 迭代期间 busy, 输入整帧丢弃)
//   级间: 每级 1像素/拍, 无反压 (tready 恒 1), 帧丢弃在 hysteresis 入口
// ============================================================================
module canny_top #(
    parameter integer IMG_W    = 640,
    parameter integer IMG_H    = 480,
    parameter integer MAX_PASS = 64
)(
    input  wire clk,
    input  wire rst_n,

    // 灰度输入流
    input  wire          s_valid,
    input  wire          s_sof,
    input  wire [7:0]    s_data,
    input  wire          s_eol,
    input  wire          s_eof,

    // 阈值配置 (寄存器堆来, 已同步)
    input  wire [11:0]   th_hi,
    input  wire [11:0]   th_lo,

    // edge 输出流
    output wire          m_valid,
    output wire          m_edge,
    output wire          m_sof,
    output wire          m_eol,
    output wire          m_eof,

    // 统计出口: NMS 幅值流 (直方图硬件用; 与 m_* 无关的旁路观察口)
    output wire          stat_valid,
    output wire [11:0]   stat_mag,

    output wire          busy
);

    // ------------------------------------------------------------------
    // 1. gaussian
    // ------------------------------------------------------------------
    wire        g_v, g_sof, g_eol, g_eof;
    wire [7:0]  g_d;

    gaussian_5x5 #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_gauss (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .m_valid(g_v), .m_data(g_d), .m_sof(g_sof), .m_eol(g_eol), .m_eof(g_eof)
    );

    // ------------------------------------------------------------------
    // 2. scharr
    // ------------------------------------------------------------------
    wire        sc_v, sc_sof, sc_eol, sc_eof;
    wire [23:0] sc_d;

    scharr_3x3 #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_scharr (
        .clk(clk), .rst_n(rst_n),
        .s_valid(g_v), .s_sof(g_sof), .s_data(g_d),
        .m_valid(sc_v), .m_data(sc_d), .m_sof(sc_sof), .m_eol(sc_eol), .m_eof(sc_eof)
    );

    // ------------------------------------------------------------------
    // 3. magnitude + direction
    // ------------------------------------------------------------------
    wire        md_v, md_sof, md_eol, md_eof;
    wire [13:0] md_d;

    gradient_mag_dir #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_mag (
        .clk(clk), .rst_n(rst_n),
        .s_valid(sc_v), .s_sof(sc_sof), .s_data(sc_d),
        .s_eol(sc_eol), .s_eof(sc_eof),
        .m_valid(md_v), .m_data(md_d), .m_sof(md_sof), .m_eol(md_eol), .m_eof(md_eof)
    );

    // ------------------------------------------------------------------
    // 4. median (3x3, 作用在幅值上, dir 透传)
    // ------------------------------------------------------------------
    wire        me_v, me_sof, me_eol, me_eof;
    wire [13:0] me_d;

    median_3x3 #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_med (
        .clk(clk), .rst_n(rst_n),
        .s_valid(md_v), .s_sof(md_sof), .s_data(md_d),
        .s_eol(md_eol), .s_eof(md_eof),
        .m_valid(me_v), .m_data(me_d), .m_sof(me_sof), .m_eol(me_eol), .m_eof(me_eof)
    );

    // ------------------------------------------------------------------
    // 5. nms
    // ------------------------------------------------------------------
    wire        nm_v, nm_sof, nm_eol, nm_eof;
    wire [13:0] nm_d;

    assign stat_valid = nm_v;
    assign stat_mag   = nm_d[11:0];

    nms #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_nms (
        .clk(clk), .rst_n(rst_n),
        .s_valid(me_v), .s_sof(me_sof), .s_data(me_d),
        .s_eol(me_eol), .s_eof(me_eof),
        .m_valid(nm_v), .m_data(nm_d), .m_sof(nm_sof), .m_eol(nm_eol), .m_eof(nm_eof)
    );

    // ------------------------------------------------------------------
    // 6. double threshold
    // ------------------------------------------------------------------
    wire        dt_v, dt_sof, dt_eol, dt_eof;
    wire [1:0]  dt_cls;

    double_threshold #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dt (
        .clk(clk), .rst_n(rst_n),
        .s_valid(nm_v), .s_sof(nm_sof), .s_data(nm_d),
        .s_eol(nm_eol), .s_eof(nm_eof),
        .th_hi(th_hi), .th_lo(th_lo),
        .m_valid(dt_v), .m_data(), .m_class(dt_cls),
        .m_sof(dt_sof), .m_eol(dt_eol), .m_eof(dt_eof)
    );

    // ------------------------------------------------------------------
    // 7. hysteresis
    // ------------------------------------------------------------------
    hysteresis #(.IMG_W(IMG_W), .IMG_H(IMG_H), .MAX_PASS(MAX_PASS)) u_hyst (
        .clk(clk), .rst_n(rst_n),
        .s_valid(dt_v), .s_sof(dt_sof), .s_class(dt_cls),
        .s_eol(dt_eol), .s_eof(dt_eof),
        .m_valid(m_valid), .m_edge(m_edge), .m_sof(m_sof),
        .m_eol(m_eol), .m_eof(m_eof),
        .busy(busy)
    );

endmodule
