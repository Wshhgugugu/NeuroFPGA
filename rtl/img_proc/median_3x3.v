`timescale 1ns/1ps
// ============================================================================
// median_3x3 — 9 值中值滤波 (作用于幅值, dir 随流透传)
//
//   恒等式 (已穷举验证): 3x3 中值
//     = median( max(行min), min(行max), median(行med) )
//   3 行各自 sort3 (各 3 比较器) + 三个 3 值归并 = 19 比较器
//   输入 {dir, mag} 14-bit, 输出 {dir, median(mag)} 14-bit
// ============================================================================
module median_3x3 #(
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
    output reg  [13:0]   m_data,
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

    // sort3: 输出 {min, med, max}
    function [35:0] sort3(input [11:0] a, input [11:0] b, input [11:0] c);
        reg [11:0] lo, hi, md;
        begin
            if (a > b) begin lo = b; hi = a; end else begin lo = a; hi = b; end
            if (c < lo) begin md = lo; lo = c; end
            else if (c > hi) begin md = hi; hi = c; end
            else md = c;
            sort3 = {lo, md, hi};
        end
    endfunction

    // sort3 打包: {lo, md, hi} -> lo=[35:24], md=[23:12], hi=[11:0]
    wire [35:0] r0 = sort3(wp[0][0][11:0], wp[0][1][11:0], wp[0][2][11:0]);
    wire [35:0] r1 = sort3(wp[1][0][11:0], wp[1][1][11:0], wp[1][2][11:0]);
    wire [35:0] r2 = sort3(wp[2][0][11:0], wp[2][1][11:0], wp[2][2][11:0]);

    wire [11:0] max_of_mins = (r0[35:24] > r1[35:24]) ?
                              ((r0[35:24] > r2[35:24]) ? r0[35:24] : r2[35:24])
                            : ((r1[35:24] > r2[35:24]) ? r1[35:24] : r2[35:24]);

    wire [11:0] min_of_maxs = (r0[11:0] < r1[11:0]) ?
                              ((r0[11:0] < r2[11:0]) ? r0[11:0] : r2[11:0])
                            : ((r1[11:0] < r2[11:0]) ? r1[11:0] : r2[11:0]);

    wire [35:0] mm = sort3(r0[23:12], r1[23:12], r2[23:12]); // 行med 的中值

    wire [35:0] med9 = sort3(max_of_mins, min_of_maxs, mm[23:12]);
    wire [11:0] median = med9[23:12];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= wv;
            m_data  <= {wp[1][1][13:12], median};
            m_sof   <= wv && (wr == 0) && (wc == 0);
            m_eol   <= wv && (wc == IMG_W - 1);
            m_eof   <= wv && we;
        end
    end

endmodule
