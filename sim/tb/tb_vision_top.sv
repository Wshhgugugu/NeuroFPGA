// tb_vision_top — 64x64 端到端: 仿真灰度流 -> vision_top(CDC+Canny) vs golden
`timescale 1ns/1ps
module tb_vision_top;
    localparam integer SZ=64, N=SZ*SZ;
    reg sys_clk=0, rst_n=0, pclk=0;
    always #10  sys_clk=~sys_clk;   // 50MHz
    always #20.8 pclk=~pclk;        // 24MHz

    reg sim_s_valid=0, sim_s_sof=0;
    reg [7:0] sim_s_data=0;
    wire sim_e_valid, sim_e_edge, sim_e_eof;
    wire [1:0] led;

    vision_top #(.IMG_W(SZ), .IMG_H(SZ), .MAX_PASS(256), .SOFT_CTRL(1)) dut (
        .sys_clk(sys_clk), .rst_n_btn(rst_n),
        .pclk(pclk), .cam_href(0), .cam_vsync(0), .cam_data(0),
        .sccb_scl(), .sccb_sda(), .cam_rst_n(), .cam_pwdn(),
        .tmds_r(), .tmds_g(), .tmds_b(), .tmds_clk(),
        .hdmi_hs(), .hdmi_vs(), .hdmi_de(),
        .led(led),
        .sim_s_valid(sim_s_valid), .sim_s_sof(sim_s_sof),
        .sim_s_data(sim_s_data),
        .sim_e_valid(sim_e_valid), .sim_e_edge(sim_e_edge), .sim_e_eof(sim_e_eof));

    reg [7:0] stim[0:N-1];
    reg [7:0] gold[0:N-1];
    integer out_cnt=0, errors=0;
    integer fx, fy, fg;
    initial $readmemh("sim/stimulus/test_image_64x64.hex", stim);
    initial $readmemh("sim/reference/golden_output.hex", gold);

    // pclk 域喂图 (行间 6 空拍)
    initial begin
        repeat(10) @(posedge pclk); rst_n=1;
        // 等 SCCB 表下载完 (NACK 也会走完, ~180ms 仿真时间)
        wait (dut.cfg_done === 1'b1);
        repeat(10) @(posedge pclk);
        for (fy=0; fy<SZ; fy=fy+1) begin
            for (fx=0; fx<SZ; fx=fx+1) begin
                @(posedge pclk);
                sim_s_valid<=1; sim_s_data<=stim[fy*SZ+fx];
                sim_s_sof<=(fy==0)&&(fx==0);
            end
            for (fg=0; fg<6; fg=fg+1) begin
                @(posedge pclk); sim_s_valid<=0; sim_s_sof<=0;
            end
        end
        @(posedge pclk); sim_s_valid<=0;
    end

    always @(posedge sys_clk) if (sim_e_valid && out_cnt<N) begin
        if (sim_e_edge !== gold[out_cnt][0]) begin
            errors=errors+1;
            if (errors<=10)
                $display("[FAIL %0d] y=%0d x=%0d gold=%b rtl=%b",
                         out_cnt, out_cnt/SZ, out_cnt%SZ, gold[out_cnt][0], sim_e_edge);
        end
        out_cnt=out_cnt+1;
    end

    integer dtn=0;
    always @(posedge sys_clk) if (dut.u_canny.dt_v && dtn<8) begin
        $display("[dt %0d] cls=%0d", dtn, dut.u_canny.dt_cls); dtn=dtn+1;
    end
    always @(posedge sys_clk) if (dut.u_canny.dt_sof) $display("[dt SOF@%0t]", $time);
    always @(posedge sys_clk) if (dut.u_canny.dt_eof) $display("[dt EOF@%0t capaddr=%0d]",
        $time, dut.u_canny.u_hyst.cap_addr);

    initial begin
        wait(rst_n); wait(sim_e_eof);
        repeat(50) @(posedge sys_clk);
        if (out_cnt==N && errors==0)
            $display("=== tb_vision_top: PASS (end-to-end %0d px, bit-exact) ===", out_cnt);
        else
            $display("=== tb_vision_top: FAIL cnt=%0d errors=%0d ===", out_cnt, errors);
        $finish;
    end
    initial begin #600_000_000; $display("TIMEOUT cnt=%0d",out_cnt); $finish; end
endmodule
