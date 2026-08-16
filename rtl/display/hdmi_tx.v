`timescale 1ns/1ps
// ============================================================================
// hdmi_tx — TMDS 8b/10b 编码器 (DVI/HDMI 兼容, 计划 D10)
//
//   编码两步:
//     ① 最小跳变: q_m[0]=d[0]; q_m[k] = d[k-1]^d[k] ? q_m[k-1] : ~q_m[k-1]
//        (q_m[8] 为反转标志: din 中 1 的个数>4 或 ==4 且 d[0]==0 时反转低8位)
//     ② 直流平衡: 按运行不平衡度 bal 决定是否再取反, 使 0/1 长期均衡
//   DE=0 消隐期发 ctrl 码 (蓝通道可带 HSYNC/VSYNC)
//
//   说明: 本板 (SmartZynq SP2) 无 HDMI 接口, 显示走 ST7789 LCD;
//   本模块输出 10-bit 码字总线, OSERDESE 串行化在具备 HDMI 的板卡接入
//   (Phase 9 板级适配点, 见 doc/architecture.md)。
// ============================================================================
module hdmi_tx (
    input  wire clk_pix,
    input  wire rst_n,

    input  wire [23:0] rgb,
    input  wire        de,
    input  wire        hs_sync,     // 消隐期随蓝通道 ctrl 编码
    input  wire        vs_sync,

    // 10-bit 码字 (接 OSERDESE 5:1 串行化的板级适配层)
    output reg  [9:0]  tmds_r_ch,
    output reg  [9:0]  tmds_g_ch,
    output reg  [9:0]  tmds_b_ch,
    output reg  [9:0]  tmds_clk_word,
    output reg  signed [3:0] bal_r,   // 运行不平衡度 (调试/验证)
    output reg  signed [3:0] bal_g,
    output reg  signed [3:0] bal_b
);

    // ------------------------------------------------------------------
    // 单通道编码函数 (纯组合)
    // ------------------------------------------------------------------
    function [13:0] tmds_encode(
        input [7:0] d, input [1:0] ctrl, input de_i,
        input signed [3:0] bal_in);
        reg [8:0] q_m;
        reg [9:0] word;
        reg signed [3:0] disp_out;
        integer k;
        reg [3:0] dn1, qn1;
        reg [3:0] onesA;
        integer ones10;
        begin
            if (!de_i) begin
                case (ctrl)
                    2'b00: word = 10'b1101010100;
                    2'b01: word = 10'b0010101011;
                    2'b10: word = 10'b0101010100;
                    default: word = 10'b1010101011;
                endcase
                disp_out = bal_in;
            end else begin
                // ① 最小跳变
                q_m[0] = d[0];
                for (k = 1; k < 8; k = k + 1)
                    q_m[k] = d[k-1] ^ d[k] ? q_m[k-1] : ~q_m[k-1];

                dn1 = d[0]+d[1]+d[2]+d[3]+d[4]+d[5]+d[6]+d[7];
                q_m[8] = (dn1 > 4) || ((dn1 == 4) && !d[0]);
                if (q_m[8]) q_m[7:0] = ~q_m[7:0];

                qn1 = q_m[0]+q_m[1]+q_m[2]+q_m[3]+q_m[4]+q_m[5]+q_m[6]+q_m[7];

                // ② 直流平衡 (可证有界 |disp|<=4, 见 tb_display):
                //    A={0,q_m}: ones=qn1+q_m[8]; B={1,q_m[8],~q_m[7:0]}: ones=9+q_m[8]-qn1
                //    disp>=0 选 ones<=5 的一侧, disp<0 选 ones>=5 的一侧
                onesA = qn1 + q_m[8];
                if (bal_in >= 0)
                    word = (onesA <= 4'd5) ? {1'b0, q_m}
                                           : {1'b1, q_m[8], ~q_m[7:0]};
                else
                    word = (onesA >= 4'd5) ? {1'b0, q_m}
                                           : {1'b1, q_m[8], ~q_m[7:0]};

                ones10 = word[0]+word[1]+word[2]+word[3]+word[4]+
                         word[5]+word[6]+word[7]+word[8]+word[9];
                disp_out = bal_in + ones10 - 5;
            end
            tmds_encode = {disp_out, word};
        end
    endfunction

    // ------------------------------------------------------------------
    // 三通道 + 时钟通道
    // ------------------------------------------------------------------
    wire [13:0] enc_r = tmds_encode(rgb[23:16], 2'b00, de, bal_r);
    wire [13:0] enc_g = tmds_encode(rgb[15:8],  2'b00, de, bal_g);
    wire [13:0] enc_b = tmds_encode(rgb[7:0],   {vs_sync, hs_sync}, de, bal_b);

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            tmds_r_ch <= 10'b1101010100;
            tmds_g_ch <= 10'b1101010100;
            tmds_b_ch <= 10'b1101010100;
            tmds_clk_word <= 10'b0000011111;
            bal_r <= 0; bal_g <= 0; bal_b <= 0;
        end else begin
            tmds_r_ch <= enc_r[9:0];
            tmds_g_ch <= enc_g[9:0];
            tmds_b_ch <= enc_b[9:0];
            tmds_clk_word <= 10'b0000011111;
            bal_r <= enc_r[13:10];
            bal_g <= enc_g[13:10];
            bal_b <= enc_b[13:10];
        end
    end

endmodule
