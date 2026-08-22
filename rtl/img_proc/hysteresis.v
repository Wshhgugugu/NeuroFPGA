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

    // 帧图: 单写口 (相位复用) + 单同步读口 (rd_addr) — 规范形式保证 BRAM 推断
    (* ram_style = "block" *) reg strong_mem [0:N-1];
    (* ram_style = "block" *) reg weak_mem   [0:N-1];

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
    reg  rd_last_d, rd_eol_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rd_last_d <= 0; rd_eol_d <= 0; end
        else begin
            rd_last_d <= rd_last;
            rd_eol_d  <= rd_pix && (rd_x == IMG_W-1);
        end
    end

    // ------------------------------------------------------------------
    // 窗口引擎 (3x3, 流字 = {weak, strong})
    // ------------------------------------------------------------------
    wire                     wv;
    wire [2:0][2:0][1:0]     wp;
    wire [$clog2(IMG_H)-1:0] wr_row;
    wire [$clog2(IMG_W)-1:0] wr_col;
    wire                     we;

    // 窗口引擎输入: 读出打一拍 (rd_word_q 与 rd_pix_r 对齐), 再打一拍
    // 切断 BRAM CLK->Q 到窗口分布式 RAM 写口的组合路径 (时序收敛)
    reg rd_pix_r, rd_sof_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rd_pix_r <= 0; rd_sof_r <= 0; end
        else begin
            rd_pix_r <= rd_pix;
            rd_sof_r <= rd_sof && rd_pix;
        end
    end

    reg [1:0] rd_word_q;   // 帧图同步读出 (供窗口引擎与输出段)
    // 注: 不可加 keep/dont_touch — 两者都会扰动 Vivado 对 strong/weak_mem 的
    //     BRAM 推断, 触发 LUTRAM 爆炸 (41k~82k LUTRAM, 超器件 2~4 倍)
    reg       m_edge_d;    // m_edge 前置打拍 (BRAM 读出口路径收敛)
    reg       m_valid_d, m_sof_d, m_eol_d, m_eof_d;   // 输出级寄存器

    // 输出级: 与 m_edge_d 对齐 (整帧输出统一晚 1 拍)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_edge <= 0; m_sof <= 0; m_eol <= 0; m_eof <= 0;
        end else begin
            m_valid <= m_valid_d;
            m_edge  <= m_edge_d;
            m_sof   <= m_sof_d;
            m_eol   <= m_eol_d;
            m_eof   <= m_eof_d;
        end
    end

    reg [1:0] win_data_r;
    reg       win_val_r, win_sof_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin win_data_r <= 0; win_val_r <= 0; win_sof_r <= 0; end
        else begin
            win_data_r <= rd_word_q;
            win_val_r  <= rd_pix_r;
            win_sof_r  <= rd_sof_r && rd_pix_r;
        end
    end

    window_kxk #(.K(3), .DW(2), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_win (
        .clk(clk), .rst_n(rst_n),
        .s_valid(win_val_r), .s_sof(win_sof_r), .s_data(win_data_r),
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

    wire       st_we = (phase == PH_IDLE  && s_valid && s_sof) ||
                       (phase == PH_CAPT  && s_valid) ||
                       (phase == PH_PASS  && promote);
    wire [AB-1:0] st_wa = (phase == PH_IDLE)  ? {AB{1'b0}} :
                           (phase == PH_CAPT) ? cap_addr : em_addr;
    wire       st_wd = (phase == PH_PASS) ? 1'b1 : (s_class == 2'd2);

    wire       wk_we = (phase == PH_IDLE && s_valid && s_sof) ||
                       (phase == PH_CAPT && s_valid);
    wire [AB-1:0] wk_wa = (phase == PH_IDLE) ? {AB{1'b0}} : cap_addr;
    wire       wk_wd = (s_class == 2'd1);

    always @(posedge clk) begin
        if (st_we) strong_mem[st_wa] <= st_wd;
        if (wk_we) weak_mem[wk_wa]   <= wk_wd;
        rd_word_q  <= {weak_mem[rd_addr], strong_mem[rd_addr]};
    end

    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= PH_IDLE; changed <= 1'b0; pass_cnt <= 0; cap_addr <= 0;
            rd_run <= 0; rd_addr <= 0; rd_x <= 0; rd_sof <= 0; em_addr <= 0;
            m_valid_d <= 0; m_sof_d <= 0; m_eol_d <= 0; m_eof_d <= 0;
        end else begin
            m_valid_d <= 1'b0;

            case (phase)
                // ------------------------------------------------------
                PH_IDLE: if (s_valid && s_sof) begin
                    // 帧首像素经端口 mux 入库 (st_we/wk_we 已含本拍)
                    cap_addr <= 1;
                    phase <= PH_CAPT;
                end

                // ------------------------------------------------------
                PH_CAPT: if (s_valid) begin
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

                    if (promote)
                        changed <= 1'b1;   // 写入由端口 mux (st_we) 完成
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
                    // 发射流水 (读推进保持 rd_pix 原节奏, 数据打一拍对齐)
                    // 输出统一进输出级 (m_*_d), BRAM 读出口路径拆成
                    // BRAM->rd_word_q->m_edge_d->m_edge 三段
                    if (rd_pix_r) begin
                        m_valid_d <= 1'b1;
                        m_edge_d  <= rd_word_q[0];   // 与 rd_pix_r 同拍 = 上拍地址数据
                        m_sof_d   <= rd_sof_r;
                        m_eol_d   <= rd_eol_d;
                        m_eof_d   <= rd_last_d;
                    end
                    // 读图推进 (与 PASS 段完全同构)
                    if (rd_run) begin
                        if (rd_pix) begin
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
