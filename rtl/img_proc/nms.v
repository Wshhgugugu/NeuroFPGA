`timescale 1ns/1ps
// ============================================================================
// nms — 非极大值抑制 (沿梯度方向比较两侧邻居, 平局保留, 与 golden 一致)
//   dir 0 (0°)  : 左右邻居   [1][0], [1][2]
//   dir 2 (90°) : 上下邻居   [0][1], [2][1]
//   dir 1 (45°) : 对角 ↘↖   [0][0], [2][2]
//   dir 3 (135°): 对角 ↗↙   [0][2], [2][0]
//   中心 mag >= 两邻居 才保留, 否则输出 0
//   输入/输出 {dir, mag} 14-bit
// ============================================================================
module nms #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire clk,
    input  wire rst_n,

    input  wire          s_valid,
    input  wire          s_sof,
    input  wire [13:0]   s_data,
    input  wire          s_eol,
    input  wire          s_eof,

    output reg           m_valid,
    output reg  [13:0]   m_data,   // {dir(原样), nms_mag}
    output reg           m_sof,
    output reg           m_eol,
    output reg           m_eof
);

    localparam int K = 3;

    wire                      wv;
    wire [K-1:0][K-1:0][13:0] wp;
    wire [$clog2(IMG_H)-1:0]  wr;
    wire [$clog2(IMG_W)-1:0]  wc;
    wire                      we;

    window_kxk #(.K(K), .DW(14), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_win (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .w_valid(wv), .w_pix(wp), .w_row(wr), .w_col(wc), .w_eof(we)
    );

    wire [1:0]  dir = wp[1][1][13:12];
    wire [11:0] mag = wp[1][1][11:0];

    reg [11:0] n1, n2;
    always @(*) begin
        case (dir)
            2'd0: begin n1 = wp[1][0][11:0]; n2 = wp[1][2][11:0]; end
            2'd2: begin n1 = wp[0][1][11:0]; n2 = wp[2][1][11:0]; end
            2'd1: begin n1 = wp[0][0][11:0]; n2 = wp[2][2][11:0]; end
            default: begin n1 = wp[0][2][11:0]; n2 = wp[2][0][11:0]; end
        endcase
    end

    wire keep = (mag >= n1) && (mag >= n2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= wv;
            m_data  <= {dir, keep ? mag : 12'd0};
            m_sof   <= wv && (wr == 0) && (wc == 0);
            m_eol   <= wv && (wc == IMG_W - 1);
            m_eof   <= wv && we;
        end
    end

endmodule
