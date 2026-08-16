`timescale 1ns/1ps
// ============================================================================
// gaussian_5x5 — 可分离高斯 [1,4,6,4,1]^2, 全移位加法 (计划书 D4)
//   行和: h_i = Σ_k W_k * pix[i][k]   (每行 10 次移位加)
//   总和: acc = Σ_i W_i * h_i
//   输出: clamp((acc + 128) >> 8, 0, 255)  与 golden 一致 (四舍五入)
// ============================================================================
module gaussian_5x5 #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire clk,
    input  wire rst_n,

    input  wire          s_valid,
    input  wire          s_sof,
    input  wire [7:0]    s_data,

    output reg           m_valid,
    output reg  [7:0]    m_data,
    output reg           m_sof,     // 首像素
    output reg           m_eol,     // 行尾
    output reg           m_eof      // 帧尾
);

    localparam int K = 5;

    wire                    wv;
    wire [K-1:0][K-1:0][7:0] wp;
    wire [$clog2(IMG_H)-1:0] wr;
    wire [$clog2(IMG_W)-1:0] wc;
    wire                    we;

    window_kxk #(.K(K), .DW(8), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_win (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .w_valid(wv), .w_pix(wp), .w_row(wr), .w_col(wc), .w_eof(we)
    );

    // 行和 h_i = p0 + 4*p1 + 6*p2 + 4*p3 + p4  (max 4080)
    function [12:0] row_sum(input [K-1:0][7:0] prow);
        reg [12:0] t;
        begin
            t = {5'b0, prow[0]} + {3'b0, prow[1], 2'b00}
              + {3'b0, prow[2], 2'b00} + {4'b0, prow[2], 1'b0}
              + {3'b0, prow[3], 2'b00} + {5'b0, prow[4]};
            row_sum = t;
        end
    endfunction

    // acc = h0 + 4*h1 + 6*h2 + 4*h3 + h4  (max 65280)
    reg [16:0] acc;
    always @(*) begin
        acc = {4'b0, row_sum(wp[0])} + {2'b0, row_sum(wp[1]), 2'b00}
            + {1'b0, row_sum(wp[2]), 2'b00} + {2'b0, row_sum(wp[2]), 1'b0}
            + {2'b0, row_sum(wp[3]), 2'b00} + {4'b0, row_sum(wp[4])};
    end

    wire [16:0] rounded = acc + 17'd128;
    wire [7:0]  gout = rounded[16] ? 8'hFF : rounded[15:8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= wv;
            m_data  <= gout;
            m_sof   <= wv && (wr == 0) && (wc == 0);
            m_eol   <= wv && (wc == IMG_W - 1);
            m_eof   <= wv && we;
        end
    end

endmodule
