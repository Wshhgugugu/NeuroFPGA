`timescale 1ns/1ps
// ============================================================================
// spike_encoder — 速率编码 (计划 D8): 活动值 act[0..NIN) -> 每步尖峰位
//   确定性 PWM: 第 t 步发 spike 当 (t < act[j]), act 0..255
// ============================================================================
module spike_encoder #(
    parameter integer NIN = 64,
    parameter integer TSTEPS = 255
)(
    input  wire clk,
    input  wire rst_n,

    input  wire         step,       // 步脉冲
    input  wire [7:0]   act [0:NIN-1],   // 输入活动 (帧级锁存)

    output reg [NIN-1:0] s_bus,     // 本步尖峰位 (step 后一拍更新)
    output reg  [7:0]   t_cnt       // 当前步 0..TSTEPS-1
);

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_cnt <= 0; s_bus <= 0;
        end else if (step) begin
            if (t_cnt == TSTEPS-1) t_cnt <= 0;
            else                   t_cnt <= t_cnt + 1'b1;
            for (j = 0; j < NIN; j = j + 1)
                s_bus[j] <= (t_cnt < act[j]);
        end
    end

endmodule
