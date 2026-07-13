// ============================================================================
// OV5640 数据捕获模块 - 100MHz 系统时钟过采样方式
//
// 原理(与 Xillinux OV7670 教程相同): PCLK 不当作时钟, 而是当作普通数据信号,
// 用系统时钟采样所有摄像头信号, 检测 PCLK 上升沿时消费一次数据。
// 要求 PCLK 频率 <= 系统时钟/8 左右 (本工程配置 PCLK 约 10MHz, 系统 100MHz)。
// 好处: 整个设计单时钟域, 无跨时钟域问题, PCLK 也无需接到时钟专用引脚。
//
// 下采样: 640x480 RGB565 -> 240x240
//   X: 取偶数列, 再裁掉左右各 40 列 (640/2=320 -> 240)
//   Y: 取偶数行 (480/2=240)
// ============================================================================
module ov5640_capture (
    input  wire        clk,           // 100MHz 系统时钟
    input  wire        rst_n,

    // 摄像头原始引脚 (异步)
    input  wire        pclk,
    input  wire        vsync,         // 高电平 = 帧间空白
    input  wire        href,          // 高电平 = 行数据有效
    input  wire [7:0]  data_in,

    // 帧缓存写口 (clk 域)
    output reg         wr_en,
    output reg  [16:0] wr_addr,       // 0..57599
    output reg  [15:0] wr_data,

    output reg         frame_tick,    // 每个 VSYNC 翻转一次 (原始活动指示)
    output reg         frame_ok_tick, // 每捕获到一个完整帧(≥57000像素)翻转一次

    // 滤波后的信号边沿脉冲 (供顶层做活动检测诊断)
    output wire        pclk_edge,
    output wire        vs_edge,
    output wire        hs_edge,       // 强去毛刺后的 HREF 上升沿
    output wire        hs_fast_edge,  // 快滤波的 HREF 上升沿 (对比毛刺率)

    // 最近一帧统计 (供 UART 诊断)
    output wire [9:0]  line_lat_o,
    output wire [16:0] wr_lat_o,
    output wire [9:0]  px_lat_o,
    output wire [7:0]  d_and_o,     // 一帧内所有字节按位与: 仍为1的位=该线从未变低(卡高)
    output wire [7:0]  d_or_o,      // 一帧内所有字节按位或: 仍为0的位=该线从未变高(卡低)

    output wire        cam_frame_start // 新帧首行到来脉冲 (供三缓冲 bank 切换)
);

// ============================================================================
// 输入同步 (第一级放 IOB, 后两级防亚稳态)
// ============================================================================
(* IOB = "TRUE" *) reg       pclk_i, vs_i, hs_i;
(* IOB = "TRUE" *) reg [7:0] d_i;
reg       pclk_s1, pclk_s2;
reg       vs_s1,   vs_s2;
reg       hs_s1,   hs_s2;
reg [7:0] d_s1;

// 数字滤波 (v7 分级):
//  - PCLK: 快滤波(连续2拍一致, 16ns) - 必须跟得上约10MHz的时钟
//  - HREF(像素门控): 快滤波, 与 PCLK/数据流水线对齐
//  - VSYNC / HREF(行计数): 强去毛刺(连续16拍一致, 128ns) -
//    帧/行同步是慢信号, 数据总线8根线同时翻转的串扰毛刺(几十ns)必须滤掉,
//    否则行计数器被毛刺打乱(帧中途复位/行数多跳), 表现为只有顶部被写入
reg       pclk_f, pclk_f_d;
reg       hs_fast, hs_fast_d;
reg       vs_slow, vs_slow_d;
reg       hs_slow, hs_slow_d;
reg [3:0] vs_dbc, hs_dbc;

always @(posedge clk) begin
    pclk_i  <= pclk;
    vs_i    <= vsync;
    hs_i    <= href;
    d_i     <= data_in;

    pclk_s1 <= pclk_i;
    vs_s1   <= vs_i;
    hs_s1   <= hs_i;
    d_s1    <= d_i;

    pclk_s2 <= pclk_s1;
    vs_s2   <= vs_s1;
    hs_s2   <= hs_s1;

    // 快滤波
    if (pclk_s1 == pclk_s2) pclk_f  <= pclk_s1;
    if (hs_s1   == hs_s2)   hs_fast <= hs_s1;
    pclk_f_d <= pclk_f;

    // 强去毛刺: 新电平须稳定16拍才被采纳
    if (vs_s1 != vs_slow) begin
        if (&vs_dbc) vs_slow <= vs_s1;
        vs_dbc <= vs_dbc + 1;
    end else
        vs_dbc <= 0;

    if (hs_s1 != hs_slow) begin
        if (&hs_dbc) hs_slow <= hs_s1;
        hs_dbc <= hs_dbc + 1;
    end else
        hs_dbc <= 0;

    vs_slow_d <= vs_slow;
    hs_slow_d <= hs_slow;
    hs_fast_d <= hs_fast;
