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

    // ---- 行 sort3 拆两拍 (每级 1 个 12-bit 比较器 + 选择) ----
    // Stage 1a: (a>b) 选 lo/hi
    wire [11:0] a0 = wp[0][0][11:0], b0 = wp[0][1][11:0], c0 = wp[0][2][11:0];
    wire [11:0] a1 = wp[1][0][11:0], b1 = wp[1][1][11:0], c1 = wp[1][2][11:0];
    wire [11:0] a2 = wp[2][0][11:0], b2 = wp[2][1][11:0], c2 = wp[2][2][11:0];

    wire sel0 = (a0 > b0), sel1 = (a1 > b1), sel2 = (a2 > b2);
    wire [11:0] lo01_0 = sel0 ? b0 : a0, hi01_0 = sel0 ? a0 : b0;
    wire [11:0] lo01_1 = sel1 ? b1 : a1, hi01_1 = sel1 ? a1 : b1;
    wire [11:0] lo01_2 = sel2 ? b2 : a2, hi01_2 = sel2 ? a2 : b2;

    reg [11:0] lo01_0_r, hi01_0_r, c0_r;
    reg [11:0] lo01_1_r, hi01_1_r, c1_r;
    reg [11:0] lo01_2_r, hi01_2_r, c2_r;
    reg        sv0_r;
    reg [$clog2(IMG_H)-1:0] wr0_r;
    reg [$clog2(IMG_W)-1:0] wc0_r;
    reg        we0_r;
    reg [1:0]  dir0_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lo01_0_r <= 0; hi01_0_r <= 0; c0_r <= 0;
            lo01_1_r <= 0; hi01_1_r <= 0; c1_r <= 0;
            lo01_2_r <= 0; hi01_2_r <= 0; c2_r <= 0;
            sv0_r <= 0; wr0_r <= 0; wc0_r <= 0; we0_r <= 0; dir0_r <= 0;
        end else begin
            lo01_0_r <= lo01_0; hi01_0_r <= hi01_0; c0_r <= c0;
            lo01_1_r <= lo01_1; hi01_1_r <= hi01_1; c1_r <= c1;
            lo01_2_r <= lo01_2; hi01_2_r <= hi01_2; c2_r <= c2;
            sv0_r <= wv; wr0_r <= wr; wc0_r <= wc; we0_r <= we;
            dir0_r <= wp[1][1][13:12];
        end
    end

    // Stage 1b: 定 lo/md/hi (1 级比较 + 打包)
    wire [11:0] md0 = (c0_r < lo01_0_r) ? lo01_0_r : (c0_r > hi01_0_r) ? hi01_0_r : c0_r;
    wire [11:0] lo0 = (c0_r < lo01_0_r) ? c0_r : lo01_0_r;
    wire [11:0] hi0 = (c0_r > hi01_0_r) ? c0_r : hi01_0_r;
    wire [11:0] md1 = (c1_r < lo01_1_r) ? lo01_1_r : (c1_r > hi01_1_r) ? hi01_1_r : c1_r;
    wire [11:0] lo1 = (c1_r < lo01_1_r) ? c1_r : lo01_1_r;
    wire [11:0] hi1 = (c1_r > hi01_1_r) ? c1_r : hi01_1_r;
    wire [11:0] md2 = (c2_r < lo01_2_r) ? lo01_2_r : (c2_r > hi01_2_r) ? hi01_2_r : c2_r;
    wire [11:0] lo2 = (c2_r < lo01_2_r) ? c2_r : lo01_2_r;
    wire [11:0] hi2 = (c2_r > hi01_2_r) ? c2_r : hi01_2_r;

    // Stage 1b → Stage 2 寄存器
    reg [35:0] r0_r, r1_r, r2_r;
    reg        sv1_r;
    reg [$clog2(IMG_H)-1:0] wr_r;
    reg [$clog2(IMG_W)-1:0] wc_r;
    reg        we_r;
    reg [1:0]  dir_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r0_r <= 0; r1_r <= 0; r2_r <= 0;
            sv1_r <= 0; wr_r <= 0; wc_r <= 0; we_r <= 0; dir_r <= 0;
        end else begin
            r0_r <= {lo0, md0, hi0};
            r1_r <= {lo1, md1, hi1};
            r2_r <= {lo2, md2, hi2};
            sv1_r <= sv0_r; wr_r <= wr0_r; wc_r <= wc0_r; we_r <= we0_r;
            dir_r <= dir0_r;
        end
    end

    // Stage 2a: max_of_mins / min_of_maxs / meds 首级比较 (并行, 各 1 级)
    wire [11:0] max_of_mins = (r0_r[35:24] > r1_r[35:24]) ?
                              ((r0_r[35:24] > r2_r[35:24]) ? r0_r[35:24] : r2_r[35:24])
                            : ((r1_r[35:24] > r2_r[35:24]) ? r1_r[35:24] : r2_r[35:24]);

    wire [11:0] min_of_maxs = (r0_r[11:0] < r1_r[11:0]) ?
                              ((r0_r[11:0] < r2_r[11:0]) ? r0_r[11:0] : r2_r[11:0])
                            : ((r1_r[11:0] < r2_r[11:0]) ? r1_r[11:0] : r2_r[11:0]);

    // 行 meds 的 sort3 拆两拍: 首拍 (m0>m1) 选 lo01/hi01 (1 级比较)
    wire [11:0] m0 = r0_r[23:12];
    wire [11:0] m1 = r1_r[23:12];
    wire [11:0] m2 = r2_r[23:12];
    wire        msel = (m0 > m1);
    wire [11:0] lo01 = msel ? m1 : m0;
    wire [11:0] hi01 = msel ? m0 : m1;

    // Stage 2a → Stage 2b 寄存器
    reg [11:0] mom_r, mmo_r;
    reg [11:0] lo01_r, hi01_r, m2_r;
    reg        sv2_r;
    reg [$clog2(IMG_H)-1:0] wr2_r;
    reg [$clog2(IMG_W)-1:0] wc2_r;
    reg        we2_r;
    reg [1:0]  dir2_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mom_r <= 0; mmo_r <= 0;
            lo01_r <= 0; hi01_r <= 0; m2_r <= 0;
            sv2_r <= 0; wr2_r <= 0; wc2_r <= 0; we2_r <= 0; dir2_r <= 0;
        end else begin
            mom_r <= max_of_mins; mmo_r <= min_of_maxs;
            lo01_r <= lo01; hi01_r <= hi01; m2_r <= m2;
            sv2_r <= sv1_r; wr2_r <= wr_r; wc2_r <= wc_r; we2_r <= we_r;
            dir2_r <= dir_r;
        end
    end

    // Stage 2b: 行 meds 中值 (1 级比较)
    wire [11:0] med_row = (m2_r < lo01_r) ? lo01_r :
                          (m2_r > hi01_r) ? hi01_r : m2_r;

    // Stage 2b → Stage 3 寄存器
    reg [11:0] mom2_r, mmo2_r, med_row_r;
    reg        sv3_r;
    reg [$clog2(IMG_H)-1:0] wr3_r;
    reg [$clog2(IMG_W)-1:0] wc3_r;
    reg        we3_r;
    reg [1:0]  dir3_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mom2_r <= 0; mmo2_r <= 0; med_row_r <= 0;
            sv3_r <= 0; wr3_r <= 0; wc3_r <= 0; we3_r <= 0; dir3_r <= 0;
        end else begin
            mom2_r <= mom_r; mmo2_r <= mmo_r; med_row_r <= med_row;
            sv3_r <= sv2_r; wr3_r <= wr2_r; wc3_r <= wc2_r; we3_r <= we2_r;
            dir3_r <= dir2_r;
        end
    end

    // Stage 3a: final sort3 首拍 (mom2 vs mmo2 选 lo01/hi01)
    wire        fsel = (mom2_r > mmo2_r);
    wire [11:0] flo = fsel ? mmo2_r : mom2_r;
    wire [11:0] fhi = fsel ? mom2_r : mmo2_r;

    reg [11:0] flo_r, fhi_r, fmd_r;
    reg        sv4_r;
    reg [$clog2(IMG_H)-1:0] wr4_r;
    reg [$clog2(IMG_W)-1:0] wc4_r;
    reg        we4_r;
    reg [1:0]  dir4_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flo_r <= 0; fhi_r <= 0; fmd_r <= 0;
            sv4_r <= 0; wr4_r <= 0; wc4_r <= 0; we4_r <= 0; dir4_r <= 0;
        end else begin
            flo_r <= flo; fhi_r <= fhi; fmd_r <= med_row_r;
            sv4_r <= sv3_r; wr4_r <= wr3_r; wc4_r <= wc3_r; we4_r <= we3_r;
            dir4_r <= dir3_r;
        end
    end

    // Stage 3b: 定 lo/md/hi (1 级比较) -> med9_r
    wire [11:0] fmd = (fmd_r < flo_r) ? flo_r : (fmd_r > fhi_r) ? fhi_r : fmd_r;
    wire [11:0] flo_f = (fmd_r < flo_r) ? fmd_r : flo_r;
    wire [11:0] fhi_f = (fmd_r > fhi_r) ? fmd_r : fhi_r;

    reg [35:0] med9_r;
    reg        sv5_r;
    reg [$clog2(IMG_H)-1:0] wr5_r;
    reg [$clog2(IMG_W)-1:0] wc5_r;
    reg        we5_r;
    reg [1:0]  dir5_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            med9_r <= 0;
            sv5_r <= 0; wr5_r <= 0; wc5_r <= 0; we5_r <= 0; dir5_r <= 0;
        end else begin
            med9_r <= {flo_f, fmd, fhi_f};
            sv5_r <= sv4_r; wr5_r <= wr4_r; wc5_r <= wc4_r; we5_r <= we4_r;
            dir5_r <= dir4_r;
        end
    end

    // Stage 4: 输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_data <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= sv5_r;
            m_data  <= {dir5_r, med9_r[23:12]};
            m_sof   <= sv5_r && (wr5_r == 0) && (wc5_r == 0);
            m_eol   <= sv5_r && (wc5_r == IMG_W - 1);
            m_eof   <= sv5_r && we5_r;
        end
    end

endmodule
