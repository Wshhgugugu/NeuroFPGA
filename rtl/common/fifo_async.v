`timescale 1ns/1ps
// ============================================================================
// fifo_async — 格雷码指针异步 FIFO (Cummings 风格, 计划书 D3 数据流 CDC 原语)
//   写/读两侧完全异步; 指针转格雷后跨域, 比较用多一位的折叠判定
//   空判: rd_gray == wr_gray_sync ; 满判: 高两位相反其余相同
// ============================================================================
module fifo_async #(
    parameter integer DW      = 8,                 // 数据位宽
    parameter integer AW      = 10,                // 地址位宽 -> 深度 2**AW
    parameter         PROG_TH = 0                  // >=此值拉 prog_full (0=不用)
)(
    // 写侧
    input  wire            wclk,
    input  wire            wr_rst_n,
    input  wire            wr_en,
    input  wire [DW-1:0]   wdata,
    output wire            full,
    output wire            prog_full,
    // 读侧
    input  wire            rclk,
    input  wire            rd_rst_n,
    input  wire            rd_en,
    output wire [DW-1:0]   rdata,
    output wire            empty
);

    localparam int DP = 1 << AW;

    // ---- 存储体: 简单双口 RAM ----
    reg [DW-1:0] mem [0:DP-1];

    // ---- 写指针 & 格雷 ----
    reg  [AW:0] wbin;
    wire [AW:0] wnext = wbin + (wr_en & ~full);
    wire [AW:0] wgray_next = (wnext >> 1) ^ wnext;

    reg  [AW:0] wgray;
    always @(posedge wclk or negedge wr_rst_n)
        if (!wr_rst_n) begin wbin <= 0; wgray <= 0; end
        else          begin wbin <= wnext; wgray <= wgray_next; end

    always @(posedge wclk)
        if (wr_en & ~full) mem[wbin[AW-1:0]] <= wdata;   // 先写当前指针, 后递增

    // ---- 读指针 & 格雷 ----
    reg  [AW:0] rbin;
    wire [AW:0] rnext = rbin + (rd_en & ~empty);
    wire [AW:0] rgray_next = (rnext >> 1) ^ rnext;

    reg  [AW:0] rgray;
    always @(posedge rclk or negedge rd_rst_n)
        if (!rd_rst_n) begin rbin <= 0; rgray <= 0; end
        else          begin rbin <= rnext; rgray <= rgray_next; end

    assign rdata = mem[rbin[AW-1:0]];

    // ---- 跨域同步 ----
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_sync;
    always @(posedge rclk or negedge rd_rst_n)
        if (!rd_rst_n) wgray_sync <= 0;
        else           wgray_sync <= wgray;

    assign empty = (rgray == wgray_sync);

    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_sync;
    always @(posedge wclk or negedge wr_rst_n)
        if (!wr_rst_n) rgray_sync <= 0;
        else           rgray_sync <= rgray;

    // ---- 满: 格雷码高两位相反, 其余位相同 ----
    wire full_c = (wgray_next == {~rgray_sync[AW:AW-1], rgray_sync[AW-2:0]});
    assign full = full_c;

    (* ASYNC_REG = "TRUE" *) reg [AW:0] rbin_sync_lvl;
    always @(posedge wclk or negedge wr_rst_n)
        if (!wr_rst_n) rbin_sync_lvl <= 0;
        else           rbin_sync_lvl <= rbin;

    assign prog_full = (PROG_TH > 0) &&
                       ((wbin[AW] - rbin_sync_lvl) >= PROG_TH[AW:0]);

endmodule