end

wire pclk_rise = pclk_f  & ~pclk_f_d;    // 像素采样沿 (快)

// ---- v13 数据三点表决: PCLK上升沿后 +0/+2/+4 拍各采一次, 逐位2/3多数表决
// PCLK 6.95MHz 半周期约72ns(9拍), 三个采样点都落在稳定窗口内,
// 短于20ns的串扰毛刺最多污染一个采样点, 被表决淘汰
reg [7:0] d_h1, d_h2, d_h3, d_h4;
reg [3:0] pr_dly;
always @(posedge clk) begin
    d_h1 <= d_s1;
    d_h2 <= d_h1;
    d_h3 <= d_h2;
    d_h4 <= d_h3;
    pr_dly <= {pr_dly[2:0], pclk_rise};
end
// v19: PCLK 提速到约14MHz后数据窗口(36ns)容不下三点表决展开,
//      改回检测点单采样(pin信号约在沿后20ns, 窗口内); 线上毛刺已实测归零
wire       byte_ev = pclk_rise;
wire [7:0] d_vote  = d_s1;
wire vs_rise   = vs_slow & ~vs_slow_d;   // (仅供UART统计, v10起不再用于分帧)
wire hs_fall   = ~hs_slow & hs_slow_d;   // 行结束 (强去毛刺)
wire hs_rise_s = hs_slow & ~hs_slow_d;   // 行开始 (强去毛刺)

// ---- v10 分帧: 不再信任 VSYNC 线 (实测其信号为行频, 非帧同步) ----
// 垂直消隐期 HREF 静默约137ms, 行间隙仅约84us:
// HREF 低电平持续超过 2ms 即认定进入帧间隙, 其后第一个 HREF 上升沿 = 新帧首行
// v23: 0.5ms @ 125MHz — 介于 OV7670 行间隙(~11us)与帧间隙(~1.9ms)之间
localparam integer GAP_CYCLES = 62_500;
reg [17:0] hs_idle_cnt;
wire frame_gap = (hs_idle_cnt >= GAP_CYCLES[17:0]);
always @(posedge clk) begin
    if (hs_slow)
        hs_idle_cnt <= 0;
    else if (!frame_gap)
        hs_idle_cnt <= hs_idle_cnt + 1;
end
wire frame_start = hs_rise_s & frame_gap;
assign cam_frame_start = frame_start;

assign pclk_edge    = pclk_rise;
assign vs_edge      = vs_rise;
assign hs_edge      = hs_slow & ~hs_slow_d;
assign hs_fast_edge = hs_fast & ~hs_fast_d;

assign line_lat_o = line_lat;
assign wr_lat_o   = wr_lat;
assign px_lat_o   = px_lat;
assign d_and_o    = d_and_lat;
assign d_or_o     = d_or_lat;

// ============================================================================
// 像素重组与计数
// ============================================================================
reg        byte_sel;      // 0=等高字节, 1=等低字节
reg [7:0]  byte_hi;
reg [9:0]  px;            // 当前行内像素号 0..639
reg [9:0]  ln;            // 当前行号 0..479
reg [16:0] row_base;      // 当前行在帧缓存中的起始地址 ((ln/2)*240, 免乘法)
reg        synced;        // 已见过 VSYNC, 计数器有效
reg [16:0] wr_cnt;        // 本帧写入像素计数

