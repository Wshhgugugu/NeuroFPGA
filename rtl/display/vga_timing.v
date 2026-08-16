`timescale 1ns/1ps
// ============================================================================
// vga_timing — 参数化视频时序 (默认 720p60: 74.25MHz 像素钟)
//   1280x720@60: HT=1650 (HA=1280, HF=110, HS=40, HB=220)
//                VT=750  (VA=720,  VF=5,  VS=5,  VB=20)
//   hs/vs 高有效; de = 数据窗口; x/y 为活动区坐标
// ============================================================================
module vga_timing #(
    parameter integer H_ACT = 1280,
    parameter integer H_FP  = 110,
    parameter integer H_PW  = 40,
    parameter integer H_BP  = 220,
    parameter integer V_ACT = 720,
    parameter integer V_FP  = 5,
    parameter integer V_PW  = 5,
    parameter integer V_BP  = 20,
    parameter integer HSYNC_POL = 1,   // 1=高有效
    parameter integer VSYNC_POL = 1
)(
    input  wire clk,
    input  wire rst_n,

    output wire                  hs,
    output wire                  vs,
    output wire                  de,
    output wire [12:0]           x,     // 0..H_ACT-1
    output wire [12:0]           y,     // 0..V_ACT-1
    output wire                  sof    // 帧首像素 (de & x==0 & y==0)
);

    localparam integer H_TOTAL = H_ACT + H_FP + H_PW + H_BP;
    localparam integer V_TOTAL = V_ACT + V_FP + V_PW + V_BP;

    localparam integer HB0 = H_ACT + H_FP;            // hs 起始
    localparam integer HB1 = H_ACT + H_FP + H_PW;     // hs 结束
    localparam integer VB0 = V_ACT + V_FP;
    localparam integer VB1 = V_ACT + V_FP + V_PW;

    reg [12:0] cx, cy;

    wire last_px = (cx == H_TOTAL-1) && (cy == V_TOTAL-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cx <= 0; cy <= 0;
        end else if (last_px) begin
            cx <= 0; cy <= 0;
        end else if (cx == H_TOTAL-1) begin
            cx <= 0; cy <= cy + 1'b1;
        end else begin
            cx <= cx + 1'b1;
        end
    end

    assign hs = (cx >= HB0) && (cx < HB1) ? HSYNC_POL[0] : ~HSYNC_POL[0];
    assign vs = (cy >= VB0) && (cy < VB1) ? VSYNC_POL[0] : ~VSYNC_POL[0];
    assign de = (cx < H_ACT) && (cy < V_ACT);
    assign x  = cx;
    assign y  = cy;
    assign sof = de && (cx == 0) && (cy == 0);

endmodule
