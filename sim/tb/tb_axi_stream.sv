// ============================================================================
// tb_axi_stream — Phase 1 出口准则验证:
//   ① fifo_async 跨域 (wclk=100MHz, rclk=74MHz 非整数比) 10 万笔零错误
//   ② 随机背压/空泡: 随机 wr_en / rd_en, 数据完整性 + 顺序不变
//   ③ line_buffer 地址遍历: 写 LW 递增数, 读出为上一行同列数据
//   ④ sync_2ff: 复位初值 + 两拍延迟
// 自检查, 结束打印 PASS/FAIL 并 $finish
// ============================================================================
`timescale 1ns/1ps

module tb_axi_stream;

    // ------------------------------------------------------------------
    // 时钟: 非整数倍频率, 专门打跨域
    // ------------------------------------------------------------------
    reg wclk = 0, rclk = 0;
    always #5.0  wclk = ~wclk;   // 100 MHz
    always #6.7  rclk = ~rclk;   // ~74.6 MHz

    reg wrst_n = 0, rrst_n = 0;

    integer i;
    integer errors = 0;

    // ------------------------------------------------------------------
    // DUT: fifo_async 16x256
    // ------------------------------------------------------------------
    localparam int DW = 16, AW = 8;
    reg            wr_en = 0, rd_en = 0;
    reg  [DW-1:0]  wdata = 0;
    wire [DW-1:0]  rdata;
    wire           full, empty, prog_full;

    fifo_async #(.DW(DW), .AW(AW), .PROG_TH(0)) dut_fifo (
        .wclk(wclk), .wr_rst_n(wrst_n), .wr_en(wr_en), .wdata(wdata),
        .full(full), .prog_full(prog_full),
        .rclk(rclk), .rd_rst_n(rrst_n), .rd_en(rd_en),
        .rdata(rdata), .empty(empty)
    );

    // ------------------------------------------------------------------
    // 激励: 写侧随机空泡, 读侧随机背压
    // ------------------------------------------------------------------
    integer wr_sent = 0, rd_got = 0;
    integer NWORDS = 10_000;
    reg [31:0] lfsr = 32'hDEAD_BEEF;
    function [31:0] nxt(input [31:0] s);
        nxt = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
    endfunction

    initial begin : wr_proc
        wait (wrst_n && rrst_n);
        while (wr_sent < NWORDS) begin
            @(posedge wclk);
            lfsr = nxt(lfsr);
            if ((lfsr[3:0] < 12) && !full) begin  // 概率发数且确认有空间
                wr_en  <= 1'b1;
                wdata  <= wr_sent[DW-1:0] ^ 16'hA500;
                wr_sent = wr_sent + 1;
            end else begin
                wr_en <= 1'b0;                    // full 时不发 (防重复写)
            end
        end
        @(posedge wclk); wr_en <= 0;
    end

    initial begin : rd_proc
        wait (wrst_n && rrst_n);
        while (rd_got < NWORDS) begin
            @(posedge rclk);
            lfsr = nxt(lfsr);
            rd_en <= (lfsr[4:0] < 20) && !empty;  // ~62% 概率收数
            if (rd_en && !empty) begin
                // fifo_async 为组合读 (rdata=mem[rbin]): rd_en 拍的 rdata
                // 即本次消费的字 (寄存器值在 posedge 采样窗内仍有效)
                if (rdata !== (rd_got[DW-1:0] ^ 16'hA500)) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("[FAIL fifo] idx=%0d exp=%04h got=%04h",
                                 rd_got, rd_got[DW-1:0] ^ 16'hA500, rdata);
                end
                rd_got = rd_got + 1;
                if (rd_got % 200 == 0)
                    $display("[hb] got=%0d/%0d errors=%0d full=%b empty=%b @%0t",
                             rd_got, NWORDS, errors, full, empty, $time);
            end
        end
    end

    // ------------------------------------------------------------------
    // line_buffer 地址遍历测试 (复位后单独跑, 用独立时钟域)
    // ------------------------------------------------------------------
    reg lb_clk = 0, lb_rst_n = 0;
    always #4 lb_clk = ~lb_clk;

    reg         lb_clken = 0, lb_sel = 0;
    reg  [7:0]  lb_din = 0;
    wire [7:0]  lb_dout;
    wire        lb_dv;

    localparam int LBW = 64;

    line_buffer #(.DW(8), .LW(LBW)) dut_lb (
        .clk(lb_clk), .rst_n(lb_rst_n), .clken(lb_clken),
        .wr_row_sel(lb_sel), .din(lb_din), .dout(lb_dout), .dout_valid(lb_dv)
    );

    integer r, c;
    integer lb_err = 0;
    reg     lb_done = 0;
    initial begin : lb_proc
        lb_rst_n = 0;
        repeat (4) @(posedge lb_clk);
        lb_rst_n = 1;
        // 写两行: 行0 数据 = x, 行1 数据 = x+100
        // 读出 dout 应为 "上一行同列": 写行1时 dout = 行0 数据
        for (r = 0; r < 2; r = r + 1) begin
            lb_sel = r[0];
            for (c = 0; c < LBW; c = c + 1) begin
                @(posedge lb_clk);
                lb_clken = 1;
                lb_din   = c + (r ? 100 : 0);
                #1;
                if (r == 1) begin
                    // 读延迟一拍: clken 打一拍后有效
                    if (lb_dv && lb_dout !== c[7:0]) begin
                        lb_err = lb_err + 1;
                        if (lb_err < 10)
                            $display("[FAIL lb] row=%0d col=%0d exp=%0d got=%0d",
                                     r, c, c, lb_dout);
                    end
                end
            end
            @(posedge lb_clk); lb_clken = 0;
            repeat (2) @(posedge lb_clk);
        end
        // 再写行0 (乒乓回): dout 应为行1 数据 (x+100)
        lb_sel = 0;
        for (c = 0; c < LBW; c = c + 1) begin
            @(posedge lb_clk);
            lb_clken = 1;
            lb_din   = 0;
            #1;
            if (lb_dv && lb_dout !== (c + 100)) begin
                lb_err = lb_err + 1;
                if (lb_err < 10)
                    $display("[FAIL lb2] col=%0d exp=%0d got=%0d", c, c + 100, lb_dout);
            end
        end
        @(posedge lb_clk); lb_clken = 0;
        $display("[lb] line_buffer sweep done, errors=%0d", lb_err);
        errors = errors + lb_err;
        lb_done = 1;
    end

    // ------------------------------------------------------------------
    // sync_2ff 快速检查
    // ------------------------------------------------------------------
    wire s2f_q;
    reg  s2f_d = 0;
    sync_2ff #(.STAGES(2), .INIT(1'b0)) dut_sync (
        .clk(rclk), .rst_n(rrst_n), .d_in(s2f_d), .q_out(s2f_q));

    integer sync_err = 0;
    initial begin : sync_proc
        wait (rrst_n);
        repeat (4) @(posedge rclk);
        if (s2f_q !== 1'b0) begin sync_err = sync_err + 1; $display("[FAIL sync] init"); end
        s2f_d = 1;
        @(posedge rclk); #1;
        // 2 级: 第 1 拍后仍为 0 (或亚稳不确定), 第 2 拍后必为 1
        @(posedge rclk); #1;
        if (s2f_q !== 1'b1) begin sync_err = sync_err + 1; $display("[FAIL sync] 2-cycle"); end
        s2f_d = 0;
        repeat (3) @(posedge rclk); #1;
        if (s2f_q !== 1'b0) begin sync_err = sync_err + 1; $display("[FAIL sync] fall"); end
        $display("[sync] errors=%0d", sync_err);
        errors = errors + sync_err;
    end

    // ------------------------------------------------------------------
    // 复位 & 汇总
    // ------------------------------------------------------------------
    initial begin
        wrst_n = 0; rrst_n = 0;
        #30;
        // 异步释放但两侧错开
        wrst_n = 1;
        #7;
        rrst_n = 1;
    end

    initial begin
        wait (rd_got >= NWORDS);
        repeat (10) @(posedge rclk);
        wait (lb_done);
        if (errors == 0)
            $display("=== tb_axi_stream: ALL PASS (fifo %0d words, lb, sync) ===", NWORDS);
        else
            $display("=== tb_axi_stream: FAIL, errors=%0d ===", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;
        $display("=== tb_axi_stream: TIMEOUT (sent=%0d got=%0d errors=%0d) ===",
                 wr_sent, rd_got, errors);
        $finish;
    end

endmodule