// ---- v6 屏上诊断仪表 ----
reg [9:0]  line_cnt;      // 本帧 HREF 下降沿计数 (饱和到1023)
reg [9:0]  px_max;        // 本帧单行最大像素数
reg [9:0]  line_lat, px_lat;
reg [16:0] wr_lat;
reg [7:0]  d_and, d_or;         // 数据线逐位活动探针
reg [7:0]  d_and_lat, d_or_lat;
reg        paint_go, painting;
reg [7:0]  paint_x;
reg [4:0]  paint_row;     // 0..29 (3个仪表各10行, v8放大)
reg [16:0] paint_acc;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_en      <= 0;
        wr_addr    <= 0;
        wr_data    <= 0;
        byte_sel   <= 0;
        byte_hi    <= 0;
        px         <= 0;
        ln         <= 0;
        row_base   <= 0;
        synced     <= 0;
        frame_tick <= 0;
        wr_cnt     <= 0;
        frame_ok_tick <= 0;
        line_cnt   <= 0;
        px_max     <= 0;
        line_lat   <= 0;
        px_lat     <= 0;
        wr_lat     <= 0;
        paint_go   <= 0;
        painting   <= 0;
        paint_x    <= 0;
        paint_row  <= 0;
        paint_acc  <= 0;
    end else begin
        wr_en    <= 0;
        paint_go <= 0;

        // 新帧首行到来 (HREF 长静默后的第一个上升沿): 锁存统计 + 复位计数器
        if (frame_start) begin
            px         <= 0;
            ln         <= 0;
            row_base   <= 0;
            byte_sel   <= 0;
            synced     <= 1;
            frame_tick <= ~frame_tick;
            // 上一帧写入量达标才算有效帧 (v10: 阈值放宽, 行内像素暂偏少)
            if (wr_cnt >= 17'd20000)
                frame_ok_tick <= ~frame_ok_tick;
            // 锁存上一帧统计, 触发屏上仪表重绘
            line_lat <= line_cnt;
            px_lat   <= px_max;
            wr_lat   <= wr_cnt;
            d_and_lat <= d_and;
            d_or_lat  <= d_or;
            d_and    <= 8'hFF;
            d_or     <= 8'h00;
            paint_go <= 1'b0;    // v14: 屏上仪表停用(统计仍走UART), 整屏显示画面
            wr_cnt   <= 0;
            line_cnt <= 0;
            px_max   <= 0;
        end else begin
            // 行数据: 两字节拼一个 RGB565 像素
            // v11: 门控 = 快滤波 | 强滤波 — 行中的串扰毛刺只会在快路径上
            // 闪一下, 强滤波保持高电平, 门不断开, 不再丢字节
            // v13: byte_ev(延迟4拍) + d_vote(三点表决) 替代单点采样
            if (byte_ev && (hs_fast | hs_slow)) begin
                d_and <= d_and & d_vote;
                d_or  <= d_or  | d_vote;
                if (!byte_sel) begin
                    byte_hi  <= d_vote;
                    byte_sel <= 1;
                end else begin
                    byte_sel <= 0;
                    // 下采样: 偶数行、偶数列, 列窗口 [16,494]
                    if (synced && !ln[0] && !px[0] &&
                        px >= 10'd16 && px < 10'd496 && ln < 10'd480) begin
                        wr_en   <= 1;
                        wr_addr <= row_base + ((px - 10'd16) >> 1);
                        // v23: OV7670 RGB565 高字节先出, 直接高在前
                        wr_data <= {byte_hi, d_vote};
                        wr_cnt  <= wr_cnt + 1;
                    end
                    px <= px + 1;
                    if (px >= px_max)
                        px_max <= px + 1;
                end
            end

            // 行结束: 直接用 HREF 下降沿计数, 不依赖 PCLK
            // (兼容行间隙 PCLK 被门控停跳的模块)
            if (hs_fall) begin
                byte_sel <= 0;
                px       <= 0;
                if (ln[0])            // 刚结束的是奇数行 -> 下一偶数行基址+240
                    row_base <= row_base + 17'd240;
                ln <= ln + 1;
                if (~&line_cnt)
                    line_cnt <= line_cnt + 1;
            end
        end

        // ------------------------------------------------------------
        // 屏上仪表 (v8: 每仪表10行, 共占底部30行, 肉眼直读):
        //   紫 = 单行最大像素/4 (满宽=960, 正常640约2/3宽)
        //   青 = 帧写入像素/240 (满宽=57600完整帧)
        //   黄 = 两次VSYNC间行数/2 (满宽=480, 正常应满宽)
        // 放在块末尾, 与摄像头写冲突时以仪表为准 (绘制发生在帧空白期)
        // ------------------------------------------------------------
        if (paint_go) begin
            painting  <= 1;
            paint_x   <= 0;
            paint_row <= 0;
            paint_acc <= 0;
        end else if (painting) begin
            wr_en   <= 1;
            wr_addr <= 17'd50400 + paint_row * 8'd240 + paint_x;   // 起始 = 210*240
            wr_data <= (paint_row < 5'd10) ? ((paint_acc < {7'd0, px_lat})   ? 16'hF81F : 16'h2104)
                     : (paint_row < 5'd20) ? ((paint_acc < wr_lat)           ? 16'h07FF : 16'h2104)
                     :                       ((paint_acc < {7'd0, line_lat}) ? 16'hFFE0 : 16'h2104);
            paint_acc <= paint_acc + ((paint_row < 5'd10) ? 17'd4 :
                                      (paint_row < 5'd20) ? 17'd240 : 17'd2);
            if (paint_x == 8'd239) begin
                paint_x   <= 0;
                paint_acc <= 0;
                if (paint_row == 5'd29)
                    painting <= 0;
                else
                    paint_row <= paint_row + 1;
            end else begin
                paint_x <= paint_x + 1;
            end
        end
    end
end

endmodule
