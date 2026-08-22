`timescale 1ns/1ps
// ============================================================================
// framebuf_pp — 双时钟乒乓帧存 (edge 位图, Phase 9 显示链核心)
//
//   写侧 (proc 域): we/waddr/wd 流式写入当前写页; w_frame_end 翻转写页
//   读侧 (pix 域):  raddr 同步读"上一页"(读页选择于 vsync 沿同步写页选择,
//                   保证整帧无撕裂)
//   CDC: wr_sel 单 bit 电平 (30Hz 翻转) → sync_2ff; 于 vs 下降沿采样进读页
//
//   BRAM: 2 页 × 640×480×1bit = 2×9 BRAM36 (同步读, 晚 1 拍)
// ============================================================================
module framebuf_pp #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire wclk,
    input  wire wrst_n,
    input  wire        we,
    input  wire [19:0] waddr,        // 线性地址 y*IMG_W+x
    input  wire        wd,
    input  wire        w_frame_end,  // 帧尾: 写页翻转 (proc)

    input  wire rclk,
    input  wire rrst_n,
    input  wire        r_vs,         // 场同步 (pix, 下降沿换读页)
    input  wire [19:0] raddr,
    output wire        rd            // 同步读 (晚 1 拍)
);

    localparam integer DEPTH = IMG_W * IMG_H;    // 307200

    // ---- 双页 BRAM ----
    (* ram_style = "block" *) reg mem0 [0:DEPTH-1];
    (* ram_style = "block" *) reg mem1 [0:DEPTH-1];

    // ---- 写页选择 (proc) ----
    reg wr_sel;
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)        wr_sel <= 1'b0;
        else if (w_frame_end) wr_sel <= ~wr_sel;
    end

    always @(posedge wclk) begin
        if (we) begin
            if (!wr_sel) mem0[waddr] <= wd;
            else         mem1[waddr] <= wd;
        end
    end

    // ---- 写页选择跨域 (单 bit 电平, 2FF) ----
    (* ASYNC_REG = "TRUE" *) reg wr_sel_p1, wr_sel_p2;
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin wr_sel_p1 <= 0; wr_sel_p2 <= 0; end
        else begin wr_sel_p1 <= wr_sel; wr_sel_p2 <= wr_sel_p1; end
    end

    // ---- 读页选择: vs 下降沿采样同步后的写页 ----
    //   读"上一页": 读页 = ~wr_sel 同步值 (写页正在写的是另一页)
    reg rd_sel;
    reg vs_d;
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin rd_sel <= 1'b1; vs_d <= 1'b1; end
        else begin
            vs_d <= r_vs;
            if (vs_d && !r_vs)          // vs 下降沿 (帧起点)
                rd_sel <= ~wr_sel_p2;   // 跟随写页选择 (读非写页)
        end
    end

    // 读: 两数组独立同步读 (标准 BRAM 推断形状), 输出外部 2:1
    reg q0, q1;
    always @(posedge rclk) begin
        q0 <= mem0[raddr];
        q1 <= mem1[raddr];
    end

    assign rd = rd_sel ? q1 : q0;

endmodule
