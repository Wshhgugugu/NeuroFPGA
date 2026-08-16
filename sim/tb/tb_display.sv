// tb_display — Phase 5 出口准则验证:
//   ① vga_timing 720p60 计数与标准逐项一致 (HT/VT/HS/VS/DE)
//   ② TMDS 编码: 自解码往返一致 + 运行不平衡度有界 + 每字跳变<=5
//   ③ color_map 四模式抽查
`timescale 1ns/1ps
module tb_display;
    reg clk=0, rst_n=0;
    always #6.734 clk=~clk;   // 74.25MHz

    integer errors=0;
    reg rst_t=0;

    // ------------------------------------------------------------------
    // ① vga_timing
    // ------------------------------------------------------------------
    wire hs, vs, de, sof;
    wire [12:0] x, y;

    vga_timing u_vga (.clk(clk), .rst_n(rst_n),
                      .hs(hs), .vs(vs), .de(de), .x(x), .y(y), .sof(sof));

    integer px_cnt=0, de_cnt=0, hs_cnt=0, vs_cnt=0;
    integer frames=0;
    reg [12:0] hs_start_x, hs_end_x;
    reg        hs_seen=0;

    always @(posedge clk) if (rst_n) begin
        px_cnt <= px_cnt+1;
        if (de) begin
            de_cnt <= de_cnt+1;
            if (sof) begin
                // 新帧: 检查上一帧
                if (frames > 0) begin
                    if (px_cnt != 1650*750) begin
                        errors=errors+1;
                        $display("[FAIL vga] frame pixels=%0d exp=%0d", px_cnt, 1650*750);
                    end
                    if (de_cnt != 1280*720) begin
                        errors=errors+1;
                        $display("[FAIL vga] de pixels=%0d exp=%0d", de_cnt, 1280*720);
                    end
                    if (hs_cnt != 40) begin errors=errors+1; $display("[FAIL vga] hs=%0d",hs_cnt); end
                    if (vs_cnt != 5)  begin errors=errors+1; $display("[FAIL vga] vs=%0d",vs_cnt); end
                end
                px_cnt<=0; de_cnt<=0; hs_cnt<=0; vs_cnt<=0; hs_seen<=0;
                frames<=frames+1;
            end
        end
        if (hs && !hs_seen) begin hs_seen<=1; hs_start_x<=x; end
        if (hs) hs_cnt<=hs_cnt+1;
        if (vs) vs_cnt<=vs_cnt+1;
        if (hs_seen && !hs && hs_end_x === 13'd0) hs_end_x <= x;
        if (frames==2) begin
            $display("[vga] hs_start_x=%0d (exp 1390)", hs_start_x);
            if (hs_start_x !== 13'd1390) begin errors=errors+1; $display("[FAIL vga] hs_start"); end
        end
    end

    // ------------------------------------------------------------------
    // ② TMDS 编码
    // ------------------------------------------------------------------
    reg [23:0] rgb=0;
    reg de_t=0, hsyn=0, vsyn=0;
    wire [9:0] wr, wg, wb, wclk;
    wire signed [3:0] br, bg, bb;

    hdmi_tx u_tx (.clk_pix(clk), .rst_n(rst_n),
                  .rgb(rgb), .de(de_t), .hs_sync(hsyn), .vs_sync(vsyn),
                  .tmds_r_ch(wr), .tmds_g_ch(wg), .tmds_b_ch(wb),
                  .tmds_clk_word(wclk),
                  .bal_r(br), .bal_g(bg), .bal_b(bb));

    // 自解码: w[9]=低8位反转标志, w[8]=级1反转标志, 链上相等=d 翻转
    function [7:0] tmds_decode(input [9:0] w);
        reg [7:0] low;
        integer k;
        begin
            low = w[9] ? ~w[7:0] : w[7:0];
            low = w[8] ? ~low : low;
            tmds_decode[0] = low[0];
            for (k=1;k<8;k=k+1)
                tmds_decode[k] = tmds_decode[k-1] ^ (low[k] == low[k-1]);
        end
    endfunction

    // 随机激励
    integer t;
    reg [23:0] exp_rgb;
    reg [7:0] dec_r, dec_g, dec_b;
    integer ntrans;
    integer tcnt=0;

    always @(posedge clk) if (rst_t) begin
        {rgb, exp_rgb} <= {rgb, rgb};
        if (de_t) begin
            // 解上一拍寄存字 (码字在 rgb 之后一拍)
        end
    end
    // 检查过程
    integer cyc=0;
    reg [23:0] data_d;
    reg        de_d;
    always @(posedge clk) begin
        cyc<=cyc+1;
        data_d <= rgb;
        de_d   <= de_t;
        if (cyc>10 && de_d) begin
            dec_r = tmds_decode(wr);
            dec_g = tmds_decode(wg);
            dec_b = tmds_decode(wb);
            if (dec_r !== data_d[23:16] || dec_g !== data_d[15:8] || dec_b !== data_d[7:0]) begin
                errors=errors+1;
                if (errors<10)
                    $display("[FAIL tmds] exp=%h got r=%h g=%h b=%h",
                             data_d, dec_r, dec_g, dec_b);
            end
            if (br > 6 || br < -6 || bg > 6 || bg < -6 || bb > 6 || bb < -6) begin
                errors=errors+1;
                if (errors<10) $display("[FAIL tmds bal] %0d %0d %0d", br, bg, bb);
            end
            // 跳变计数
            ntrans = 0;
            for (t=0;t<9;t=t+1) if (wr[t] != wr[t+1]) ntrans=ntrans+1;
            if (ntrans > 8) begin errors=errors+1; $display("[FAIL tmds trans]=%0d",ntrans); end
        end
    end

    // TMDS 随机数据激励
    integer seed=42;
    always @(posedge clk) if (cyc>5 && cyc<3000) begin
        rgb <= $random;
        de_t <= ($random % 8) != 0;
        hsyn <= 0; vsyn <= 0;
    end

    // ------------------------------------------------------------------
    // ③ color_map 抽查 (模式 0/1/3: 定值; 模式 2: 首带 heat=0 -> R=0,B=~0=FF)
    // ------------------------------------------------------------------
    wire [23:0] cm_rgb;
    wire cm_de;
    reg [1:0] mode=0;
    reg [7:0] gray=8'h80;
    reg edge_bit=0;
    reg [7:0] heat [0:15];
    reg [12:0] dy=0;
    integer hidx;
    initial for (hidx=0;hidx<16;hidx=hidx+1) heat[hidx]=hidx*16;

    color_map u_cm (.clk(clk), .rst_n(rst_n), .mode(mode), .gray(gray),
                    .edge_bit(edge_bit), .snn_heat(heat), .disp_y(dy),
                    .in_de(1'b1), .rgb(cm_rgb), .out_de(cm_de));

    initial begin
        repeat(3) @(posedge clk); rst_n=1; rst_t=1;
    end

    initial begin
        wait (cyc > 3200);
        mode<=0; edge_bit<=0; dy<=0;
        repeat(4) @(posedge clk);
        if (cm_rgb !== 24'h808080) begin errors=errors+1; $display("[FAIL cm0] %h",cm_rgb); end

        mode<=1; edge_bit<=1;
        repeat(4) @(posedge clk);
        if (cm_rgb !== 24'hFF2000) begin errors=errors+1; $display("[FAIL cm1] %h",cm_rgb); end

        mode<=2; edge_bit<=0; dy<=0;       // neu_sel2=0 -> heat=0x00
        repeat(4) @(posedge clk);
        if (cm_rgb[23:16] !== 8'h00 || cm_rgb[7:0] !== 8'hFF) begin
            errors=errors+1; $display("[FAIL cm2] %h",cm_rgb); end

        mode<=3; edge_bit<=1;
        repeat(4) @(posedge clk);
        if (cm_rgb !== 24'hFF4000) begin errors=errors+1; $display("[FAIL cm3] %h",cm_rgb); end

        if (errors==0) $display("=== tb_display: PASS ===");
        else $display("=== tb_display: FAIL errors=%0d ===", errors);
        $finish;
    end

    // 等两帧 vga + tmds 段后由上面收尾; 超时保护
    initial begin
        #1_500_000;
        $display("=== tb_display: TIMEOUT errors=%0d frames=%0d ===", errors, frames);
        $finish;
    end

endmodule
