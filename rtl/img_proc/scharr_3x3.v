`timescale 1ns/1ps
// ============================================================================
// scharr_3x3 — Scharr 梯度核, 12-bit 有符号饱和 (计划书 D5 前级)
//   Gx = [-3 0 3; -10 0 10; -3 0 3]  (x 向右正)
//   Gy = [-3 -10 -3; 0 0 0; 3 10 3]  (y 向下正)
//   饱和到 [-2048, 2047]
// 输出: {Gy[11:0], Gx[11:0]} 24-bit 流
// ============================================================================
module scharr_3x3 #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire clk,
    input  wire rst_n,

    input  wire          s_valid,
    input  wire          s_sof,
    input  wire [7:0]    s_data,

    output reg           m_valid,
    output reg  [23:0]   m_data,   // {Gy, Gx}
    output reg           m_sof,
    output reg           m_eol,
    output reg           m_eof
);

    localparam int K = 3;

    wire                  wv;
    wire [K-1:0][K-1:0][7:0] wp;
    wire [$clog2(IMG_H)-1:0] wr;
    wire [$clog2(IMG_W)-1:0] wc;
    wire                  we;

    window_kxk #(.K(K), .DW(8), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_win (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .w_valid(wv), .w_pix(wp), .w_row(wr), .w_col(wc), .w_eof(we)
    );

    // ---- 3 级流水线 (部分积 → 差值 → 求和+饱和) ----
    // Stage 1: 6 个部分积 (mul3/mul10 各 1 级移位加)
    function signed [12:0] mul3(input [7:0] v);
        mul3 = $signed({5'b0, v}) + $signed({4'b0, v, 1'b0});
    endfunction
    function signed [12:0] mul10(input [7:0] v);
        mul10 = $signed({2'b0, v, 3'b000}) + $signed({4'b0, v, 1'b0});
    endfunction

    reg signed [12:0] p_ul, p_ml, p_ll;      // Gx 列差 (左右)
    reg signed [12:0] p_t, p_b;              // Gy 行和 (上/下)
    reg        sv1_r;
    reg [$clog2(IMG_H)-1:0] wr_r;
    reg [$clog2(IMG_W)-1:0] wc_r;
    reg        we_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_ul <= 0; p_ml <= 0; p_ll <= 0;
            p_t <= 0; p_b <= 0;
            sv1_r <= 0; wr_r <= 0; wc_r <= 0; we_r <= 0;
        end else begin
            // Gx 列差: -3a+3c, -10d+10f, -3g+3j
            p_ul <= mul3(wp[0][2]) - mul3(wp[0][0]);
            p_ml <= mul10(wp[1][2]) - mul10(wp[1][0]);
            p_ll <= mul3(wp[2][2]) - mul3(wp[2][0]);
            // Gy 行和: -(3a+10b+3c), +(3g+10h+3j)
            p_t  <= mul3(wp[0][0]) + mul10(wp[0][1]) + mul3(wp[0][2]);
            p_b  <= mul3(wp[2][0]) + mul10(wp[2][1]) + mul3(wp[2][2]);
            sv1_r <= wv; wr_r <= wr; wc_r <= wc; we_r <= we;
        end
    end

    // Stage 2: 汇总 (Gx 3 项相加, Gy 下行-上行, 各 2 级加法树)
    wire signed [14:0] gx_full = $signed(p_ul) + $signed(p_ml) + $signed(p_ll);
    wire signed [14:0] gy_full = $signed(p_b) - $signed(p_t);

    reg signed [14:0] gx_r, gy_r;
    reg        sv2_r;
    reg [$clog2(IMG_H)-1:0] wr2_r;
    reg [$clog2(IMG_W)-1:0] wc2_r;
    reg        we2_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gx_r <= 0; gy_r <= 0;
            sv2_r <= 0; wr2_r <= 0; wc2_r <= 0; we2_r <= 0;
        end else begin
            gx_r <= gx_full; gy_r <= gy_full;
            sv2_r <= sv1_r; wr2_r <= wr_r; wc2_r <= wc_r; we2_r <= we_r;
        end
    end

    // Stage 3: 饱和 + 输出
    function [11:0] sat12(input signed [14:0] v);
        sat12 = (v > 15'sd2047)  ? 12'sd2047 :
                (v < -15'sd2048) ? 12'h800 : v[11:0];
    endfunction

    wire [11:0] gx_s = sat12(gx_r);
    wire [11:0] gy_s = sat12(gy_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= sv2_r;
            m_data  <= {gy_s, gx_s};
            m_sof   <= sv2_r && (wr2_r == 0) && (wc2_r == 0);
            m_eol   <= sv2_r && (wc2_r == IMG_W - 1);
            m_eof   <= sv2_r && we2_r;
        end
    end

endmodule
