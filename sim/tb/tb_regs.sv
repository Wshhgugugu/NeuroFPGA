// tb_regs — 控制面全流程 (Phase 6 出口准则):
//   ① 软 CPU 序列: 配阈值 -> 切 mode -> 读 ID (0x5640_0001)
//   ② 寄存器读写回读一致; SNN 计数可读
//   ③ 非法地址: 读 0xDEAD_BEEF, 写置 STATUS.addr_err (可观测错误标志)
`timescale 1ns/1ps
module tb_regs;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    // 软 CPU
    wire m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
    wire [11:0] m_awaddr;
    wire [31:0] m_wdata;
    wire m_arvalid, m_arready, m_rvalid, m_rready;
    wire [11:0] m_araddr;
    wire [31:0] m_rdata;

    vexriscv_wrapper #(.SOFT_CTRL(1)) u_cpu (
        .clk(clk), .rst_n(rst_n),
        .m_awvalid(m_awvalid), .m_awaddr(m_awaddr), .m_awready(m_awready),
        .m_wvalid(m_wvalid), .m_wdata(m_wdata), .m_wready(m_wready),
        .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arvalid(m_arvalid), .m_araddr(m_araddr), .m_arready(m_arready),
        .m_rvalid(m_rvalid), .m_rdata(m_rdata), .m_rready(m_rready));

    wire [1:0] mode_raw; wire [11:0] th_hi, th_lo;
    wire signed [23:0] snn_vth;
    wire snn_act_wr, snn_run_start;
    wire [5:0] snn_act_idx; wire [7:0] snn_act_wdata;
    wire canny_busy, snn_busy, snn_done;
    wire [7:0] snn_cnt [0:15];

    // SNN 计数测试值
    integer k;
    reg [7:0] forced_cnt [0:15];
    initial for (k=0;k<16;k=k+1) forced_cnt[k] = k*3;

    // 手动测试用独立实例 (与软 CPU 实例 u_regs 分离, 避免 force 冲突)
    reg  t_awvalid=0, t_wvalid=0, t_arvalid=0;
    reg  [11:0] t_awaddr=0, t_araddr=0;
    reg  [31:0] t_wdata=0;
    wire t_awready, t_wready, t_bvalid, t_arready, t_rvalid;
    wire [31:0] t_rdata;
    wire [1:0] t_mode; wire [11:0] t_thi, t_thlo;
    wire signed [23:0] t_vth;
    wire t_actwr, t_run; wire [5:0] t_actidx; wire [7:0] t_actwd;

    axi_crossbar_wrap #(.NNEU(16)) u_regs2 (
        .clk(clk), .rst_n(rst_n),
        .s_awvalid(t_awvalid), .s_awaddr(t_awaddr), .s_awready(t_awready),
        .s_wvalid(t_wvalid), .s_wdata(t_wdata), .s_wready(t_wready),
        .s_bvalid(t_bvalid), .s_bready(1'b1),
        .s_arvalid(t_arvalid), .s_araddr(t_araddr), .s_arready(t_arready),
        .s_rvalid(t_rvalid), .s_rdata(t_rdata), .s_rready(1'b1),
        .mode_raw(t_mode), .th_hi(t_thi), .th_lo(t_thlo), .snn_vth(t_vth),
        .snn_act_wr(t_actwr), .snn_act_idx(t_actidx),
        .snn_act_wdata(t_actwd), .snn_run_start(t_run),
        .canny_busy(1'b0), .snn_busy(1'b0), .snn_done(1'b1),
        .snn_cnt(forced_cnt),
        .cfg_done(1'b1), .id_ok(1'b1), .chip_id(16'h5640));

    axi_crossbar_wrap #(.NNEU(16)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_awvalid(m_awvalid), .s_awaddr(m_awaddr), .s_awready(m_awready),
        .s_wvalid(m_wvalid), .s_wdata(m_wdata), .s_wready(m_wready),
        .s_bvalid(m_bvalid), .s_bready(m_bready),
        .s_arvalid(m_arvalid), .s_araddr(m_araddr), .s_arready(m_arready),
        .s_rvalid(m_rvalid), .s_rdata(m_rdata), .s_rready(m_rready),
        .mode_raw(mode_raw), .th_hi(th_hi), .th_lo(th_lo), .snn_vth(snn_vth),
        .snn_act_wr(snn_act_wr), .snn_act_idx(snn_act_idx),
        .snn_act_wdata(snn_act_wdata), .snn_run_start(snn_run_start),
        .canny_busy(1'b0), .snn_busy(1'b0), .snn_done(1'b1),
        .snn_cnt(forced_cnt),
        .cfg_done(1'b1), .id_ok(1'b1), .chip_id(16'h5640));

    integer errors=0;
    integer phase=0;
    reg [31:0] last_rdata;

    // 手动 AXI 读写任务 (软 CPU 跑完后)
    task axi_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            t_awvalid<=1; t_awaddr<=addr; t_wvalid<=1; t_wdata<=data;
            @(posedge clk);
            while (!t_bvalid) @(posedge clk);
            @(posedge clk);
            t_awvalid<=0; t_wvalid<=0;
        end
    endtask

    task axi_read(input [11:0] addr);
        begin
            @(posedge clk);
            t_arvalid<=1; t_araddr<=addr;
            @(posedge clk);
            while (!t_rvalid) @(posedge clk);
            last_rdata = t_rdata;
            @(posedge clk);
            t_arvalid<=0;
        end
    endtask

    initial begin
        repeat(3) @(posedge clk); rst_n=1;
        // ① 等软 CPU 序列走完 (停在 S_DONE)
        wait (u_cpu.g_soft.state == 3'd6);
        repeat(5) @(posedge clk);

        // 软 CPU 结果检查
        if (th_hi !== 12'd600)  begin errors++; $display("[FAIL] th_hi=%0d", th_hi); end
        if (th_lo !== 12'd200)  begin errors++; $display("[FAIL] th_lo=%0d", th_lo); end
        if (mode_raw !== 2'd1)  begin errors++; $display("[FAIL] mode=%0d", mode_raw); end
        if (u_cpu.g_soft.id_val[31:16] !== 16'h5640) begin
            errors++; $display("[FAIL] id=%h", u_cpu.g_soft.id_val); end
        $display("[softcpu] th=%0d/%0d mode=%0d id=%h",
                 th_hi, th_lo, mode_raw, u_cpu.g_soft.id_val);

        // ② 回读 + SNN 计数
        axi_read(12'h008);
        if (last_rdata[11:0] !== 12'd600) begin errors++; $display("[FAIL] rd th_hi=%h", last_rdata); end
        axi_read(12'h030 + 4*5);
        if (last_rdata[7:0] !== 8'd15) begin errors++; $display("[FAIL] snn_cnt5=%h", last_rdata); end

        // ③ 非法地址
        axi_read(12'h7F0);
        if (last_rdata !== 32'hDEAD_BEEF) begin errors++; $display("[FAIL] illegal read=%h", last_rdata); end
        axi_write(12'h7F0, 32'h1);
        axi_read(12'h018);
        if (!last_rdata[8]) begin errors++; $display("[FAIL] addr_err not set: %h", last_rdata); end

        if (errors==0) $display("=== tb_regs: PASS ===");
        else $display("=== tb_regs: FAIL errors=%0d ===", errors);
        $finish;
    end
    initial begin #1_000_000; $display("TIMEOUT state=%0d", u_cpu.g_soft.state); $finish; end
endmodule
