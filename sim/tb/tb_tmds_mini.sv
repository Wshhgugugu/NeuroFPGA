`timescale 1ns/1ps
module tb_tmds_mini;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [23:0] rgb=24'h3C3C3C;
    reg de=1;
    wire [9:0] wr,wg,wb,wclk;
    wire signed [3:0] br,bg,bb;
    hdmi_tx u (.clk_pix(clk),.rst_n(rst_n),.rgb(rgb),.de(de),
               .hs_sync(0),.vs_sync(0),
               .tmds_r_ch(wr),.tmds_g_ch(wg),.tmds_b_ch(wb),
               .tmds_clk_word(wclk),.bal_r(br),.bal_g(bg),.bal_b(bb));
    integer i;
    initial begin
        repeat(2) @(posedge clk); rst_n=1;
        @(posedge clk);
        for (i=0;i<20;i=i+1) begin
            @(posedge clk);
            $display("%02d w=%010b bal=%0d", i, wr, br);
        end
        $finish;
    end
endmodule
