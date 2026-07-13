// ============================================================================
// OV5640 摄像头 + 板载LCD 显示 顶层模块 (Smart Zynq SP2, XC7Z020-CLG484)
//
// 时钟方案: 板载 50MHz (M19) -> PLL -> 125MHz 系统时钟 (v5b)
// 数据通路: OV5640 (VGA RGB565, 0x3035=0x81 全局/8 降速, 125MHz过采样PCLK)
//           -> 下采样 240x240 -> BRAM帧缓存 -> ST7789V SPI LCD
// 全部逻辑在 125MHz 单时钟域, 无跨时钟域问题
//
// LED 语义见文件末尾 "调试 LED" 段注释 (KEY2 切换两页)
// 上电后 LCD 先显示彩条(帧缓存初始化图案), 摄像头出图后被替换
// ============================================================================
module test_camera_lcd (
    input  wire        clk,           // 50MHz 板载晶振 (M19)
    input  wire        rst_n,         // KEY1 (K21), 按下复位
    input  wire        key2,          // KEY2 (J20), 按住切换LED诊断页

    // OV5640 接口 (Bank33 排针)
    input  wire        pclk,          // 像素时钟(当数据采样, 非时钟引脚)
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  data_in,
    output wire        xclk,          // 25MHz 备用主时钟 (排针11, 模块NC脚)
    output wire        ov5640_rst,    // 复位, 低有效
    output wire        ov5640_pwdn,   // 掉电, 高有效
    output wire        scl,
    inout  wire        sda,

    // 板载 LCD (ST7789V 240x240)
    output wire        lcd_scl,
    output wire        lcd_sda,
    output wire        lcd_cs,
    output wire        lcd_dc,
    output wire        lcd_res,
    output wire        lcd_blk,

    // 调试 LED
    output wire [1:0]  led,

    // UART 诊断输出 (FT2232 通道B, 115200 8N1)
    output wire        uart_txd
);

// ============================================================================
// PLL: 50MHz -> 125MHz 系统时钟
// (v5b: 200MHz 在 -1 速度等级时序不收敛, 降为 125MHz;
//  过采样能力约 PCLK<=20MHz, 配合摄像头 0x3035=0x81 /8 降速余量充足)
// ============================================================================
wire clk_fb, clk_sys_raw, clk25_raw;
wire clk_sys, clk25;
wire pll_locked;

localparam integer SYS_FREQ = 125_000_000;

PLLE2_BASE #(
    .CLKIN1_PERIOD (20.000),
    .DIVCLK_DIVIDE (1),
    .CLKFBOUT_MULT (20),        // VCO = 1000MHz
    .CLKOUT0_DIVIDE(8),         // 125MHz 系统时钟
    .CLKOUT1_DIVIDE(40)         // 25MHz OV7670 XCLK
) u_pll (
    .CLKIN1  (clk),
    .CLKFBIN (clk_fb),
    .CLKFBOUT(clk_fb),
    .CLKOUT0 (clk_sys_raw),
    .CLKOUT1 (clk25_raw),
    .CLKOUT2 (),
    .CLKOUT3 (),
    .CLKOUT4 (),
    .CLKOUT5 (),
    .LOCKED  (pll_locked),
    .RST     (1'b0),
    .PWRDWN  (1'b0)
);

BUFG u_bufg_sys (.I(clk_sys_raw), .O(clk_sys));
BUFG u_bufg25   (.I(clk25_raw),   .O(clk25));

// XCLK: OV7670 无晶振, FPGA 输出 25MHz 主时钟 (ODDR 干净转发到 IO)
ODDR #(
    .DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")
) u_oddr_xclk (
    .Q(xclk), .C(clk25), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
);

// ============================================================================
// 复位: PLL 锁定 + 按键(同步后) + 上电计数
// ============================================================================
reg [1:0]  key_sync = 2'b11;
reg [15:0] por_cnt  = 16'd0;
wire       sys_rst_n = por_cnt[15];

always @(posedge clk_sys) begin
    key_sync <= {key_sync[0], rst_n};
    if (!pll_locked || !key_sync[1])
        por_cnt <= 16'd0;
    else if (!sys_rst_n)
        por_cnt <= por_cnt + 1;
end

// ============================================================================
// OV7670 上电时序 + SCCB 配置 (v23: 换用 OV7670)
// ============================================================================
wire cfg_done;
wire cfg_ack_err;

ov7670_config #(
    .CLK_FREQ(SYS_FREQ)
) u_config (
    .clk        (clk_sys),
    .rst_n      (sys_rst_n),
    .scl        (scl),
    .sda        (sda),
    .cam_rst_n  (ov5640_rst),
    .cam_pwdn   (ov5640_pwdn),
    .done       (cfg_done),
    .cfg_ack_err(cfg_ack_err)
);

