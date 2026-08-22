// tb_cpu — mcu8 + axi_mcu_bridge + axi_crossbar_wrap 闭环验证
//   场景: snn_cnt[0]=200, snn_cnt[1]=100 → activity=150 > 96
//         → 每轮 TH_HI += 16 (592→608→624...)
//   检查: ① ID 读取通过 (未 HALT)  ② mode/th_lo 正确写入
//         ③ TH_HI 逐轮上升  ④ snn_run_start 周期脉冲
`timescale 1ns/1ps
module tb_cpu;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                  // 100MHz

    // ---------------- DUT 链 ----------------
    wire [7:0] port_addr, port_out, port_in;
    wire       port_wr, port_rd;
    wire       halted, active;

    mcu8 #(.PROG("mem/prog_adaptive.hex")) u_cpu (
        .clk(clk), .rst_n(rst_n),
        .port_addr(port_addr), .port_out(port_out), .port_in(port_in),
        .port_wr(port_wr), .port_rd(port_rd),
        .halted(halted), .active(active));

    // AXI 主 (桥) → AXI 从 (寄存器堆)
    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire [11:0] awaddr;
    wire [31:0] wdata;
    wire        arvalid, arready, rvalid, rready;
    wire [11:0] araddr;
    wire [31:0] rdata;

    reg id_ok = 1, cfg_done = 1, snn_done = 1, snn_busy = 0, canny_busy = 0;

    axi_mcu_bridge u_bridge (
        .clk(clk), .rst_n(rst_n),
        .port_addr(port_addr), .port_out(port_out), .port_wr(port_wr),
        .port_in(port_in),
        .m_awvalid(awvalid), .m_awaddr(awaddr), .m_awready(awready),
        .m_wvalid(wvalid), .m_wdata(wdata), .m_wready(wready),
        .m_bvalid(bvalid), .m_bready(bready),
        .m_arvalid(arvalid), .m_araddr(araddr), .m_arready(arready),
        .m_rvalid(rvalid), .m_rdata(rdata), .m_rready(rready),
        .id_ok(id_ok), .cfg_done(cfg_done), .snn_done(snn_done),
        .snn_busy(snn_busy), .canny_busy(canny_busy));

    // 寄存器堆 (被测从机)
    wire [1:0]  mode_raw;
    wire [11:0] th_hi, th_lo;
    wire signed [23:0] snn_vth;
    wire snn_act_wr, snn_run_start;
    wire [5:0]  snn_act_idx;
    wire [7:0]  snn_act_wdata;
    reg  [7:0]  snn_cnt [0:15];
    integer i;
    initial for (i = 0; i < 16; i = i + 1) snn_cnt[i] = 0;
    initial begin snn_cnt[0] = 200; snn_cnt[1] = 100; end   // activity=150

    axi_crossbar_wrap #(.NNEU(16)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_awvalid(awvalid), .s_awaddr(awaddr), .s_awready(awready),
        .s_wvalid(wvalid), .s_wdata(wdata), .s_wready(wready),
        .s_bvalid(bvalid), .s_bready(bready),
        .s_arvalid(arvalid), .s_araddr(araddr), .s_arready(arready),
        .s_rvalid(rvalid), .s_rdata(rdata), .s_rready(rready),
        .mode_raw(mode_raw), .th_hi(th_hi), .th_lo(th_lo), .snn_vth(snn_vth),
        .snn_act_wr(snn_act_wr), .snn_act_idx(snn_act_idx),
        .snn_act_wdata(snn_act_wdata), .snn_run_start(snn_run_start),
        .canny_busy(canny_busy), .snn_busy(snn_busy), .snn_done(snn_done),
        .snn_cnt(snn_cnt), .cfg_done(cfg_done), .id_ok(id_ok),
        .chip_id(16'h5640));

    // ---------------- 检查 ----------------
    integer errors = 0;
    integer run_pulses = 0;
    integer th_samples = 0;
    integer last_th = 0;

    always @(posedge clk) if (snn_run_start) run_pulses = run_pulses + 1;

    // 执行轨迹 (调试用: WAIT/JNZ 全打印 + 延时窗口)
    always @(posedge clk) if (u_cpu.state == 2'd2 && (
                u_cpu.ir[17:12] == 6'h18 || u_cpu.ir[17:12] == 6'h12 ||
                (u_cpu.pc >= 99 && u_cpu.pc <= 105)))
        $display("t=%0t EXEC pc=%0d ir=%h r0=%0d",
                 $time, u_cpu.pc, u_cpu.ir, u_cpu.regs[0]);

    // 跟踪 TH_HI 变化轨迹 (每变化采样一次)
    reg [11:0] th_q = 0;
    always @(posedge clk) begin
        if (th_hi != th_q) begin
            th_q = th_hi;
            th_samples = th_samples + 1;
            $display("[%0t] TH_HI = %0d (第%0d次)", $time, th_hi, th_samples);
        end
    end

    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        // 等程序跑完 boot + 至少 2 轮自适应 (每轮 ~4.4ms: 延时 8×51k 拍)
        wait (th_samples >= 4);
        repeat (100) @(posedge clk);

        // 检查 1: 未停机 (ID 校验通过)
        if (halted) begin errors = errors + 1; $display("[FAIL] CPU HALT (ID 校验失败?)"); end
        // 检查 2: mode/th_lo
        if (mode_raw !== 2'd1) begin errors = errors + 1; $display("[FAIL] mode=%0d (期望 1)", mode_raw); end
        if (th_lo  !== 12'd200) begin errors = errors + 1; $display("[FAIL] th_lo=%0d (期望 200)", th_lo); end
        // 检查 3: TH_HI 逐轮 +16 (592 → 608 → 624)
        if (th_hi < 12'd624) begin errors = errors + 1;
            $display("[FAIL] th_hi=%0d 未按 16 递增 (期望 >=624)", th_hi); end
        // 检查 4: SNN 启动脉冲已发
        if (run_pulses < 2) begin errors = errors + 1;
            $display("[FAIL] snn_run_start 仅 %0d 次", run_pulses); end

        if (errors == 0)
            $display("=== tb_cpu: PASS (自适应闭环: TH_HI=%0d, run×%0d) ===",
                     th_hi, run_pulses);
        else
            $display("=== tb_cpu: FAIL errors=%0d ===", errors);
        $finish;
    end

    initial begin
        #50_000_000;   // 50ms 超时
        $display("=== tb_cpu: TIMEOUT halted=%b th=%0d samples=%0d ===",
                 halted, th_hi, th_samples);
        $finish;
    end
endmodule
