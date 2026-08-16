// tb_hyst — hysteresis 独立测试: cls 流 -> edge 流, vs golden
`timescale 1ns/1ps
module tb_hyst;
    localparam integer SZ=64, N=SZ*SZ;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    reg s_valid=0, s_sof=0, s_eol=0, s_eof=0;
    reg [1:0] s_class=0;
    wire m_valid, m_edge, m_sof, m_eol, m_eof, busy;

    hysteresis #(.IMG_W(SZ), .IMG_H(SZ), .MAX_PASS(256)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_class(s_class),
        .s_eol(s_eol), .s_eof(s_eof),
        .m_valid(m_valid), .m_edge(m_edge), .m_sof(m_sof),
        .m_eol(m_eol), .m_eof(m_eof), .busy(busy));

    reg [7:0] cls [0:N-1];
    reg [7:0] gold [0:N-1];
    integer out_cnt=0, errors=0;
    integer fx, fy, fg, fd;

    initial $readmemh("sim/stimulus/cls_64x64.hex", cls);
    initial $readmemh("sim/reference/golden_output.hex", gold);

    // 跟踪: 捕获/晋升
    integer cap_cnt=0;
    always @(posedge clk) if (dut.phase==1 && dut.cap_addr < 8 && s_valid)
        $display("capt[%0d] cls=%b", dut.cap_addr, s_class);

    // pass1 reader 字流探针 (前 70 个)
    integer rdn = 0;
    always @(posedge clk) if (dut.phase==2 && dut.rd_pix && rdn < 70) begin
        $display("rd[%0d] addr=%0d word=%b",
                 rdn, dut.rd_addr, {dut.weak_mem[dut.rd_addr], dut.strong_mem[dut.rd_addr]});
        rdn = rdn + 1;
    end

    // pass1 窗口探针
    integer passseen=0;
    always @(posedge clk) if (dut.phase==2 && dut.u_win.w_valid &&
        ((dut.u_win.w_row==0 && dut.u_win.w_col<=2) ||
         (dut.u_win.w_row==0 && dut.u_win.w_col==16) ||
         (dut.u_win.w_row==1 && dut.u_win.w_col<=1)))
        $display("p%0d win r=%0d c=%0d: %b%b%b / %b%b%b / %b%b%b",
                 dut.pass_cnt, dut.u_win.w_row, dut.u_win.w_col,
                 dut.u_win.w_pix[0][0][0],dut.u_win.w_pix[0][1][0],dut.u_win.w_pix[0][2][0],
                 dut.u_win.w_pix[1][0][0],dut.u_win.w_pix[1][1][0],dut.u_win.w_pix[1][2][0],
                 dut.u_win.w_pix[2][0][0],dut.u_win.w_pix[2][1][0],dut.u_win.w_pix[2][2][0]);

    initial begin
        repeat(3) @(posedge clk); rst_n=1;
        repeat(2) @(posedge clk);
        for (fy=0; fy<SZ; fy=fy+1) begin
            for (fx=0; fx<SZ; fx=fx+1) begin
                @(posedge clk);
                s_valid<=1; s_class<=cls[fy*SZ+fx][1:0];
                s_sof<=(fy==0)&&(fx==0);
                s_eol<=(fx==SZ-1); s_eof<=(fy==SZ-1)&&(fx==SZ-1);
            end
            for (fg=0; fg<4; fg=fg+1) begin
                @(posedge clk); s_valid<=0; s_sof<=0; s_eol<=0; s_eof<=0;
            end
        end
        @(posedge clk); s_valid<=0;
    end

    always @(posedge clk) if (m_valid && out_cnt<N) begin
        if (m_edge !== gold[out_cnt][0]) begin
            errors=errors+1;
            if (errors<=10)
                $display("[FAIL %0d] y=%0d x=%0d gold=%b rtl=%b",
                         out_cnt, out_cnt/SZ, out_cnt%SZ, gold[out_cnt][0], m_edge);
        end
        out_cnt=out_cnt+1;
    end

    initial begin
        wait(rst_n); wait(m_eof);
        repeat(20) @(posedge clk);
        if (out_cnt==N && errors==0)
            $display("=== tb_hyst: PASS ===");
        else
            $display("=== tb_hyst: FAIL cnt=%0d errors=%0d pass_cnt=%0d ===",
                     out_cnt, errors, dut.pass_cnt);
        $finish;
    end
    initial begin #50_000_000; $display("TIMEOUT cnt=%0d phase=%0d",out_cnt,dut.phase); $finish; end
endmodule
