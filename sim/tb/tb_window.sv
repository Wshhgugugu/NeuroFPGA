// tb_window — window_kxk 独立对齐测试: 行 r 全部填值 r, 窗口应严格 = 行号图案
`timescale 1ns/1ps
module tb_window;
    localparam integer W = 8, H = 8, K = 5;
    localparam integer HF = (K-1)/2;
    reg clk=0, rst_n=0;
    always #5 clk = ~clk;

    reg s_valid=0, s_sof=0;
    reg [7:0] s_data=0;
    wire wv, we;
    wire [K-1:0][K-1:0][7:0] wp;
    wire [2:0] wr, wc;

    window_kxk #(.K(K), .DW(8), .IMG_W(W), .IMG_H(H)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .w_valid(wv), .w_pix(wp), .w_row(wr), .w_col(wc), .w_eof(we));

    integer x, y, g, errs=0;
    integer expv;
    integer fx, fy, fg;   // 喂图专用 (与检查循环的 x/y 隔离)
    initial begin
        repeat(3) @(posedge clk); rst_n=1;
        repeat(2) @(posedge clk);
        for (fy=0; fy<H; fy=fy+1) begin
            for (fx=0; fx<W; fx=fx+1) begin
                @(posedge clk);
                s_valid<=1; s_data<=fy; s_sof<=(fy==0)&&(fx==0);
            end
            for (fg=0; fg<4; fg=fg+1) begin @(posedge clk); s_valid<=0; s_sof<=0; end
        end
        @(posedge clk); s_valid<=0;
    end

    // 收集: 窗行 i 的期望值 = wr-2+i (越界为 0), 窗列 k 期望 = wc-2+k (越界 0)
    always @(posedge clk) if (wv) begin
        for (y=0; y<K; y=y+1) for (x=0; x<K; x=x+1) begin
            expv = 0;
            if ((wr-HF+y >= 0) && (wr-HF+y < H) && ((wc-HF+x) >= 0) && ((wc-HF+x) < W))
                expv = wr-HF+y;    // 图案: 值=行号 (与列无关)
            if (wp[y][x] !== expv[7:0]) begin
                errs = errs+1;
                if (errs<=15)
                    $display("MISMATCH r=%0d c=%0d [%0d][%0d]: got=%0d exp=%0d",
                             wr, wc, y, x, wp[y][x], expv);
            end
        end
        $display("win r=%0d c=%0d : %3d %3d %3d %3d %3d / %3d %3d %3d %3d %3d / %3d %3d %3d %3d %3d / %3d %3d %3d %3d %3d / %3d %3d %3d %3d %3d",
                 wr, wc,
                 wp[0][0],wp[0][1],wp[0][2],wp[0][3],wp[0][4],
                 wp[1][0],wp[1][1],wp[1][2],wp[1][3],wp[1][4],
                 wp[2][0],wp[2][1],wp[2][2],wp[2][3],wp[2][4],
                 wp[3][0],wp[3][1],wp[3][2],wp[3][3],wp[3][4],
                 wp[4][0],wp[4][1],wp[4][2],wp[4][3],wp[4][4]);
    end

    initial begin
        wait(rst_n); wait(we);
        repeat(10) @(posedge clk);
        if (errs==0) $display("=== tb_window: PASS ===");
        else $display("=== tb_window: FAIL errs=%0d ===", errs);
        $finish;
    end
    initial begin #1_000_000; $display("TIMEOUT"); $finish; end
endmodule