// ============================================================================
// 摄像头捕获 (过采样) -> 帧缓存
// ============================================================================
wire        wr_en;
wire [16:0] cap_wr_addr;    // 帧内偏移 0..57599
wire [15:0] wr_data;
wire        frame_tick;
wire        frame_ok_tick;
wire        cam_frame_start;

wire pclk_edge, vs_edge, hs_edge, hs_fast_edge;
wire [9:0]  line_lat_o, px_lat_o;
wire [16:0] wr_lat_o;
wire [7:0]  d_and_o, d_or_o;

ov5640_capture u_capture (
    .clk          (clk_sys),
    .rst_n        (sys_rst_n),
    .pclk         (pclk),
    .vsync        (vsync),
    .href         (href),
    .data_in      (data_in),
    .wr_en        (wr_en),
    .wr_addr      (cap_wr_addr),
    .wr_data      (wr_data),
    .frame_tick   (frame_tick),
    .frame_ok_tick(frame_ok_tick),
    .pclk_edge    (pclk_edge),
    .vs_edge      (vs_edge),
    .hs_edge      (hs_edge),
    .hs_fast_edge (hs_fast_edge),
    .line_lat_o   (line_lat_o),
    .wr_lat_o     (wr_lat_o),
    .px_lat_o     (px_lat_o),
    .d_and_o      (d_and_o),
    .d_or_o       (d_or_o),
    .cam_frame_start(cam_frame_start)
);

// ============================================================================
// 三缓冲 bank 管理器 (全部在 clk_sys 单时钟域, 无 CDC)
//   摄像头写 wr_idx, LCD 读 rd_idx, 第三块空闲。各自只在本方帧边界切换指针,
//   -> LCD 扫描途中读 bank 永不改变 = 零撕裂
// ============================================================================
reg  [1:0] wr_idx   = 2'd0;
reg  [1:0] rd_idx   = 2'd1;
reg  [1:0] done_idx = 2'd0;
reg        wr_tgl   = 1'b0;   // 摄像头每完成一帧翻转
reg        lcd_seen = 1'b0;   // LCD 已消费到的 wr_tgl

wire       lcd_frame_done;
wire [16:0] lcd_rd_addr;
wire [15:0] rd_data;

// bank 基址 (免乘法): 0 / 57600 / 115200
function [17:0] bank_base(input [1:0] idx);
    case (idx)
        2'd0:    bank_base = 18'd0;
        2'd1:    bank_base = 18'd57600;
        default: bank_base = 18'd115200;
    endcase
endfunction

// 摄像头侧: 新帧开始时发布刚写完的 bank, 切到空闲 bank(既非在读也非刚写完)
always @(posedge clk_sys) begin
    if (!sys_rst_n) begin
        wr_idx <= 2'd0; done_idx <= 2'd0; wr_tgl <= 1'b0;
    end else if (cam_frame_start) begin
        done_idx <= wr_idx;
        wr_tgl   <= ~wr_tgl;
        wr_idx   <= 2'd3 - wr_idx - rd_idx;   // 三块中剩下的那块
    end
end

