`timescale 1ns/1ps
// ============================================================================
// synapse_array — 权重 BRAM (mem/weights_snn.coe 初始化) + 单口时分量读
//   组织: w[n][j], n=0..NNEU-1 (突触后), j=0..NIN-1 (输入通道)
//   覆盖顺序: n 外层 j 内层, 每拍一个地址; MAC 由 snn_top 驱动
// ============================================================================
module synapse_array #(
    parameter integer NNEU = 16,
    parameter integer NIN  = 64,
    parameter        INIT_FILE = "weights_snn.coe"
)(
    input  wire clk,

    input  wire          rd_en,      // 本拍读 w[cur_n][cur_j]
    input  wire [3:0]    cur_n,      // 由控制 FSM 给出 (时分)
    input  wire [5:0]    cur_j,

    output reg  signed [7:0] w       // 一拍延迟读出
);

    (* rom_style = "block" *)
    reg signed [7:0] mem [0:NNEU*NIN-1];

    initial begin
        $readmemh("mem/weights_snn.hex", mem);
    end

    always @(posedge clk) begin
        if (rd_en)
            w <= mem[{cur_n, cur_j}];
    end

endmodule
