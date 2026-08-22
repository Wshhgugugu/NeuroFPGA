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

    // ---- 4 级流水线 (行部分积 → 行和 → 垂直部分和 → 总加+round) ----
    // Stage 1a: 行部分积 A=p0+4p1, B=6p2, C=4p3+p4 (各 1 级移位加)
    function [13:0] part_a(input [K-1:0][7:0] prow);
        part_a = {4'b0, prow[0]} + {2'b0, prow[1], 2'b00};
    endfunction
    function [13:0] part_b(input [K-1:0][7:0] prow);
        part_b = {2'b0, prow[2], 2'b00} + {3'b0, prow[2], 1'b0};
    endfunction
    function [13:0] part_c(input [K-1:0][7:0] prow);
        part_c = {2'b0, prow[3], 2'b00} + {4'b0, prow[4]};
    endfunction

    reg [13:0] pa_r [0:4];
    reg [13:0] pb_r [0:4];
    reg [13:0] pc_r [0:4];
    reg        sv0_r;
    reg [$clog2(IMG_H)-1:0] wr0_r;
    reg [$clog2(IMG_W)-1:0] wc0_r;
    reg        we0_r;
    integer    gi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (gi = 0; gi < 5; gi = gi + 1) begin
                pa_r[gi] <= 0; pb_r[gi] <= 0; pc_r[gi] <= 0;
            end
            sv0_r <= 0; wr0_r <= 0; wc0_r <= 0; we0_r <= 0;
        end else begin
            pa_r[0] <= part_a(wp[0]); pb_r[0] <= part_b(wp[0]); pc_r[0] <= part_c(wp[0]);
            pa_r[1] <= part_a(wp[1]); pb_r[1] <= part_b(wp[1]); pc_r[1] <= part_c(wp[1]);
            pa_r[2] <= part_a(wp[2]); pb_r[2] <= part_b(wp[2]); pc_r[2] <= part_c(wp[2]);
            pa_r[3] <= part_a(wp[3]); pb_r[3] <= part_b(wp[3]); pc_r[3] <= part_c(wp[3]);
            pa_r[4] <= part_a(wp[4]); pb_r[4] <= part_b(wp[4]); pc_r[4] <= part_c(wp[4]);
            sv0_r <= wv; wr0_r <= wr; wc0_r <= wc; we0_r <= we;
        end
    end

    // Stage 1b: 行和 h_i = A+B+C (1 级加, max 4080)
    reg [12:0] h_r [0:4];
    reg        sv1_r;
    reg [$clog2(IMG_H)-1:0] wr_r;
    reg [$clog2(IMG_W)-1:0] wc_r;
    reg        we_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (gi = 0; gi < 5; gi = gi + 1) h_r[gi] <= 0;
            sv1_r <= 0; wr_r <= 0; wc_r <= 0; we_r <= 0;
        end else begin
            h_r[0] <= pa_r[0] + pb_r[0] + pc_r[0];
            h_r[1] <= pa_r[1] + pb_r[1] + pc_r[1];
            h_r[2] <= pa_r[2] + pb_r[2] + pc_r[2];
            h_r[3] <= pa_r[3] + pb_r[3] + pc_r[3];
            h_r[4] <= pa_r[4] + pb_r[4] + pc_r[4];
            sv1_r <= sv0_r; wr_r <= wr0_r; wc_r <= wc0_r; we_r <= we0_r;
        end
    end

    // Stage 2: 垂直部分和 (并行, 每路 1 次移位加)
    //   p01 = h0 + 4*h1 ; p34 = 4*h3 + h4 ; p2 = 6*h2
    wire [15:0] p01 = {3'b0, h_r[0]} + {1'b0, h_r[1], 2'b00};
    wire [15:0] p34 = {1'b0, h_r[3], 2'b00} + {3'b0, h_r[4]};
    wire [15:0] p2  = {2'b0, h_r[2], 2'b00} + {3'b0, h_r[2], 1'b0};

    reg [15:0] p01_r, p34_r, p2_r;
    reg        sv2_r;
    reg [$clog2(IMG_H)-1:0] wr2_r;
    reg [$clog2(IMG_W)-1:0] wc2_r;
    reg        we2_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p01_r <= 0; p34_r <= 0; p2_r <= 0;
            sv2_r <= 0; wr2_r <= 0; wc2_r <= 0; we2_r <= 0;
        end else begin
            p01_r <= p01; p34_r <= p34; p2_r <= p2;
            sv2_r <= sv1_r; wr2_r <= wr_r; wc2_r <= wc_r; we2_r <= we_r;
        end
    end

    // Stage 3: 总加 + round + clamp
    wire [17:0] acc = {2'b0, p01_r} + {2'b0, p34_r} + {2'b0, p2_r};
    wire [17:0] rounded = acc + 18'd128;
    wire [7:0]  gout = rounded[17] ? 8'hFF : rounded[15:8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= sv2_r;
            m_data  <= gout;
            m_sof   <= sv2_r && (wr2_r == 0) && (wc2_r == 0);
            m_eol   <= sv2_r && (wc2_r == IMG_W - 1);
            m_eof   <= sv2_r && we2_r;
        end
    end

endmodule