// LCD 侧: 每刷完一整屏, 若有新帧就切到最新完成的 bank
always @(posedge clk_sys) begin
    if (!sys_rst_n) begin
        rd_idx <= 2'd1; lcd_seen <= 1'b0;
    end else if (lcd_frame_done) begin
        if (wr_tgl != lcd_seen) begin
            rd_idx   <= done_idx;
            lcd_seen <= wr_tgl;
        end
    end
end

wire [17:0] fb_wr_addr = bank_base(wr_idx) + {1'b0, cap_wr_addr};
wire [17:0] fb_rd_addr = bank_base(rd_idx) + {1'b0, lcd_rd_addr};

frame_buffer u_fb (
    .clk    (clk_sys),
    .wr_en  (wr_en),
    .wr_addr(fb_wr_addr),
    .wr_data(wr_data),
    .rd_addr(fb_rd_addr),
    .rd_data(rd_data)
);

// ============================================================================
// LCD 驱动 (独立初始化, 持续刷屏)
// ============================================================================
lcd_driver #(
    .CLK_FREQ(SYS_FREQ),
    .SPI_FREQ(12_500_000)
) u_lcd (
    .clk    (clk_sys),
    .rst_n  (sys_rst_n),
    .lcd_scl(lcd_scl),
    .lcd_sda(lcd_sda),
    .lcd_cs (lcd_cs),
    .lcd_dc (lcd_dc),
    .lcd_res(lcd_res),
    .lcd_blk(lcd_blk),
    .rd_addr(lcd_rd_addr),
    .rd_data(rd_data),
    .frame_done_o(lcd_frame_done)
);

// ============================================================================
// 调试 LED (v5: KEY2 切换两个诊断页)
//
// 【第1页 = KEY2 不按】
//   LED1: 亮 = I2C 配置完成且全部 ACK; 灭 = 有 NACK
//   LED2: 慢闪 = 完整帧流动中; 常亮 = 有VSYNC但凑不满帧; 灭 = 无VSYNC
// 【第2页 = 按住 KEY2】
//   LED1: 按 VSYNC 频率翻转 (肉眼可见闪 = 帧率已降下来; 看似常亮 = 帧率过快)
//   LED2: 亮 = HREF 线上有活动
// ============================================================================
reg [1:0] key2_sync = 2'b11;
always @(posedge clk_sys) key2_sync <= {key2_sync[0], key2};
wire diag_page = ~key2_sync[1];    // 按下(低电平)= 第2页

// 信号活动检测: 出现边沿后点亮 0.3s (单稳态)
localparam ACT_HOLD = 26'd37_500_000;   // 0.3s @ 125MHz
reg [25:0] vs_act_cnt, hs_act_cnt;
always @(posedge clk_sys) begin
    if (vs_edge)              vs_act_cnt   <= ACT_HOLD;
    else if (|vs_act_cnt)     vs_act_cnt   <= vs_act_cnt - 1;
    if (hs_edge)              hs_act_cnt   <= ACT_HOLD;
    else if (|hs_act_cnt)     hs_act_cnt   <= hs_act_cnt - 1;
end
wire vs_active   = |vs_act_cnt;
wire hs_active   = |hs_act_cnt;

// "完整帧最近1秒内出现过" 检测
reg        fok_d;
reg [27:0] fok_cnt;
always @(posedge clk_sys) begin
    fok_d <= frame_ok_tick;
    if (fok_d ^ frame_ok_tick) fok_cnt <= 28'd125_000_000;   // 1s @ 125MHz
    else if (|fok_cnt)         fok_cnt <= fok_cnt - 1;
end
wire frames_flowing = |fok_cnt;

assign led[0] = diag_page ? frame_tick
                          : (cfg_done & ~cfg_ack_err);
assign led[1] = diag_page ? hs_active
                          : (frames_flowing ? frame_ok_tick : vs_active);

// ============================================================================
// v9: UART 每秒诊断报文 (115200 8N1)
// 格式: 7个字段, 每字段8位HEX, 空格分隔, CRLF结尾:
//   [0] VSYNC 沿/秒  [1] HREF(强滤波) 沿/秒  [2] HREF(快滤波) 沿/秒
//   [3] PCLK 沿/秒(=实测PCLK频率Hz)  [4] 帧内行数  [5] 帧写入像素  [6] 单行最大像素
// ============================================================================
reg [26:0]  sec_cnt;
reg [15:0]  vs_c, hs_c;
reg [23:0]  hf_c;
reg [27:0]  p_c;
reg [223:0] msg;
reg         snap;

always @(posedge clk_sys) begin
    snap <= 0;
    if (!sys_rst_n) begin
        sec_cnt <= 0;
        vs_c <= 0; hs_c <= 0; hf_c <= 0; p_c <= 0;
    end else begin
        if (vs_edge)      vs_c <= vs_c + 1;
        if (hs_edge)      hs_c <= hs_c + 1;
        if (hs_fast_edge) hf_c <= hf_c + 1;
        if (pclk_edge)    p_c  <= p_c  + 1;
        if (sec_cnt == 27'd124_999_999) begin
            sec_cnt <= 0;
            // v16: 字段0 改为数据线探针 {AND字节, OR字节} (原VSYNC计数已无用)
            msg  <= {{16'd0, d_and_o, d_or_o}, {16'd0, hs_c}, {8'd0, hf_c}, {4'd0, p_c},
                     {22'd0, line_lat_o}, {15'd0, wr_lat_o}, {22'd0, px_lat_o}};
            snap <= 1;
            vs_c <= 0; hs_c <= 0; hf_c <= 0; p_c <= 0;
        end else begin
            sec_cnt <= sec_cnt + 1;
        end
    end
end

function [7:0] hex2asc(input [3:0] n);
    hex2asc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
endfunction

wire       tx_busy;
reg  [7:0] tx_data;
reg        tx_send;

localparam PR_IDLE = 2'd0, PR_HEX = 2'd1, PR_SEP = 2'd2;
reg [1:0] pr_st;
reg [2:0] pf;      // 字段 0..6
reg [2:0] pn;      // 半字节 0(高)..7(低)
reg       crlf;
wire [8:0] nib_pos = 9'd220 - {pf, 5'd0} - {pn, 2'd0};   // 223-pf*32-pn*4-3 的起始位

always @(posedge clk_sys) begin
    if (!sys_rst_n) begin
        pr_st <= PR_IDLE; pf <= 0; pn <= 0; crlf <= 0;
        tx_send <= 0; tx_data <= 0;
    end else begin
        tx_send <= 0;
        case (pr_st)
            PR_IDLE: if (snap) begin
                pf <= 0; pn <= 0; crlf <= 0;
                pr_st <= PR_HEX;
            end

            PR_HEX: if (!tx_busy && !tx_send) begin
                tx_data <= hex2asc(msg[nib_pos +: 4]);
                tx_send <= 1;
                if (pn == 3'd7) begin
                    pn    <= 0;
                    pr_st <= PR_SEP;
                end else begin
                    pn <= pn + 1;
                end
            end

            PR_SEP: if (!tx_busy && !tx_send) begin
                if (pf == 3'd6) begin
                    if (!crlf) begin
                        tx_data <= 8'h0D; tx_send <= 1; crlf <= 1;
                    end else begin
                        tx_data <= 8'h0A; tx_send <= 1; pr_st <= PR_IDLE;
                    end
                end else begin
                    tx_data <= 8'h20; tx_send <= 1;
                    pf <= pf + 1; pr_st <= PR_HEX;
                end
            end

            default: pr_st <= PR_IDLE;
        endcase
    end
end

uart_tx #(
    .CLK_FREQ(SYS_FREQ),
    .BAUD(115_200)
) u_uart (
    .clk  (clk_sys),
    .rst_n(sys_rst_n),
    .data (tx_data),
    .send (tx_send),
    .busy (tx_busy),
    .txd  (uart_txd)
);

endmodule
