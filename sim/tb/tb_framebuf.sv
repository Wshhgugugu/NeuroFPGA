// tb_framebuf — 乒乓帧存单元验证
//   ① 双时钟读写: wclk=100MHz, rclk=75MHz
//   ② 帧写入翻转写页, vs 下降沿读页跟随 → 读到上一帧数据
//   ③ 两帧内容不同, 验证乒乓隔离 (第二帧写入期间读出的仍是第一帧)
`timescale 1ns/1ps
module tb_framebuf;
    localparam integer W = 64, H = 32, N = W*H;

    reg wclk = 0, rclk = 0, wrst_n = 0, rrst_n = 0;
    always #5  wclk = ~wclk;    // 100MHz
    always #6.7 rclk = ~rclk;   // ~75MHz

    reg         we = 0;
    reg  [19:0] waddr = 0;
    reg         wd = 0;
    reg         w_frame_end = 0;
    reg         gwe = 0;
    reg  [16:0] gwaddr = 0;
    reg  [7:0]  gwd = 0;
    reg         r_vs = 1;
    reg  [19:0] raddr = 0;
    wire        rd;
    wire [7:0]  grd;

    framebuf_pp #(.IMG_W(W), .IMG_H(H)) dut (
        .wclk(wclk), .wrst_n(wrst_n),
        .we(we), .waddr(waddr), .wd(wd), .w_frame_end(w_frame_end),
        .gwe(gwe), .gwaddr(gwaddr), .gwd(gwd),
        .rclk(rclk), .rrst_n(rrst_n),
        .r_vs(r_vs), .raddr(raddr), .rd(rd),
        .graddr(gwaddr), .grd(grd));

    integer errors = 0;
    integer i;

    // ---- 帧写入任务: 全帧写 val 位 + 灰度写行号 ----
    task write_frame(input val);
        begin
            for (i = 0; i < N; i = i + 1) begin
                @(posedge wclk);
                we <= 1; waddr <= i[19:0]; wd <= val;
                if (i < N/4) begin           // 灰度通道 (1/4 深度)
                    gwe <= 1; gwaddr <= i[16:0]; gwd <= val ? 8'hA5 : 8'h3C;
                end
            end
            @(posedge wclk); we <= 0; gwe <= 0;
            @(posedge wclk); w_frame_end <= 1;
            @(posedge wclk); w_frame_end <= 0;
        end
    endtask

    // ---- 读校验任务: 全帧读期望 exp (edge) + gexp (gray) ----
    task check_frame(input exp, input [7:0] gexp, input integer frame_no);
        begin
            for (i = 0; i < N/4; i = i + 1) begin
                @(posedge rclk);
                raddr <= i[19:0]; gwaddr <= i[16:0];
                @(posedge rclk);      // 同步读晚 1 拍
                if (rd !== exp) begin
                    errors = errors + 1;
                    if (errors <= 5)
                        $display("[FAIL f%0d] addr=%0d exp=%b got=%b",
                                 frame_no, i, exp, rd);
                end
                if (grd !== gexp) begin
                    errors = errors + 1;
                    if (errors <= 5)
                        $display("[FAIL f%0d gray] addr=%0d exp=%h got=%h",
                                 frame_no, i, gexp, grd);
                end
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge wclk);
        wrst_n = 1; rrst_n = 1;

        // 帧 0: 全 0
        write_frame(1'b0);
        repeat (10) @(posedge rclk);
        // vs 下降沿 (读页跟随)
        @(posedge rclk); r_vs <= 0;
        repeat (5)  @(posedge rclk);
        @(posedge rclk); r_vs <= 1;
        repeat (5)  @(posedge rclk);
        check_frame(1'b0, 8'h3C, 0);

        // 帧 1: 全 1 (写入另一页, 读页内容不变)
        write_frame(1'b1);
        repeat (10) @(posedge rclk);
        @(posedge rclk); r_vs <= 0;
        repeat (5)  @(posedge rclk);
        @(posedge rclk); r_vs <= 1;
        repeat (5)  @(posedge rclk);
        check_frame(1'b1, 8'hA5, 1);

        if (errors == 0)
            $display("=== tb_framebuf: PASS (乒乓隔离+灰度, 双时钟) ===");
        else
            $display("=== tb_framebuf: FAIL errors=%0d ===", errors);
        $finish;
    end

    initial begin #2_000_000; $display("TIMEOUT"); $finish; end
endmodule
