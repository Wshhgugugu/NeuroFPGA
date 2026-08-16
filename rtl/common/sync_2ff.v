`timescale 1ns/1ps
// ============================================================================
// sync_2ff — 两级触发器同步器 (计划书 D3 允许的唯一控制位 CDC 原语)
//   仅用于单 bit 电平/脉冲展宽后的控制信号; 数据流必须走 fifo_async
// ============================================================================
module sync_2ff #(
    parameter integer STAGES = 2,          // 2..4
    parameter         INIT  = 1'b0
)(
    input  wire clk,
    input  wire rst_n,      // 异步复位
    input  wire d_in,       // 源域信号
    output wire q_out       // 目的域同步输出
);

    initial if (STAGES < 2) $error("sync_2ff: STAGES must be >= 2");

    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync_ff;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1)
                sync_ff[i] <= INIT;
        end else begin
            sync_ff[0] <= d_in;
            for (i = 1; i < STAGES; i = i + 1)
                sync_ff[i] <= sync_ff[i-1];
        end
    end

    assign q_out = sync_ff[STAGES-1];

endmodule
