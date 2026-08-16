`timescale 1ns/1ps
// ============================================================================
// gradient_mag_dir — 幅值 |Gx|+|Gy| 饱和 12-bit + 2-bit 方向量化 (D5/D6)
//   方向边界 (整数比较, 与 golden 一致, == 归下侧):
//     |Gy|*10000 <= |Gx|*4142          -> dir 0 (0°)
//     |Gy|*10000 >= |Gx|*24142         -> dir 2 (90°)
//     否则 sign(Gx)==sign(Gy)          -> dir 1 (45°) / dir 3 (135°)
// 输入 {Gy,Gx} 24-bit, 输出 {dir[1:0], mag[11:0]} 14-bit
// ============================================================================
module gradient_mag_dir #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire clk,
    input  wire rst_n,

    input  wire          s_valid,
    input  wire          s_sof,
    input  wire [23:0]   s_data,   // {Gy, Gx}
    input  wire          s_eol,
    input  wire          s_eof,

    output reg           m_valid,
    output reg  [13:0]   m_data,   // {dir, mag}
    output reg           m_sof,
    output reg           m_eol,
    output reg           m_eof
);

    wire signed [11:0] gx = s_data[11:0];
    wire signed [11:0] gy = s_data[23:12];

    wire [11:0] ax = gx[11] ? (~gx + 1) : gx;   // |Gx|
    wire [11:0] ay = gy[11] ? (~gy + 1) : gy;   // |Gy|

    // |Gx|+|Gy| 饱和 12-bit
    wire [12:0] msum = {1'b0, ax} + {1'b0, ay};
    wire [11:0] mag  = msum[12] ? 12'hFFF : msum[11:0];

    // 方向量化 (12x14 位乘)
    wire [25:0] mul_y = ay * 14'd10000;
    wire [25:0] mul_x = ax * 26'd4142;
    wire [25:0] mul_x2 = ax * 26'd24142;

    wire same_sign = (gx[11] == gy[11]);

    reg [1:0] dir;
    always @(*) begin
        if      (mul_y <= mul_x)  dir = 2'd0;
        else if (mul_y >= mul_x2) dir = 2'd2;
        else                      dir = same_sign ? 2'd1 : 2'd3;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= s_valid;
            m_data  <= {dir, mag};
            m_sof   <= s_sof;
            m_eol   <= s_eol;
            m_eof   <= s_eof;
        end
    end

endmodule
