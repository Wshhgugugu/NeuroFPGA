// tb_brain — 数字大脑 Phase A: 世界→眼→SNN→行为 闭环 (纯仿真)
//
//   世界: 64×64 平灰背景 + 一个亮度食物球 (半径 5, 缓慢漂移)
//   NPC:  位置 (bx,by), 视野以自身为中心渲染 (所见即所得)
//   大脑: vision_top 全链 — Canny 边缘 → act_mem 8×8 (顶盖: 方向)
//         → SNN 16 神经元 (唤醒度: 尖峰总数), 每帧自动推理
//   行为 (TB 充当身体): 朝活动质心移动, 步长 ∝ 唤醒度
//   PASS: ≤40 帧内 NPC 到食物距离 < 6 (进入球内)
`timescale 1ns/1ps
module tb_brain;
    localparam integer SZ = 64, HALF = 32;
    localparam integer FOOD_R = 5;

    reg sys_clk = 0, rst_n_btn = 0, pclk = 0;
    always #10 sys_clk = ~sys_clk;
    always #9  pclk = ~pclk;

    reg  sim_s_valid = 0, sim_s_sof = 0;
    reg  [7:0] sim_s_data = 0;
    wire sim_e_valid, sim_e_edge, sim_e_eof;
    wire sccb_scl; wire sccb_sda = 1'b1;
    wire cam_rst_n, cam_pwdn;
    wire [9:0] tmds_r, tmds_g, tmds_b, tmds_clk;
    wire hdmi_hs, hdmi_vs, hdmi_de;
    wire [1:0] led;

    vision_top #(.IMG_W(SZ), .IMG_H(SZ), .NCHAN(1), .SOFT_CTRL(1)) dut (
        .sys_clk(sys_clk), .rst_n_btn(rst_n_btn),
        .pclk(pclk), .cam_href(1'b0), .cam_vsync(1'b0), .cam_data(8'd0),
        .sccb_scl(sccb_scl), .sccb_sda(sccb_sda),
        .cam_rst_n(cam_rst_n), .cam_pwdn(cam_pwdn),
        .tmds_r(tmds_r), .tmds_g(tmds_g), .tmds_b(tmds_b), .tmds_clk(tmds_clk),
        .hdmi_hs(hdmi_hs), .hdmi_vs(hdmi_vs), .hdmi_de(hdmi_de),
        .led(led),
        .sim_s_valid(sim_s_valid), .sim_s_sof(sim_s_sof),
        .sim_s_data(sim_s_data),
        .sim_e_valid(sim_e_valid), .sim_e_edge(sim_e_edge), .sim_e_eof(sim_e_eof));

    // ---------------- 世界状态 ----------------
    integer fx = 40, fy = 20;        // 食物 (世界坐标)
    integer bx = 12, by = 40;        // NPC
    integer wx, wy, dx, dy, d2;

    function [7:0] render(input integer x, input integer y);
        // 视野 (x,y) ↔ 世界 (bx+x-HALF, by+y-HALF)
        integer wwx, wwy;
        begin
            wwx = bx + x - HALF;
            wwy = by + y - HALF;
            dx = fx - wwx; dy = fy - wwy;
            if (dx*dx + dy*dy <= FOOD_R*FOOD_R) render = 8'd230;
            else                                 render = 8'd40;
        end
    endfunction

    // ---------------- 喂帧 ----------------
    task feed_frame;
        integer x, y, g;
        begin
            for (y = 0; y < SZ; y = y + 1) begin
                for (x = 0; x < SZ; x = x + 1) begin
                    @(posedge pclk);
                    sim_s_valid <= 1; sim_s_data <= render(x, y);
                    sim_s_sof <= (y == 0) && (x == 0);
                end
                for (g = 0; g < 6; g = g + 1) begin
                    @(posedge pclk); sim_s_valid <= 0; sim_s_sof <= 0;
                end
            end
            @(posedge pclk); sim_s_valid <= 0;
        end
    endtask

    // ---------------- SNN done 捕获 ----------------
    reg snn_done_evt = 0;
    always @(posedge sys_clk) if (dut.snn_done) snn_done_evt = 1;

    // ---------------- 主行为循环 ----------------
    integer frame = 0;
    integer cx, cy, wsum, binx, biny;
    integer spikes, i;
    integer dist0, dst;
    integer step;
    real arousal;
    integer errors = 0;
    integer arrived = 0;

    initial begin
        repeat (10) @(posedge pclk); rst_n_btn = 1;
        wait (dut.cfg_done === 1'b1);
        repeat (10) @(posedge pclk);

        dx = fx - bx; dy = fy - by;
        dist0 = dx*dx + dy*dy;
        $display("[brain] 出发: NPC(%0d,%0d) 食物(%0d,%0d) 距离²=%0d",
                 bx, by, fx, fy, dist0);

        while (frame < 40) begin
            frame = frame + 1;
            feed_frame;

            // 等大脑消化完 (搬运 64 拍 + SNN 64 步推理)
            snn_done_evt = 0;
            wait (snn_done_evt);
            @(posedge sys_clk);

            // ---- 读脑: 活动质心 (顶盖=方向) + 尖峰总数 (唤醒=动力) ----
            cx = 0; cy = 0; wsum = 0; spikes = 0;
            for (i = 0; i < 64; i = i + 1) begin
                biny = i / 8; binx = i % 8;
                cx = cx + binx * dut.act_mem[i];
                cy = cy + biny * dut.act_mem[i];
                wsum = wsum + dut.act_mem[i];
            end
            for (i = 0; i < 16; i = i + 1)      // SNN 只有 16 个神经元
                spikes = spikes + dut.snn_cnt[i];

            dx = fx - bx; dy = fy - by;
            dst = dx*dx + dy*dy;

            if (dst <= FOOD_R*FOOD_R) begin
                $display("[brain] 帧%0d: 到达食物! dst²=%0d 唤醒=%0d",
                         frame, dst, spikes);
                arrived = frame;
                frame = 1000;   // 成功退出
            end else begin
                // 行为: 朝质心走 (质心在视野坐标, 中心是 3.5)
                if (wsum > 0) begin
                    arousal = spikes;   // 唤醒度 (尖峰越多越兴奋)
                    step = (spikes > 20) ? 3 : (spikes > 5) ? 2 : 1;
                    bx = bx + ((cx / wsum) > 3 ? step :
                               ((cx / wsum) < 3 ? -step : 0));
                    by = by + ((cy / wsum) > 3 ? step :
                               ((cy / wsum) < 3 ? -step : 0));
                end
                $display("[brain] 帧%0d: 活动=%0d 质心(%0d,%0d) 唤醒=%0d → NPC(%0d,%0d) dst²=%0d",
                         frame, wsum, cx/wsum, cy/wsum, spikes, bx, by, dst);
                // 食物缓慢漂移 (世界不是死的)
                fx = fx + (frame % 4 == 0 ? 1 : 0);
                fy = fy - (frame % 6 == 0 ? 1 : 0);
            end
        end

        dx = fx - bx; dy = fy - by; dst = dx*dx + dy*dy;
        if (dst <= (FOOD_R+2)*(FOOD_R+2))
            $display("=== tb_brain: PASS (觅食闭环: dst² %0d → %0d, %0d 帧) ===",
                     dist0, dst, arrived);
        else begin
            $display("=== tb_brain: FAIL (未到达: dst²=%0d > %0d) ===",
                     dst, (FOOD_R+2)*(FOOD_R+2));
        end
        $finish;
    end

    initial begin #500_000_000; $display("TIMEOUT frame=%0d", frame); $finish; end
endmodule
