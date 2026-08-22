`timescale 1ns/1ps
// ============================================================================
// lif_neuron — LIF 神经元, 膜电位 Q8.16 定点 (冻结规范, 与 golden_model_snn.py 一致)
//   每步: v = v - (v >>> LEAK) + (I_raw <<< 10)     [I_raw = Σ w8*s, ±8124]
//   发放: v >= VTH -> spike=1, v=0, 进入不应期 REFRA 步
//   不应期: 只泄漏不积分
//   饱和保护: v 夹在 [-128<<16, 127<<16], 溢出置位 ovf (计划 R6)
//
//   3 级流水 (180MHz 时序收敛; step 间隔 64 拍, 延迟无影响):
//     A(step):   vsub = v - vleak
//     B(step_d1): vnext = vsub + i_q; ge = (vsub + i_q) >= vth; sat_hi
//     C(step_d2): 提交 v/spike/refra/ovf  (spike 比 step 晚 2 拍)
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

    // ---- 流水节拍 (step → 提交级共 2 拍延迟) ----
    reg step_d1, step_d2;

    // ---- Stage A: vsub = v - vleak (24-bit 减法, 单拍; 符号扩展到 26-bit) ----
    reg signed [25:0] vsub_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin vsub_r <= 0; step_d1 <= 0; end
        else begin
            step_d1 <= step;
            if (step) vsub_r <= {{2{v[23]}}, v} - {{2{vleak[23]}}, vleak};
        end
    end

    // ---- Stage B: vnext / ge / sat_hi (加法与比较各 1 拍) ----
    wire signed [25:0] vnext_c = vsub_r + {{2{i_q[23]}}, i_q};
    reg signed [25:0] vnext_r;
    reg              ge_r, sat_hi_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vnext_r <= 0; ge_r <= 0; sat_hi_r <= 0; step_d2 <= 0;
        end else begin
            step_d2 <= step_d1;
            if (step_d1) begin
                // 注: 拼接结果是无符号, 与有符号数比较须 $signed() 包裹
                vnext_r  <= vnext_c;
                ge_r     <= (vnext_c >= $signed({{2{vth[23]}}, vth}));
                sat_hi_r <= (vnext_c > VMAX_E) || (vnext_c < VMIN_E);
            end
        end
    end

    // ---- Stage C: 提交 (分支选通 + 饱和, 各 ≤1 比较级) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v <= 0; spike <= 0; ovf <= 0; refra_cnt <= 0;
        end else begin
            spike <= 1'b0;
            if (step_d2) begin
                if (refra_cnt != 0) begin
                    refra_cnt <= refra_cnt - 1'b1;
                    v <= sat(vsub_r);          // 同号相减必不溢出
                end else if (ge_r) begin
                    spike <= 1'b1;
                    v <= 0;
                    refra_cnt <= REFRA;
                end else begin
                    v <= sat(vnext_r);
                end
                if (sat_hi_r) ovf <= 1'b1;
            end
        end
    end

endmodule
