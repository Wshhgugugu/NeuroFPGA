`timescale 1ns/1ps
// ============================================================================
// hysteresis — 迟滞连接 (计划书 D7: 帧存 BRAM + 帧内迭代, 正确性优先)
//
//   CAPTURE: 双阈值分类流写 weak/strong 两张 1-bit 帧图
//   PASS(k): 读图流过 3x3 窗口引擎 (发射滞后读 2 行 -> 原地写安全),
//            weak 中心且 3x3 邻域含 strong 且自身非 strong -> 晋升
//            记 changed; 一趟毕: changed 且未满 MAX_PASS -> 再一趟
//   OUTPUT : 读 strong 图输出 edge 流 (sof/eol/eof + 行间隙契约)
//
//   与 golden_model.py 一致性: 两者都迭代至同一不动点 (strong 在 weak
//   连通域上的闭包), 趟数差异不影响最终图, 比较按最终图逐位。
//
//   流控: busy 期间不接受新帧 (上层整帧丢弃)。
// ============================================================================
module hysteresis #(
    parameter integer IMG_W    = 640,
    parameter integer IMG_H    = 480,
    parameter integer MAX_PASS = 64
)(
    input  wire clk,
    input  wire rst_n,

    // 分类图输入 (来自 double_threshold)
    input  wire          s_valid,
    input  wire          s_sof,
    input  wire [1:0]    s_class,
    input  wire          s_eol,
    input  wire          s_eof,

    // edge 输出流
    output reg           m_valid,
    output reg           m_edge,    // 1-bit edge map
    output reg           m_sof,
    output reg           m_eol,
    output reg           m_eof,

    output wire          busy       // 忙 (不接受新帧)
);

    localparam integer N  = IMG_W * IMG_H;
    localparam integer AB = $clog2(N);
    localparam integer CB = $clog2(IMG_W);

    // 帧图 (SDP: 独立写口/读口)
    reg strong_mem [0:N-1];
    reg weak_mem   [0:N-1];

    // 状态
    localparam [2:0] PH_IDLE   = 3'd0;
    localparam [2:0] PH_CAPT   = 3'd1;
    localparam [2:0] PH_PASS   = 3'd2;   // 读图 + 窗口 + 晋升
    localparam [2:0] PH_CHECK  = 3'd3;   // 帧冲刷完, changed 已定型
    localparam [2:0] PH_OUTPUT = 3'd4;

    reg [2:0]    phase;
    reg          changed;
    reg [7:0]    pass_cnt;
    reg [AB-1:0] cap_addr;

    assign busy = (phase != PH_IDLE);

    // ------------------------------------------------------------------
    // 读图器 (PASS / OUTPUT 共用): 每行 W 有效 + 2 空拍 (rd_x = W..W+1)
    // ------------------------------------------------------------------
    reg          rd_run;
    reg [AB-1:0] rd_addr;
    reg [CB+1:0] rd_x;
    reg          rd_sof;

    wire rd_pix  = rd_run && (rd_x < IMG_W);          // 本拍有像素
    wire rd_last = rd_pix && (rd_addr == N-1);

    // ------------------------------------------------------------------
    // 窗口引擎 (3x3, 流字 = {weak, strong})
    // ------------------------------------------------------------------
    wire                     wv;
    wire [2:0][2:0][1:0]     wp;
    wire [$clog2(IMG_H)-1:0] wr_row;
    wire [$clog2(IMG_W)-1:0] wr_col;
    wire                     we;

    wire [1:0] rd_word = {weak_mem[rd_addr], strong_mem[rd_addr]};

    window_kxk #(.K(3), .DW(2), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_win (
        .clk(clk), .rst_n(rst_n),
        .s_valid(rd_pix), .s_sof(rd_sof && rd_pix), .s_data(rd_word),
        .w_valid(wv), .w_pix(wp), .w_row(wr_row), .w_col(wr_col), .w_eof(we)
    );

    wire weak_c     = wp[1][1][1];
    wire strong_c   = wp[1][1][0];
    wire any_strong = |{wp[0][0][0], wp[0][1][0], wp[0][2][0],
                        wp[1][0][0],               wp[1][2][0],
                        wp[2][0][0], wp[2][1][0], wp[2][2][0]};
    wire promote    = wv && weak_c && !strong_c && any_strong;

    // 晋升地址 = 发射序号 (行主序)
    reg [AB-1:0] em_addr;

    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE; changed <= 1'b0; pass_cnt <= 0; cap_addr <= 0;
            rd_run <= 0; rd_addr <= 0; rd_x <= 0; rd_sof <= 0; em_addr <= 0;
            m_valid <= 0; m_edge <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= 1'b0;

            case (phase)
                // ------------------------------------------------------
                PH_IDLE: if (s_valid && s_sof) begin
                    // 帧首像素当拍入库 (状态切换是 NBA, 本拍不进 CAPT 分支)
                    strong_mem[0] <= (s_class == 2'd2);
                    weak_mem[0]   <= (s_class == 2'd1);
                    cap_addr <= 1;
                    phase <= PH_CAPT;
                end

                // ------------------------------------------------------
                PH_CAPT: if (s_valid) begin
                    strong_mem[cap_addr] <= (s_class == 2'd2);
                    weak_mem[cap_addr]   <= (s_class == 2'd1);
                    if (cap_addr == N-1 || s_eof) begin
                        phase <= PH_PASS; changed <= 1'b0; pass_cnt <= 0;
                        rd_run <= 1'b1; rd_addr <= 0; rd_x <= 0;
                        rd_sof <= 1'b1; em_addr <= 0;
                    end else
                        cap_addr <= cap_addr + 1'b1;
                end

                // ------------------------------------------------------
                PH_PASS: begin
                    if (rd_run) begin
                        if (rd_pix) begin
                            if (rd_x == IMG_W-1) rd_x <= IMG_W;  // 进 2 空拍
                            else                 rd_x <= rd_x + 1'b1;
                            rd_addr <= rd_addr + 1'b1;
                            rd_sof  <= 1'b0;
                            if (rd_last) rd_run <= 1'b0;
                        end else if (rd_x == IMG_W+1) begin
                            rd_x <= 0;                          // 空拍结束
                        end else begin
                            rd_x <= rd_x + 1'b1;                // 空拍中
                        end
                    end

                    if (promote) begin
                        strong_mem[em_addr] <= 1'b1;
                        changed <= 1'b1;
                    end
                    if (wv) em_addr <= em_addr + 1'b1;

                    // 读喂完 + 引擎冲刷完 (we) -> 检查
                    if (!rd_run && we) phase <= PH_CHECK;
                end

                // ------------------------------------------------------
                PH_CHECK: begin // settled changed (promote 均已入账)
                    if (changed && pass_cnt != MAX_PASS-1) begin
                        phase <= PH_PASS; changed <= 1'b0;
                        pass_cnt <= pass_cnt + 1'b1;
                        rd_run <= 1'b1; rd_addr <= 0; rd_x <= 0;
                        rd_sof <= 1'b1; em_addr <= 0;
                    end else begin
                        phase <= PH_OUTPUT;
                        rd_run <= 1'b1; rd_addr <= 0; rd_x <= 0;
                        rd_sof <= 1'b1;
                    end
                end

                // ------------------------------------------------------
                PH_OUTPUT: begin
                    if (rd_run) begin
                        if (rd_pix) begin
                            m_valid <= 1'b1;
                            m_edge  <= strong_mem[rd_addr];
                            m_sof   <= rd_sof;
                            m_eol   <= (rd_x == IMG_W-1);
                            m_eof   <= rd_last;
                            if (rd_x == IMG_W-1) rd_x <= IMG_W;  // 进 2 空拍
                            else                 rd_x <= rd_x + 1'b1;
                            rd_addr <= rd_addr + 1'b1;
                            rd_sof  <= 1'b0;
                            if (rd_last) rd_run <= 1'b0;
                        end else if (rd_x == IMG_W+1) begin
                            rd_x <= 0;
                        end else begin
                            rd_x <= rd_x + 1'b1;
                        end
                    end else begin
                        phase <= PH_IDLE;
                    end
                end

                default: phase <= PH_IDLE;
            endcase
        end
    end

endmodule
