`timescale 1ns/1ps
// ============================================================================
// line_buffer — BRAM 行缓存 (计划书 D2)
//   简单双口乒乓: 写进一行, 同时读出上一行
//   两个地址计数器各自独立推进, 复位后从 0 遍历; 读地址 = 写地址(写该行时
//   读另一行, 因为偶奇交替, 两计数器相差一行即天然乒乓)
// ============================================================================
module line_buffer #(
    parameter integer DW = 8,     // 像素位宽
    parameter integer LW = 640    // 一行像素数
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            clken,       // 本拍有效像素
    input  wire            wr_row_sel,  // 写入哪个 bank (0/1)
    input  wire [DW-1:0]   din,
    output wire [DW-1:0]   dout,        // 与 din 同拍读出的"上一行"同列像素
    output wire            dout_valid   // clken 打一拍
);

    localparam int AW = $clog2(LW);

    // 写地址: 行内游标, clken 推进, 到 LW 回 0
    reg [AW-1:0] waddr;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)          waddr <= 0;
        else if (clken)      waddr <= (waddr == LW-1) ? {AW{1'b0}} : waddr + 1'b1;

    // 读地址 = 当前列号 (与写同列, 读的是另一个 bank = 上一行同列)

    // 双 bank 乒乓 BRAM
    reg [DW-1:0] mem [0:2*LW-1];
    integer i;
    initial for (i = 0; i < 2*LW; i = i + 1) mem[i] = {DW{1'b0}};

    wire [AW:0] wbank_addr = {wr_row_sel, waddr};
    wire [AW:0] rbank_addr = {~wr_row_sel, waddr};   // 同列, 另一 bank

    always @(posedge clk)
        if (clken) mem[wbank_addr] <= din;

    reg [DW-1:0] dout_r;
    always @(posedge clk)
        if (clken) dout_r <= mem[rbank_addr];

    assign dout = dout_r;

    reg dout_valid_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) dout_valid_r <= 1'b0;
        else        dout_valid_r <= clken;

    assign dout_valid = dout_valid_r;

endmodule
