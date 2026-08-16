`timescale 1ns/1ps
// ============================================================================
// lif_neuron — LIF 神经元, 膜电位 Q8.16 定点 (冻结规范, 与 golden_model_snn.py 一致)
//   每步: v = v - (v >>> LEAK) + (I_raw <<< 10)     [I_raw = Σ w8*s, ±8124]
//   发放: v >= VTH -> spike=1, v=0, 进入不应期 REFRA 步
//   不应期: 只泄漏不积分
//   饱和保护: v 夹在 [-128<<16, 127<<16], 溢出置位 ovf (计划 R6)
// ============================================================================
module lif_neuron #(
    parameter integer LEAK_SHIFT = 4,          // 每步泄漏 v/16
    parameter integer REFRA     = 2            // 不应期步数
)(
    input  wire clk,
    input  wire rst_n,

    input  wire              step,       // 一步积分 (单周期脉冲)
    input  wire signed [15:0] i_raw,     // Σ w8*s (Q0 整数)
    input  wire signed [23:0] vth,       // 阈值 Q8.16

    output reg               spike,
    output reg  signed [23:0] v,         // 膜电位 Q8.16
    output reg               ovf         // 饱和曾发生 (rst 清零)
);

    localparam signed [23:0] VMAX =  $signed(24'sd127 << 16);
    localparam signed [23:0] VMIN = -$signed(24'sd128 << 16);
    localparam signed [25:0] VMAX_E = {2'b00, VMAX};
    localparam signed [25:0] VMIN_E = {2'b11, VMIN};   // 符号扩展

    function signed [23:0] sat(input signed [25:0] x);
        sat = (x > VMAX_E) ? VMAX : (x < VMIN_E) ? VMIN : x[23:0];
    endfunction

    reg [7:0] refra_cnt;

    wire signed [23:0] vleak = v >>> LEAK_SHIFT;
    wire signed [23:0] i_q   = i_raw <<< 10;
    wire signed [25:0] vnext = v - vleak + i_q;

    wire sat_hi = (vnext > VMAX_E) || (vnext < VMIN_E);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v <= 0; spike <= 0; ovf <= 0; refra_cnt <= 0;
        end else begin
            spike <= 1'b0;
            if (step) begin
                if (refra_cnt != 0) begin
                    refra_cnt <= refra_cnt - 1'b1;
                    v <= sat(v - vleak);          // 同号相减必不溢出
                end else if (vnext >= vth) begin
                    spike <= 1'b1;
                    v <= 0;
                    refra_cnt <= REFRA;
                end else begin
                    v <= sat(vnext);
                end
                if (sat_hi) ovf <= 1'b1;
            end
        end
    end

endmodule
