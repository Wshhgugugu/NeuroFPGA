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

    // ---- 4 级流水线 (abs → mag 饱和 → 乘法 → 比较) ----
    // Stage 0: |Gx|/|Gy| (1 级取反+进位)
    wire signed [11:0] gx = s_data[11:0];
    wire signed [11:0] gy = s_data[23:12];

    wire [11:0] ax = gx[11] ? (~gx + 1) : gx;   // |Gx|
    wire [11:0] ay = gy[11] ? (~gy + 1) : gy;   // |Gy|

    reg [11:0] ax_r, ay_r;
    reg        gxsgn_r, gysgn_r;
    reg        sv0_r;
    reg        ssof_r, seol_r, seof_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ax_r <= 0; ay_r <= 0;
            gxsgn_r <= 0; gysgn_r <= 0;
            sv0_r <= 0; ssof_r <= 0; seol_r <= 0; seof_r <= 0;
        end else begin
            ax_r <= ax; ay_r <= ay;
            gxsgn_r <= gx[11]; gysgn_r <= gy[11];
            sv0_r <= s_valid; ssof_r <= s_sof; seol_r <= s_eol; seof_r <= s_eof;
        end
    end

    // Stage 1: mag 饱和 (13-bit 加 + 饱和, 单拍)
    wire [12:0] msum = {1'b0, ax_r} + {1'b0, ay_r};
    wire [11:0] mag  = msum[12] ? 12'hFFF : msum[11:0];

    reg [11:0] mag_r;
    reg        sv1_r;
    reg        ssof1_r, seol1_r, seof1_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mag_r <= 0;
            sv1_r <= 0; ssof1_r <= 0; seol1_r <= 0; seof1_r <= 0;
        end else begin
            mag_r <= mag;
            sv1_r <= sv0_r; ssof1_r <= ssof_r; seol1_r <= seol_r; seof1_r <= seof_r;
        end
    end

    // Stage 2: 乘法寄存 + 符号/标志推进 (数据在此拍 = N, 下一拍输出)
    wire [25:0] mul_y = ay_r * 14'd10000;
    wire [25:0] mul_x = ax_r * 26'd4142;
    wire [25:0] mul_x2 = ax_r * 26'd24142;

    reg [25:0] mul_y_r, mul_x_r, mul_x2_r;
    reg        gxsgn2_r, gysgn2_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_y_r <= 0; mul_x_r <= 0; mul_x2_r <= 0;
            gxsgn2_r <= 0; gysgn2_r <= 0;
        end else begin
            mul_y_r <= mul_y; mul_x_r <= mul_x; mul_x2_r <= mul_x2;
            gxsgn2_r <= gxsgn_r; gysgn2_r <= gysgn_r;
        end
    end

    // Stage 3: 比较 + 输出 (mag_r 与 mul_r 同拍, 三者同进输出寄存)
    wire same_sign = (gxsgn2_r == gysgn2_r);

    reg [1:0] dir;
    always @(*) begin
        if      (mul_y_r <= mul_x_r)  dir = 2'd0;
        else if (mul_y_r >= mul_x2_r) dir = 2'd2;
        else                          dir = same_sign ? 2'd1 : 2'd3;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= sv1_r;
            m_data  <= {dir, mag_r};
            m_sof   <= ssof1_r;
            m_eol   <= seol1_r;
            m_eof   <= seof1_r;
        end
    end

endmodule
