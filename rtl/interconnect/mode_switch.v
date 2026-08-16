`timescale 1ns/1ps
// ============================================================================
// mode_switch — 显示模式切换 (计划 §.4; 只在场消隐期生效, 无 glitch)
//   输入: mode_raw (寄存器值, 任意时刻可变)
//   输出: mode (只在 vsync 消隐期间采样更新)
// ============================================================================
module mode_switch (
    input  wire clk,
    input  wire rst_n,
    input  wire [1:0] mode_raw,
    input  wire vsync,        // 显示时序 vs
    output reg  [1:0] mode
);

    reg vs_d;
    reg [1:0] mode_cdc;

    // 寄存器值打两拍 (值稳定型 CDC, 计划 §CDC 矩阵)
    reg [1:0] s1, s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1 <= 0; s2 <= 0; end
        else begin s1 <= mode_raw; s2 <= s1; end
    end

    // vsync 下降沿 = 场消隐起点 -> 采样
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin vs_d <= 0; mode <= 0; end
        else begin
            vs_d <= vsync;
            if (vs_d && !vsync) mode <= s2;   // 高->低: 消隐
        end
    end

endmodule
