`timescale 1ns/1ps
// ============================================================================
// snn_top — 速率编码 SNN 加速器 (计划 D8, 冻结规范见 doc/architecture.md)
//   输入: 64 通道 8-bit 活动 (act 写口, 帧级)
//   每帧: TSTEPS 个时间步; 每步: 编码器出尖峰 -> 1024 拍单 MAC 时分累加
//         (16 神经元 x 64 通道, 每神经元 64 拍) -> 各神经元积分一步
//   输出: 每神经元尖峰计数 spike_cnt[0..15] + done 脉冲
//
//   MAC 时序: 地址 cnt 于周期 C 送出, w 于 C+1 有效;
//   神经元 n 的最后一项在 cnt=(n+1)*64 的第一拍并入 i_raw 并触发 step。
// ============================================================================
module snn_top #(
    parameter integer NIN    = 64,
    parameter integer NNEU   = 16,
    parameter integer TSTEPS = 64
)(
    input  wire clk,
    input  wire rst_n,

    // 活动写入口 (寄存器堆/AXI 侧驱动)
    input  wire        act_wr,
    input  wire [5:0]  act_idx,
    input  wire [7:0]  act_wdata,
    input  wire        run_start,     // 单脉冲: 开跑 (act 应已写好)

    input  wire signed [23:0] vth,    // Q8.16

    output reg         busy,
    output reg         done,          // 单脉冲
    output reg  [7:0]  spike_cnt [0:NNEU-1]
);

    // ---- 活动寄存器 ----
    reg [7:0] act [0:NIN-1];
    integer ai;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ai = 0; ai < NIN; ai = ai + 1) act[ai] <= 0;
        end else if (act_wr) begin
            act[act_idx] <= act_wdata;
        end
    end

    // ---- 编码器 ----
    wire [NIN-1:0] s_bus;
    wire [7:0] t_cnt;
    reg   step_enc;

    spike_encoder #(.NIN(NIN), .TSTEPS(TSTEPS)) u_enc (
        .clk(clk), .rst_n(rst_n),
        .step(step_enc), .act(act),
        .s_bus(s_bus), .t_cnt(t_cnt));

    // ---- 突触 BRAM + MAC ----
    wire signed [7:0] w_rd;
    reg  mac_rd_en;
    wire [3:0] cur_n;                  // MAC 地址 = 步内计数 cnt (n*64+j)
    wire [5:0] cur_j;

    synapse_array #(.NNEU(NNEU), .NIN(NIN)) u_syn (
        .clk(clk), .rd_en(mac_rd_en), .cur_n(cur_n), .cur_j(cur_j), .w(w_rd));

    // ---- 神经元阵列 ----
    wire [NNEU-1:0] neu_spike;
    reg  signed [15:0] i_raw_bcast;
    reg  [NNEU-1:0] neu_step;

    genvar g;
    generate
        for (g = 0; g < NNEU; g = g + 1) begin : g_neu
            lif_neuron #(.LEAK_SHIFT(4), .REFRA(2)) u_lif (
                .clk(clk), .rst_n(rst_n),
                .step(neu_step[g]), .i_raw(i_raw_bcast), .vth(vth),
                .spike(neu_spike[g]), .v(), .ovf());
        end
    endgenerate

    // step 流水延迟 3 拍对齐 LIF 3 级流水 (spike 在 step+3 拍有效: step→A→B→C 提交)
    reg [NNEU-1:0] neu_step_d1, neu_step_d2, neu_step_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            neu_step_d1 <= 0; neu_step_d2 <= 0; neu_step_d <= 0;
        end else begin
            neu_step_d1 <= neu_step;
            neu_step_d2 <= neu_step_d1;
            neu_step_d  <= neu_step_d2;
        end
    end

    // 尖峰计数 (spike 在 step 后一拍有效)
    integer ni;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ni = 0; ni < NNEU; ni = ni + 1) spike_cnt[ni] <= 0;
        end else if (run_start) begin
            for (ni = 0; ni < NNEU; ni = ni + 1) spike_cnt[ni] <= 0;
        end else begin
            for (ni = 0; ni < NNEU; ni = ni + 1)
                if (neu_step_d[ni] && neu_spike[ni])
                    spike_cnt[ni] <= spike_cnt[ni] + 1'b1;
        end
    end

    // ---- 控制 FSM ----
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;
    localparam [1:0] S_TAIL = 2'd2;   // 收神经元 15
    localparam [1:0] S_DONE = 2'd3;

    reg [1:0] state;
    reg [9:0] cnt;
    reg [7:0] t_step;
    reg signed [15:0] acc;
    reg [5:0] j_d;

    assign cur_n = cnt[9:6];
    assign cur_j = cnt[5:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 0; done <= 0;
            mac_rd_en <= 0; cnt <= 0; t_step <= 0;
            step_enc <= 0; neu_step <= 0;
            acc <= 0; j_d <= 0; i_raw_bcast <= 0;
        end else begin
            done <= 0;
            step_enc <= 0;
            neu_step <= 0;
            mac_rd_en <= 0;

            case (state)
                S_IDLE: if (run_start) begin
                    busy <= 1;
                    cnt <= 0; t_step <= 0;
                    mac_rd_en <= 1'b1;   // 预读: cnt=0 地址当拍送出
                    state <= S_RUN;
                end

                S_RUN: begin
                    if (cnt == 0) step_enc <= 1;   // 本步尖峰 (下拍生效)
                    mac_rd_en <= 1;

                    // MAC 累加: w_rd/j_d 为上一拍地址的权/通道
                    if (cnt != 0)
                        acc <= acc + (w_rd * $signed({1'b0, s_bus[j_d]}));
                    j_d <= cur_j;

                    // 神经元边界: cnt 为 (n+1)*64 的第一拍 -> 收神经元 n
                    if (cnt[5:0] == 6'd0 && cnt != 0) begin
                        i_raw_bcast <= acc + (w_rd * $signed({1'b0, s_bus[j_d]}));
                        neu_step[cur_n - 1'b1] <= 1'b1;
                        acc <= 0;
                    end

                    if (cnt == NNEU*NIN - 1) begin
                        cnt <= 0;
                        state <= S_TAIL;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_TAIL: begin
                    // w_rd/j_d = 神经元 15 的最后一项
                    i_raw_bcast <= acc + (w_rd * $signed({1'b0, s_bus[j_d]}));
                    neu_step[NNEU-1] <= 1'b1;
                    acc <= 0;
                    if (t_step == TSTEPS - 1) begin
                        state <= S_DONE;
                    end else begin
                        t_step <= t_step + 1'b1;
                        state <= S_RUN;
                    end
                end

                S_DONE: begin
                    busy <= 0;
                    done <= 1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
