// tb_multi — 多核并行验证 (NCHAN=2)
//   通道 0 喂 edge 图案, 通道 1 喂 noise 图案; 每路输出与各自 golden 对比。
//   同时检查两路互相隔离 (通道 1 输出不受通道 0 影响)。
`timescale 1ns/1ps
module tb_multi;
    localparam integer SZ = 64, N = SZ*SZ;

    reg sys_clk=0, rst_n_btn=0, pclk=0;
    always #10 sys_clk = ~sys_clk;
    always #9  pclk = ~pclk;

    // 每路独立激励
    reg sim_s_valid0=0, sim_s_sof0=0;
    reg [7:0] sim_s_data0=0;
    reg sim_s_valid1=0, sim_s_sof1=0;
    reg [7:0] sim_s_data1=0;
    wire [1:0] sim_e_valid, sim_e_edge, sim_e_eof;

    wire sccb_scl; wire sccb_sda = 1'b1;
    wire cam_rst_n, cam_pwdn;
    wire [9:0] tmds_r, tmds_g, tmds_b, tmds_clk;
    wire hdmi_hs, hdmi_vs, hdmi_de;
    wire [1:0] led;

    vision_top #(.IMG_W(SZ), .IMG_H(SZ), .NCHAN(2)) dut (
        .sys_clk(sys_clk), .rst_n_btn(rst_n_btn),
        .pclk(pclk), .cam_href(1'b0), .cam_vsync(1'b0), .cam_data(8'd0),
        .sccb_scl(sccb_scl), .sccb_sda(sccb_sda),
        .cam_rst_n(cam_rst_n), .cam_pwdn(cam_pwdn),
        .tmds_r(tmds_r), .tmds_g(tmds_g), .tmds_b(tmds_b), .tmds_clk(tmds_clk),
        .hdmi_hs(hdmi_hs), .hdmi_vs(hdmi_vs), .hdmi_de(hdmi_de),
        .led(led),
        .sim_s_valid({sim_s_valid1, sim_s_valid0}),
        .sim_s_sof({sim_s_sof1, sim_s_sof0}),
        .sim_s_data({sim_s_data1, sim_s_data0}),
        .sim_e_valid(sim_e_valid), .sim_e_edge(sim_e_edge), .sim_e_eof(sim_e_eof));

    reg [7:0] stim0[0:N-1], stim1[0:N-1];
    reg [7:0] gold0[0:N-1], gold1[0:N-1];
    integer out0=0, out1=0, err0=0, err1=0;
    integer fx, fy, fg;

    initial begin
        $readmemh("sim/stimulus/test_image_64x64.hex",   stim0);
        $readmemh("sim/stimulus/test_noise.hex",         stim1);
        $readmemh("sim/reference/golden_output.hex",     gold0);
        // 通道 1 golden: noise 图案专用
        $readmemh("sim/reference/golden_noise.hex",      gold1);
    end

    // 两路同时注入 (同 pclk 域)
    initial begin
        repeat(10) @(posedge pclk); rst_n_btn=1;
        wait (dut.cfg_done === 1'b1);
        repeat(10) @(posedge pclk);
        for (fy=0; fy<SZ; fy=fy+1) begin
            for (fx=0; fx<SZ; fx=fx+1) begin
                @(posedge pclk);
                sim_s_valid0<=1; sim_s_data0<=stim0[fy*SZ+fx];
                sim_s_sof0<=(fy==0)&&(fx==0);
                sim_s_valid1<=1; sim_s_data1<=stim1[fy*SZ+fx];
                sim_s_sof1<=(fy==0)&&(fx==0);
            end
            for (fg=0; fg<6; fg=fg+1) begin
                @(posedge pclk);
                sim_s_valid0<=0; sim_s_sof0<=0;
                sim_s_valid1<=0; sim_s_sof1<=0;
            end
        end
        @(posedge pclk); sim_s_valid0<=0; sim_s_valid1<=0;
    end

    // 通道 0 输出对比
    always @(posedge sys_clk) if (sim_e_valid[0] && out0<N) begin
        if (sim_e_edge[0] !== gold0[out0][0]) begin
            err0=err0+1;
            if (err0<=5) $display("[FAIL ch0] idx=%0d gold=%b rtl=%b",
                                 out0, gold0[out0][0], sim_e_edge[0]);
        end
        out0=out0+1;
    end

    // 通道 1 输出对比
    always @(posedge sys_clk) if (sim_e_valid[1] && out1<N) begin
        if (sim_e_edge[1] !== gold1[out1][0]) begin
            err1=err1+1;
            if (err1<=5) $display("[FAIL ch1] idx=%0d gold=%b rtl=%b",
                                 out1, gold1[out1][0], sim_e_edge[1]);
        end
        out1=out1+1;
    end

    initial begin
        wait(rst_n_btn); wait(&sim_e_eof);   // 两路都 EOF
        repeat(50) @(posedge sys_clk);
        if (out0==N && out1==N && err0==0 && err1==0)
            $display("=== tb_multi: PASS (NCHAN=2, ch0=%0d px ch1=%0d px, bit-exact) ===", out0, out1);
        else
            $display("=== tb_multi: FAIL ch0=%0d/%0d err=%0d ch1=%0d/%0d err=%0d ===",
                     out0, N, err0, out1, N, err1);
        $finish;
    end

    initial begin #5_000_000_000; $display("TIMEOUT out0=%0d out1=%0d", out0, out1); $finish; end
endmodule
