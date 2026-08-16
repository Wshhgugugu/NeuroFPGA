`timescale 1ns/1ps
// ============================================================================
// double_threshold — 双阈值分类 (==th 归 strong/weak 侧, 与 golden 一致)
//   mag >= th_hi -> 2 (strong)
//   mag >= th_lo -> 1 (weak)
//   否则         -> 0
//   阈值来自寄存器堆 (已打两拍同步的稳定值)
// ============================================================================
module double_threshold #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire clk,
    input  wire rst_n,

    input  wire          s_valid,
    input  wire          s_sof,
    input  wire [13:0]   s_data,
    input  wire          s_eol,
    input  wire          s_eof,

    input  wire [11:0]   th_hi,    // 配置, 高于 12-bit mag 域
    input  wire [11:0]   th_lo,

    output reg           m_valid,
    output reg  [13:0]   m_data,   // {dir, cls[1:0] 填充}
    output reg  [1:0]    m_class,
    output reg           m_sof,
    output reg           m_eol,
    output reg           m_eof
);

    wire [11:0] mag = s_data[11:0];
    wire [1:0]  cls = (mag >= th_hi) ? 2'd2 : (mag >= th_lo) ? 2'd1 : 2'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_class <= 0;
            m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= s_valid;
            m_data  <= s_data;
            m_class <= cls;
            m_sof   <= s_sof;
            m_eol   <= s_eol;
            m_eof   <= s_eof;
        end
    end

endmodule
