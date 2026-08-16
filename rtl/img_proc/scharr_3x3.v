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

    // 3*v = v + 2v ; 10*v = 8v + 2v  (全移位加)
    function signed [12:0] mul3(input [7:0] v);
        mul3 = $signed({5'b0, v}) + $signed({4'b0, v, 1'b0});
    endfunction
    function signed [12:0] mul10(input [7:0] v);
        mul10 = $signed({2'b0, v, 3'b000}) + $signed({4'b0, v, 1'b0});
    endfunction

    function signed [12:0] sx; // -3a+3c -10d+10f -3g+3j
        input [K-1:0][K-1:0][7:0] w;
        begin
            sx = mul3(w[0][2]) - mul3(w[0][0])
               + mul10(w[1][2]) - mul10(w[1][0])
               + mul3(w[2][2]) - mul3(w[2][0]);
        end
    endfunction

    function signed [12:0] sy; // -3a-10b-3c +3g+10h+3j
        input [K-1:0][K-1:0][7:0] w;
        begin
            sy = - mul3(w[0][0]) - mul10(w[0][1]) - mul3(w[0][2])
               + mul3(w[2][0]) + mul10(w[2][1]) + mul3(w[2][2]);
        end
    endfunction

    function [11:0] sat12(input signed [12:0] v);
        sat12 = (v > 13'sd2047)  ? 12'sd2047 :
                (v < -13'sd2048) ? 12'h800 : v[11:0];
    endfunction

    wire signed [12:0] gx_full = sx(wp);
    wire signed [12:0] gy_full = sy(wp);
    wire [11:0] gx_s = sat12(gx_full);
    wire [11:0] gy_s = sat12(gy_full);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= wv;
            m_data  <= {gy_s, gx_s};
            m_sof   <= wv && (wr == 0) && (wc == 0);
            m_eol   <= wv && (wc == IMG_W - 1);
            m_eof   <= wv && we;
        end
    end

endmodule
