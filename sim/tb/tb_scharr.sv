// tb_scharr — scharr_3x3 + gradient_mag_dir 单级 vs golden 中间级 dump
//   (gx.hex/gy.hex/mag.hex/dir.hex 由 golden_model.py --dump-dir 生成)
`timescale 1ns/1ps
module tb_scharr;
    localparam integer SZ=64, N=SZ*SZ;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    // 原图 -> 高斯 (已验证) -> scharr -> mag/dir
    reg s_valid=0, s_sof=0;
    reg [7:0] s_data=0;
    wire g_v, g_sof, g_eol, g_eof; wire [7:0] g_d;

    gaussian_5x5 #(.IMG_W(SZ), .IMG_H(SZ)) u_gauss (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .m_valid(g_v), .m_data(g_d), .m_sof(g_sof), .m_eol(g_eol), .m_eof(g_eof));

    wire sc_v, sc_sof, sc_eol, sc_eof; wire [23:0] sc_d;
    scharr_3x3 #(.IMG_W(SZ), .IMG_H(SZ)) u_scharr (
        .clk(clk), .rst_n(rst_n),
        .s_valid(g_v), .s_sof(g_sof), .s_data(g_d),
        .m_valid(sc_v), .m_data(sc_d), .m_sof(sc_sof), .m_eol(sc_eol), .m_eof(sc_eof));

    wire md_v, md_sof, md_eol, md_eof; wire [13:0] md_d;
    gradient_mag_dir #(.IMG_W(SZ), .IMG_H(SZ)) u_mag (
        .clk(clk), .rst_n(rst_n),
        .s_valid(sc_v), .s_sof(sc_sof), .s_data(sc_d),
        .s_eol(sc_eol), .s_eof(sc_eof),
        .m_valid(md_v), .m_data(md_d), .m_sof(md_sof), .m_eol(md_eol), .m_eof(md_eof));

    reg [7:0] stim[0:N-1];
    reg [11:0] g_gx[0:N-1], g_gy[0:N-1], g_mag[0:N-1];
    reg [1:0] g_dir[0:N-1];
    integer out_cnt=0, errors=0, errors_mag=0;
    integer fx, fy, fg;
    integer signed rx, ry;
    initial $readmemh("sim/stimulus/test_image_64x64.hex", stim);
    initial begin
        $readmemh("sim/reference/gx.hex",  g_gx);
        $readmemh("sim/reference/gy.hex",  g_gy);
        $readmemh("sim/reference/mag.hex", g_mag);
        $readmemh("sim/reference/dir.hex", g_dir);
    end

    initial begin
        repeat(5) @(posedge clk); rst_n=1;
        repeat(5) @(posedge clk);
        for (fy=0; fy<SZ; fy=fy+1) begin
            for (fx=0; fx<SZ; fx=fx+1) begin
                @(posedge clk);
                s_valid<=1; s_data<=stim[fy*SZ+fx]; s_sof<=(fy==0)&&(fx==0);
            end
            for (fg=0; fg<4; fg=fg+1) begin @(posedge clk); s_valid<=0; s_sof<=0; end
        end
        @(posedge clk); s_valid<=0;
    end

    always @(posedge clk) if (sc_v && out_cnt<N) begin
        rx = $signed(sc_d[11:0]); ry = $signed(sc_d[23:12]);
        if (rx !== $signed(g_gx[out_cnt]) || ry !== $signed(g_gy[out_cnt])) begin
            errors=errors+1;
            if (errors<=6)
                $display("[scharr %0d] gx rtl=%0d gold=%0d gy rtl=%0d gold=%0d",
                         out_cnt, rx, g_gx[out_cnt], ry, g_gy[out_cnt]);
        end
        out_cnt=out_cnt+1;
    end

    integer m_cnt=0;
    always @(posedge clk) if (md_v && m_cnt<N) begin
        if (md_d[11:0] !== g_mag[m_cnt] || md_d[13:12] !== g_dir[m_cnt]) begin
            errors_mag=errors_mag+1;
            if (errors_mag<=6)
                $display("[mag %0d] rtl=%0d/%0d gold=%0d/%0d",
                         m_cnt, md_d[11:0], md_d[13:12], g_mag[m_cnt], g_dir[m_cnt]);
        end
        m_cnt=m_cnt+1;
    end

    initial begin
        wait(rst_n); wait(md_eof);
        repeat(20) @(posedge clk);
        if (out_cnt==N && errors==0 && m_cnt==N && errors_mag==0)
            $display("=== tb_scharr: PASS (gx/gy/mag/dir bit-exact) ===");
        else
            $display("=== tb_scharr: FAIL cnt=%0d/%0d e=%0d/%0d ===",
                     out_cnt, m_cnt, errors, errors_mag);
        $finish;
    end
    initial begin #5_000_000; $display("TIMEOUT"); $finish; end
endmodule
