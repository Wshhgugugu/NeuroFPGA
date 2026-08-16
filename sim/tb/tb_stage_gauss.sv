// tb_stage_gauss — gaussian_5x5 单级 vs golden/reference/gauss.hex
`timescale 1ns/1ps
module tb_stage_gauss;
    localparam integer SZ = 64, N = SZ*SZ;
    reg clk=0, rst_n=0;
    always #5 clk = ~clk;

    reg s_valid=0, s_sof=0;
    reg [7:0] s_data=0;
    wire m_valid, m_sof, m_eol, m_eof;
    wire [7:0] m_data;

    gaussian_5x5 #(.IMG_W(SZ), .IMG_H(SZ)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .m_valid(m_valid), .m_data(m_data), .m_sof(m_sof),
        .m_eol(m_eol), .m_eof(m_eof));

    reg [7:0] stim[0:N-1];
    reg [7:0] gold[0:N-1];
    reg [7:0] rtlo[0:N-1];
    integer out_cnt=0, errors=0;
    integer x,y,g,fd;

    initial $readmemh("sim/stimulus/test_image_64x64.hex", stim);
    initial $readmemh("sim/reference/gauss.hex", gold);

    initial begin
        repeat(5) @(posedge clk); rst_n=1;
        repeat(5) @(posedge clk);
        for (y=0; y<SZ; y=y+1) begin
            for (x=0; x<SZ; x=x+1) begin
                @(posedge clk);
                s_valid<=1; s_data<=stim[y*SZ+x]; s_sof<=(y==0)&&(x==0);
            end
            for (g=0; g<4; g=g+1) begin
                @(posedge clk); s_valid<=0; s_sof<=0;
            end
        end
        @(posedge clk); s_valid<=0;
    end

    // 逐拍 trace: 引擎移位序列
    integer trc = 0;
    always @(posedge clk) if (rst_n && (dut.u_win.shift || dut.u_win.s_valid || dut.u_win.w_valid)) begin
        if (trc >= 128 && trc < 140)
            $display("t=%0t x=%0d r=%0d emit=%b | wv=%b wp2=%h | gout=%h",
                     $time, dut.u_win.x, dut.u_win.r, dut.u_win.emit,
                     dut.u_win.w_valid, dut.u_win.w_pix[2], dut.gout);
        trc = trc + 1;
    end

    always @(posedge clk) if (m_valid && out_cnt<N) begin
        rtlo[out_cnt] <= m_data;
        if (out_cnt < 6)
            $display("win[%0d] r=%0d c=%0d rows: %0d %0d %0d %0d %0d | %h %h %h %h %h",
                     out_cnt, dut.u_win.w_row, dut.u_win.w_col,
                     dut.u_win.w_pix[0][2], dut.u_win.w_pix[1][2], dut.u_win.w_pix[2][2],
                     dut.u_win.w_pix[3][2], dut.u_win.w_pix[4][2],
                     dut.u_win.w_pix[2], dut.u_win.w_pix[3], dut.u_win.w_pix[4],
                     dut.u_win.sr[0][4], dut.u_win.feed_bank[0]);
        if (m_data !== gold[out_cnt]) begin
            errors=errors+1;
            if (errors<=10)
                $display("[FAIL] idx=%0d (y=%0d x=%0d) gold=%02x rtl=%02x",
                         out_cnt, out_cnt/SZ, out_cnt%SZ, gold[out_cnt], m_data);
        end
        out_cnt=out_cnt+1;
    end

    initial begin
        wait(rst_n); wait(m_eof);
        repeat(20) @(posedge clk);
        fd=$fopen("out/rtl_gauss.hex","w");
        for (x=0;x<N;x=x+1) $fwrite(fd,"%02X\n",rtlo[x]);
        $fclose(fd);
        if (out_cnt==N && errors==0)
            $display("=== tb_gauss: PASS (%0d px) ===", out_cnt);
        else
            $display("=== tb_gauss: FAIL cnt=%0d errors=%0d ===", out_cnt, errors);
        $finish;
    end

    initial begin #5_000_000; $display("TIMEOUT cnt=%0d",out_cnt); $finish; end
endmodule
