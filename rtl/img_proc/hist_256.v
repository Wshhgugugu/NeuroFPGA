`timescale 1ns/1ps
// ============================================================================
// hist_256 — NMS 幅值直方图 (256 bin × 16bit)
//
//   输入: mag[11:0] → bin = mag[11:4]; 只统计 mag >= 128 的强候选像素
//   更新: 1 拍/像素 (分布式 RAM 异步读 + 寄存写)
//   帧协议 (冻结-读取-清零三段):
//     S_IDLE: 等 sof → S_CLEAR (frame_done 撤销)
//     S_CLEAR: 清 256 bin (新帧头 ~256 像素统计被丢弃, 0.08%, 可忽略)
//     S_ACC:   帧内累计; eof 置 frame_done=1 → S_IDLE
//   ⇒ 帧间直方图**冻结** (最长一整个帧间隔), CPU 从容读取
//   读口: cfg 域组合读 (地址稳定约定; 约束见 timing.xdc)
// ============================================================================
module hist_256 (
    input  wire clk,            // proc 域
    input  wire rst_n,

    input  wire        s_valid,
    input  wire [11:0] s_mag,
    input  wire        s_sof,   // 帧首
    input  wire        s_eof,   // 帧尾

    // cfg 域读口 (组合, CPU 写地址寄存器后稳定)
    input  wire [7:0]  rd_addr,
    output wire [15:0] rd_data,

    output reg         frame_done   // 本帧直方图就绪 (冻结至下一帧 sof)
);

    localparam [1:0] S_IDLE  = 2'd0,  // 等帧首 (直方图冻结)
                     S_CLEAR = 2'd1,  // 新帧开始: 清 bin
                     S_ACC   = 2'd2;  // 帧内累计

    (* ram_style = "distributed" *) reg [15:0] bin_cnt [0:255];

    reg [1:0] state;
    reg [7:0] clr_addr;
    reg       armed;    // 1=sof 已到 (清完直入累计); 0=复位清零 (清完等 sof)

    wire [7:0]  bin = s_mag[11:4];
    wire [15:0] cur = bin_cnt[bin];
    wire [15:0] cur_clr = bin_cnt[clr_addr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_CLEAR; clr_addr <= 0; frame_done <= 0; armed <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (s_valid && s_sof) begin
                        frame_done <= 1'b0;      // 新帧: 撤销旧就绪
                        clr_addr  <= 0;
                        armed     <= 1'b1;
                        state     <= S_CLEAR;
                    end
                end

                S_CLEAR: begin
                    bin_cnt[clr_addr] <= 16'd0;  // 无条件清 (X 也要写成 0!)
                    if (clr_addr == 8'd255)
                        state <= armed ? S_ACC : S_IDLE;
                    else
                        clr_addr <= clr_addr + 1'b1;
                end

                S_ACC: begin
                    if (s_valid && s_mag >= 12'd128 && cur != 16'hFFFF)
                        bin_cnt[bin] <= cur + 16'd1;
                    if (s_valid && s_eof) begin
                        frame_done <= 1'b1;      // 冻结, 等 CPU 读
                        armed      <= 1'b0;
                        state      <= S_IDLE;
                    end
                end

                default: begin state <= S_CLEAR; armed <= 1'b0; end
            endcase
        end
    end

    assign rd_data = bin_cnt[rd_addr];

endmodule
