`timescale 1ns/1ps
// ============================================================================
// window_kxk — 流式 KxK (K=3 或 5) 窗口引擎, gaussian/scharr/median/nms 复用
//
// 边界规则 (冻结, 与 golden_model.py 一致): **零填充**
//   - 行: 窗行绝对行号 arow_i = r-K+1+i, <0 或 >=H 的行输出强制 0
//   - 列: 每行移位链起点承接上一行行尾的 HALF 个 0 喂入 (col<0 = 0),
//         行尾 x>=W 再补 HALF 个 0 移位 (col>=W = 0)
//
// 流契约 (上游必须遵守, 见 doc/architecture.md):
//   ① 每行 W 个像素, 行间 ≥ 2*HALF 空拍 (行尾补零 + 起点对齐)
//   ② 帧首像素带 s_sof=1; 帧完到下一帧 sof 之间空拍 ≥ HALF*(W+2*HALF)
//     (供引擎冲刷尾 HALF 行)
//   ③ 引擎不对上游反压; 链内级间 tready 恒 1, 背压在 canny_top 两端
//     由 FIFO 吸收
//
// 行存: NPREV=K-1 个 bank, 每行写入 bank = r%NPREV; 同拍同址读旧值
//   (read-first) 取得最老行。窗行 i (i<K-1) 读 bank (r+i)%NPREV。
//   可证明: arow_i<0 <=> 对应 bank 本帧从未写过, 其 X 会被行零填充挡住。
// ============================================================================
module window_kxk #(
    parameter integer K     = 5,    // 3 或 5
    parameter integer DW    = 8,
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire clk,
    input  wire rst_n,

    // 像素流输入
    input  wire          s_valid,
    input  wire          s_sof,     // 帧首像素 (与 s_valid 同拍)
    input  wire [DW-1:0] s_data,

    // 窗口输出 (晚一拍)
    output reg                    w_valid,
    output reg [K-1:0][K-1:0][DW-1:0] w_pix, // [0][0]=左上, [K-1][K-1]=右下(live)
    output reg [$clog2(IMG_H)-1:0] w_row,    // 中心行号 0..H-1
    output reg [$clog2(IMG_W)-1:0] w_col,    // 中心列号 0..W-1
    output reg                    w_eof      // 本帧最后一个窗口
);

    localparam integer HALF  = (K - 1) / 2;
    localparam integer NPREV = K - 1;
    localparam integer XMAX  = IMG_W + HALF;   // 每行移位数 (含行尾补零)

    localparam integer CB = $clog2(IMG_W);
    localparam integer RB = $clog2(IMG_H);
    localparam integer XB = $clog2(XMAX);

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------
    reg            sof_seen;
    reg [XB-1:0]   x;         // 本行移位计数 0..XMAX-1
    reg [RB+1:0]   r;         // 行计数 0..H+HALF-1 (含冲刷行)
    wire           flushing   = (r >= IMG_H);

    wire start     = s_valid && s_sof && !sof_seen;      // 帧首 (x=0, r=0)
    wire in_real   = (x < IMG_W) && !flushing && sof_seen;
    wire pop       = start || (s_valid && in_real);      // 收一个像素
    // 行尾补零区 (x>=W) 与冲刷行: 无数据也推进零移位
    wire shift_z   = sof_seen && !pop && (x >= IMG_W || flushing) && (x < XMAX);
    wire shift     = pop || shift_z;
    // 行存: 每 bank 独立 1D 数组 (generate) + 连续赋值异步读 -> 分布式 RAM
    //   (2D 数组+组合遍历读会被综合器摊成 FF+巨型多路器, 22k+ LUT 教训)
    wire [CB-1:0] rd_col = x[CB-1:0];
    wire [DW-1:0] feed_bank [0:NPREV-1];
    // start 拍 sof_seen 仍为 0, 单独让数据进 live 链
    wire [DW-1:0] feed_live = (start || in_real) ? s_data : {DW{1'b0}};

    genvar gb;
    generate
        for (gb = 0; gb < NPREV; gb = gb + 1) begin : g_bank
            (* ram_style = "distributed" *) reg [DW-1:0] mem_b [0:IMG_W-1];
            wire bank_wr = start ? (gb == 0) : ((r % NPREV) == gb);
            always @(posedge clk)
                if (pop && x < IMG_W && bank_wr)
                    mem_b[rd_col] <= s_data;
            assign feed_bank[gb] = (x < IMG_W) ? mem_b[rd_col] : {DW{1'b0}};
        end
    endgenerate

    // 移位链: sr[j] (j<NPREV) 由 bank j 馈送; sr[NPREV] 为 live 行
    reg [K-1:0][DW-1:0] sr [0:NPREV];

    // 窗行 i -> bank 映射与绝对行号
    function integer bank_of(input [RB+1:0] row, input integer wi);
        bank_of = (row + wi) % NPREV;
    endfunction

    integer i, k, j;

    // 发射条件: 中心在图内
    wire emit = shift && (x >= HALF) && (r >= HALF);
    wire last_win = (r == IMG_H + HALF - 1) && (x == XMAX - 1);

    // ------------------------------------------------------------------
    // 发射拆拍 (时序收敛): 段1 每拍捕获 bank 选择/零填充/发射标志,
    // 段2 组合只剩 2:1 mux, 消除 bank 译码+分布式RAM读的长路径
    // ------------------------------------------------------------------
    // 段 1: bank_of 译码 + sr/feed 捕获 + 零填充判断 + emit 标志
    reg [DW-1:0] src_reg [0:K-2][0:K-1];     // 各行 i 的移位前 sr 全槽
    reg [DW-1:0] src_feed_reg [0:K-2];       // 各行 i 的 feed_bank
    reg [DW-1:0] src_live_reg [0:K-1];       // live 行 (拍 T 捕获)
    reg [K-2:0]  zero_reg;                   // 各行 i 越界标志
    reg          emit_p, last_p;
    reg [RB+1:0] r_p;
    reg [XB-1:0] x_p;

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ii = 0; ii < K-1; ii = ii + 1) begin
                src_feed_reg[ii] <= 0;
                for (k = 0; k < K; k = k + 1) src_reg[ii][k] <= 0;
            end
            for (k = 0; k < K; k = k + 1) src_live_reg[k] <= 0;
            zero_reg <= 0;
            emit_p <= 0; last_p <= 0; r_p <= 0; x_p <= 0;
        end else begin
            for (ii = 0; ii < K-1; ii = ii + 1) begin
                src_feed_reg[ii] <= feed_bank[bank_of(r, ii)];
                for (k = 0; k < K; k = k + 1)
                    src_reg[ii][k] <= sr[bank_of(r, ii)][k];
                zero_reg[ii] <= (($signed(r) - K + 1 + ii) < 0) ||
                                (($signed(r) - K + 1 + ii) >= $signed(IMG_H));
            end
            for (k = 0; k < K; k = k + 1)
                src_live_reg[k] <= (k == K-1) ? feed_live : sr[NPREV][k+1];
            emit_p <= emit;
            last_p <= last_win;
            r_p <= r;
            x_p <= x;
        end
    end

    // 段 2: 发射 (用段 1 的拍 T 状态, 窗口输出整体晚 1 拍)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_valid <= 0; w_eof <= 0; w_row <= 0; w_col <= 0;
            w_pix <= '0;
        end else begin
            w_valid <= 1'b0;
            w_eof   <= 1'b0;
            if (emit_p) begin
                w_valid <= 1'b1;
                w_col   <= x_p - HALF;
                w_row   <= r_p - HALF;
                w_eof   <= last_p;
                for (i = 0; i < K - 1; i = i + 1) begin
                    for (k = 0; k < K; k = k + 1)
                        w_pix[i][k] <= zero_reg[i] ? {DW{1'b0}}
                                      : (k == K-1 ? src_feed_reg[i]
                                                  : src_reg[i][k+1]);
                end
                for (k = 0; k < K; k = k + 1)
                    w_pix[K-1][k] <= src_live_reg[k];
            end
        end
    end

    // ------------------------------------------------------------------
    // 主时序
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sof_seen <= 1'b0;
            x <= 0; r <= 0;
            for (j = 0; j <= NPREV; j = j + 1)
                for (k = 0; k < K; k = k + 1)
                    sr[j][k] <= 0;
        end else begin
            if (start) begin
                sof_seen <= 1'b1;
                x <= 1;                  // x=0 的移位本拍完成
                r <= 0;
            end

            if (shift) begin
                // 移位链推进 (显式逐槽: 槽 k 保存 K-1-k 拍前的值, 槽 K-1=最新)
                for (j = 0; j < NPREV; j = j + 1) begin
                    for (k = 0; k < K - 1; k = k + 1)
                        sr[j][k] <= sr[j][k+1];
                    sr[j][K-1] <= feed_bank[j];
                end
                for (k = 0; k < K - 1; k = k + 1)
                    sr[NPREV][k] <= sr[NPREV][k+1];
                sr[NPREV][K-1] <= feed_live;

                // 行/帧推进 (start 分支已处理 x=0)
                if (!start) begin
                    if (x == XMAX - 1) begin
                        x <= 0;
                        if (r == IMG_H + HALF - 1)
                            sof_seen <= 1'b0;   // 帧完, 等下一帧 sof
                        else
                            r <= r + 1;
                    end else begin
                        x <= x + 1;
                    end
                end
            end
        end
    end

endmodule
