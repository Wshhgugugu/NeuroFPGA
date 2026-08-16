// tb_lif — snn_top 全链 vs golden_model_snn.py (尖峰计数逐位一致)
//   另含 lif_neuron 单元轨迹探查 (前 40 步 v 值打印, 供人工比对)
`timescale 1ns/1ps
module tb_lif;
    localparam integer NIN=64, NNEU=16, T=64;
    localparam signed [23:0] VTH = 24'sd8 << 16;

    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    reg act_wr=0, run_start=0;
    reg [5:0] act_idx=0;
    reg [7:0] act_wdata=0;
    wire busy, done;
    wire [7:0] spike_cnt [0:NNEU-1];

    snn_top #(.NIN(NIN), .NNEU(NNEU), .TSTEPS(T)) dut (
        .clk(clk), .rst_n(rst_n),
        .act_wr(act_wr), .act_idx(act_idx), .act_wdata(act_wdata),
        .run_start(run_start), .vth(VTH),
        .busy(busy), .done(done), .spike_cnt(spike_cnt));

    reg [7:0] act [0:NIN-1];
    reg [7:0] gold [0:NNEU-1];
    integer i, errors=0;

    initial $readmemh("sim/stimulus/act_64.hex", act);
    initial $readmemh("out/golden_snn.hex", gold);

    initial begin
        repeat(3) @(posedge clk); rst_n=1;
        repeat(2) @(posedge clk);
        // 写活动
        for (i=0;i<NIN;i=i+1) begin
            @(posedge clk);
            act_wr<=1; act_idx<=i[5:0]; act_wdata<=act[i];
        end
        @(posedge clk); act_wr<=0;
        repeat(2) @(posedge clk);
        @(posedge clk); run_start<=1;
        @(posedge clk); run_start<=0;
    end

    // 探针
    integer nstep = 0;
    integer trc2 = 0;
    always @(posedge clk) if (rst_n && trc2 >= 60 && trc2 < 76) begin
        $display("cyc%0d state=%0d cnt=%0d bnd=%b w=%0d j_d=%0d s0=%b acc=%0d",
                 trc2, dut.state, dut.cnt,
                 (dut.cnt[5:0]==6'd0 && dut.cnt!=10'd0),
                 dut.w_rd, dut.j_d, dut.s_bus[dut.j_d], dut.acc);
        trc2 = trc2 + 1;
    end
    always @(posedge clk) if (rst_n && !(trc2 >= 60 && trc2 < 76)) trc2 = trc2 + 1;
    always @(posedge clk) if (rst_n) begin
        if (dut.neu_step !== 0) begin
            if (nstep < 5)
                $display("step@%0t n=%b i_raw=%0d t_step=%0d cnt=%0d",
                         $time, dut.neu_step, dut.i_raw_bcast, dut.t_step, dut.cnt);
            nstep = nstep + 1;
        end
        if (dut.state == 0 && dut.busy) $display("state=idle but busy");
    end

    always @(posedge clk) if (done) begin
        for (i=0;i<NNEU;i=i+1) begin
            if (spike_cnt[i] !== gold[i]) begin
                errors=errors+1;
                $display("[FAIL neu %0d] rtl=%0d gold=%0d", i, spike_cnt[i], gold[i]);
            end
        end
        if (errors==0)
            $display("=== tb_lif: PASS (16 neurons, %0d steps, counts bit-exact) ===", T);
        else
            $display("=== tb_lif: FAIL errors=%0d ===", errors);
        $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT busy=%b",busy); $finish; end
endmodule
