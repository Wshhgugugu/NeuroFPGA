// ============================================================================
// tb_canny — Canny 全链路 vs golden_model.py
//   激励: sim/stimulus/test_image_64x64.hex (每行 1 字节)
//   契约: 每行 64 像素连续 valid + 4 空拍; 帧尾等流水线/迟滞收敛
//   检查: 输出 edge 流 4096 点, 与 sim/reference/golden_output.hex 逐位比对
//   输出: out/rtl_output.hex (可再用 compare_output.py 复核)
// ============================================================================
`timescale 1ns/1ps

module tb_canny;

    localparam integer SZ = 64;
    localparam integer N  = SZ * SZ;
    localparam logic [11:0] TH_HI = 12'd600;
    localparam logic [11:0] TH_LO = 12'd200;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         s_valid = 0, s_sof = 0, s_eol = 0, s_eof = 0;
    reg  [7:0]  s_data = 0;
    wire        m_valid, m_edge, m_sof, m_eol, m_eof, busy;

    canny_top #(
        .IMG_W(SZ), .IMG_H(SZ), .MAX_PASS(256)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_sof(s_sof), .s_data(s_data),
        .s_eol(s_eol), .s_eof(s_eof),
        .th_hi(TH_HI), .th_lo(TH_LO),
        .m_valid(m_valid), .m_edge(m_edge), .m_sof(m_sof),
        .m_eol(m_eol), .m_eof(m_eof),
        .busy(busy)
    );

    // 激励图像 / 黄金参考 / RTL 输出
    reg [7:0] stim  [0:N-1];
    reg [7:0] gold  [0:N-1];
    reg [7:0] rtlout[0:N-1];
    reg [1023:0] stim_file, gold_file;
    integer out_cnt = 0;

    reg probe_en = 1'b1;
    initial begin
        if (!$value$plusargs("stim=%s", stim_file)) stim_file = "sim/stimulus/test_image_64x64.hex";
        else probe_en = 1'b0;
        if (!$value$plusargs("gold=%s", gold_file)) gold_file = "sim/reference/golden_output.hex";
        $readmemh(stim_file, stim);
        $readmemh(gold_file, gold);
    end

    // ---- 喂图 (契约: 行间 >=4 空拍; 本实验加随机行中气泡) ----
    integer y, x, g;
    integer bub;
    initial begin : feed
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        for (y = 0; y < SZ; y = y + 1) begin
            for (x = 0; x < SZ; x = x + 1) begin
                // 随机 0-2 拍行中气泡 (模拟 CDC 读侧空泡)
                bub = ($random % 3 + 3) % 3;
                for (g = 0; g < bub; g = g + 1) begin
                    @(posedge clk);
                    s_valid <= 0; s_sof <= 0; s_eol <= 0; s_eof <= 0;
                end
                @(posedge clk);
                s_valid <= 1;
                s_data  <= stim[y*SZ + x];
                s_sof   <= (y == 0) && (x == 0);
                s_eol   <= (x == SZ-1);
                s_eof   <= (y == SZ-1) && (x == SZ-1);
            end
            // 行间 4 空拍
            for (g = 0; g < 4; g = g + 1) begin
                @(posedge clk);
                s_valid <= 0; s_sof <= 0; s_eol <= 0; s_eof <= 0;
            end
        end
        @(posedge clk);
        s_valid <= 0; s_sof <= 0; s_eol <= 0; s_eof <= 0;
    end

    // ---- 收集输出 ----
    integer errors = 0;
    integer tp = 0, fp = 0, fn = 0;
    always @(posedge clk) begin
        if (m_valid) begin
            if (out_cnt < N) begin
                rtlout[out_cnt] <= m_edge;
                if (m_edge !== gold[out_cnt][0]) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("[FAIL] idx=%0d (y=%0d x=%0d) golden=%b rtl=%b",
                                 out_cnt, out_cnt/SZ, out_cnt%SZ,
                                 gold[out_cnt][0], m_edge);
                end
                if (m_edge && gold[out_cnt][0]) tp = tp + 1;
                if (m_edge && !gold[out_cnt][0]) fp = fp + 1;
                if (!m_edge && gold[out_cnt][0]) fn = fn + 1;
            end else begin
                errors = errors + 1;
                $display("[FAIL] output overflow at %0d", out_cnt);
            end
            out_cnt = out_cnt + 1;
        end
    end

    always @(posedge clk) if (rst_n && dut.u_med.u_win.w_valid &&
        (dut.u_med.u_win.w_row <= 1) && (dut.u_med.u_win.w_col >= 61)) begin
        $display("medwin r=%0d c=%0d: %04h %04h %04h / %04h %04h %04h / %04h %04h %04h",
                 dut.u_med.u_win.w_row, dut.u_med.u_win.w_col,
                 dut.u_med.u_win.w_pix[0][0][11:0], dut.u_med.u_win.w_pix[0][1][11:0], dut.u_med.u_win.w_pix[0][2][11:0],
                 dut.u_med.u_win.w_pix[1][0][11:0], dut.u_med.u_win.w_pix[1][1][11:0], dut.u_med.u_win.w_pix[1][2][11:0],
                 dut.u_med.u_win.w_pix[2][0][11:0], dut.u_med.u_win.w_pix[2][1][11:0], dut.u_med.u_win.w_pix[2][2][11:0]);
    end

    // ---- 中间级 golden 对比探针 ----
    reg [11:0] g_gx[0:N-1];  reg [11:0] g_gy[0:N-1];
    reg [11:0] g_mag[0:N-1]; reg [11:0] g_med[0:N-1]; reg [11:0] g_nms[0:N-1];
    reg [1:0]  g_dir[0:N-1];
    integer c2=0,c3=0,c4=0,c5=0;
    integer e2=0,e3=0,e4=0,e5=0;
    integer signed sc_gx, sc_gy;
    initial begin
        $readmemh("sim/reference/gx.hex", g_gx);
        $readmemh("sim/reference/gy.hex", g_gy);
        $readmemh("sim/reference/mag.hex", g_mag);
        $readmemh("sim/reference/median.hex", g_med);
        $readmemh("sim/reference/nms.hex", g_nms);
        $readmemh("sim/reference/dir.hex", g_dir);
    end
    always @(posedge clk) if (rst_n && probe_en) begin
        if (dut.sc_v) begin
            sc_gx = $signed(dut.sc_d[11:0]); sc_gy = $signed(dut.sc_d[23:12]);
            if (sc_gx !== $signed(g_gx[c2]) || sc_gy !== $signed(g_gy[c2])) begin
                e2=e2+1;
                if (e2<=5) $display("[scharr %0d] gx rtl=%0d gold=%0d gy rtl=%0d gold=%0d",
                                    c2, sc_gx, g_gx[c2], sc_gy, g_gy[c2]);
            end
            c2=c2+1;
        end
        if (dut.md_v) begin
            if (dut.md_d[11:0] !== g_mag[c3] || dut.md_d[13:12] !== g_dir[c3]) begin
                e3=e3+1;
                if (e3<=5) $display("[mag %0d] mag rtl=%0d gold=%0d dir rtl=%0d gold=%0d",
                                    c3, dut.md_d[11:0], g_mag[c3], dut.md_d[13:12], g_dir[c3]);
            end
            c3=c3+1;
        end
        if (dut.me_v) begin
            if (dut.me_d[11:0] !== g_med[c4]) begin
                e4=e4+1;
                if (e4<=3) begin
                    $display("[med %0d] rtl=%0d gold=%0d", c4, dut.me_d[11:0], g_med[c4]);
                    $display("  win: %04h %04h %04h / %04h %04h %04h / %04h %04h %04h",
                             dut.u_med.u_win.w_pix[0][0][11:0], dut.u_med.u_win.w_pix[0][1][11:0], dut.u_med.u_win.w_pix[0][2][11:0],
                             dut.u_med.u_win.w_pix[1][0][11:0], dut.u_med.u_win.w_pix[1][1][11:0], dut.u_med.u_win.w_pix[1][2][11:0],
                             dut.u_med.u_win.w_pix[2][0][11:0], dut.u_med.u_win.w_pix[2][1][11:0], dut.u_med.u_win.w_pix[2][2][11:0]);
                    $display("  r0=%h r1=%h r2=%h maxmin=%h minmax=%h medrow=%h",
                             dut.u_med.r0_r, dut.u_med.r1_r, dut.u_med.r2_r,
                             dut.u_med.max_of_mins, dut.u_med.min_of_maxs, dut.u_med.med_row);
                end
            end
            c4=c4+1;
        end
        if (dut.nm_v) begin
            if (dut.nm_d[11:0] !== g_nms[c5]) begin
                e5=e5+1;
                if (e5<=5) $display("[nms %0d] rtl=%0d gold=%0d dir=%0d", c5, dut.nm_d[11:0], g_nms[c5], dut.nm_d[13:12]);
            end
            c5=c5+1;
        end
    end

    // ---- 探针: 各级 valid 计数 ----
    integer c_g=0, c_sc=0, c_md=0, c_me=0, c_nm=0, c_dt=0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.g_v)  c_g  = c_g  + 1;
            if (dut.sc_v) c_sc = c_sc + 1;
            if (dut.md_v) c_md = c_md + 1;
            if (dut.me_v) c_me = c_me + 1;
            if (dut.nm_v) c_nm = c_nm + 1;
            if (dut.dt_v) c_dt = c_dt + 1;
        end
    end

    // ---- 汇总 ----
    real prec, rec, f1;
    integer fd;
    initial begin : monitor
        wait (rst_n);
        wait (m_eof);
        // m_eof 后输出应停止
        repeat (100) @(posedge clk);
        if (out_cnt != N) begin
            $display("=== tb_canny: FAIL, out_cnt=%0d (expect %0d) ===", out_cnt, N);
            $finish;
        end
        prec = (tp+fp) > 0 ? real'(tp)/real'(tp+fp) : 1.0;
        rec  = (tp+fn) > 0 ? real'(tp)/real'(tp+fn) : 1.0;
        f1   = (prec+rec) > 0 ? 2.0*prec*rec/(prec+rec) : 1.0;
        $display("stage errs: scharr=%0d/%0d mag=%0d/%0d med=%0d/%0d nms=%0d/%0d",
                 e2,c2,e3,c3,e4,c4,e5,c5);
        $display("TP=%0d FP=%0d FN=%0d precision=%f recall=%f F1=%f",
                 tp, fp, fn, prec, rec, f1);

        fd = $fopen("out/rtl_output.hex", "w");
        for (y = 0; y < N; y = y + 1)
            $fwrite(fd, "%02X\n", rtlout[y]);
        $fclose(fd);

        if (errors == 0)
            $display("=== tb_canny: PASS (bit-exact vs golden, F1=%f) ===", f1);
        else
            $display("=== tb_canny: FAIL, %0d mismatched pixels, F1=%f ===",
                     errors, f1);
        $finish;
    end

    // 超时: 256 pass * 64*66 拍 裕量
    initial begin
        #50_000_000;
        $display("=== tb_canny: TIMEOUT (out_cnt=%0d busy=%b) ===", out_cnt, busy);
        $display("counts: g=%0d sc=%0d md=%0d me=%0d nm=%0d dt=%0d hphase=%0d capaddr=%0d",
                 c_g, c_sc, c_md, c_me, c_nm, c_dt, dut.u_hyst.phase, dut.u_hyst.cap_addr);
        $finish;
    end

endmodule
