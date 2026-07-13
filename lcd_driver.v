// ============================================================================
// LCD 驱动 - ST7789V 240x240, 4线 SPI
//
// 修复点(相对旧版):
//  - 增加硬件复位脚 lcd_res, 复位后按手册要求延时
//  - SLPOUT 后等 120ms 再发后续命令 (旧版无延时导致初始化失败)
//  - SDA 在 SCL 低电平期间更新, 上升沿前有半个 SPI 周期建立时间
//    (旧版 SDA 与 SCL 同沿翻转, 建立时间为 0)
//  - 不再依赖摄像头 pixel_valid 节拍, 而是自主从帧缓存读取, 持续刷屏
//
// SPI 12.5MHz (ST7789V 写周期规格 66ns 以内), 整屏刷新率约 13fps
// ============================================================================
module lcd_driver #(
    parameter CLK_FREQ = 100_000_000,
    parameter SPI_FREQ = 12_500_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // LCD 物理接口
    output reg         lcd_scl,
    output reg         lcd_sda,
    output reg         lcd_cs,
    output reg         lcd_dc,        // 0=命令 1=数据
    output reg         lcd_res,       // 低有效复位
    output reg         lcd_blk,       // 背光 (板上默认上拉, 驱动高即可)

    // 帧缓存读口
    output reg  [16:0] rd_addr,
    input  wire [15:0] rd_data,

    output reg         frame_done_o   // 一整屏刷新完成脉冲 (供三缓冲 bank 切换)
);

localparam integer SPI_HALF = CLK_FREQ / (SPI_FREQ * 2);
localparam integer MS       = CLK_FREQ / 1000;
localparam integer N_PIX    = 240 * 240;

// ============================================================================
// SPI 单字节发送引擎 (只管 SCL/SDA; CS/DC 由主状态机控制)
// 时序: CS已低 -> 装载数据并输出bit7 -> 半周期后SCL升 -> 半周期后SCL降+换位
// ============================================================================
reg        spi_go;
reg [7:0]  spi_byte;
reg        spi_busy;
reg        spi_done;
reg [2:0]  sbit;
reg [7:0]  sh;
reg [7:0]  scnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        spi_busy <= 0;
        spi_done <= 0;
        lcd_scl  <= 0;
        lcd_sda  <= 0;
        sbit     <= 0;
        sh       <= 0;
        scnt     <= 0;
    end else begin
        spi_done <= 0;
        if (!spi_busy) begin
            lcd_scl <= 0;
            if (spi_go) begin
                spi_busy <= 1;
                sh       <= spi_byte;
                lcd_sda  <= spi_byte[7];   // 提前放好第一位
                sbit     <= 3'd7;
                scnt     <= 0;
            end
        end else begin
            if (scnt == SPI_HALF - 1) begin
                scnt <= 0;
                if (!lcd_scl) begin
                    lcd_scl <= 1;          // 上升沿: 数据已稳定半个SPI周期
                end else begin
                    lcd_scl <= 0;          // 下降沿
                    if (sbit == 0) begin
                        spi_busy <= 0;
                        spi_done <= 1;
                    end else begin
                        sbit    <= sbit - 1;
                        sh      <= {sh[6:0], 1'b0};
                        lcd_sda <= sh[6];  // SCL低电平期间更新下一位
                    end
                end
            end else begin
                scnt <= scnt + 1;
            end
        end
    end
end

// ============================================================================
// 初始化命令表 {dc, 字节, 后置延时ms}
// ============================================================================
localparam N_INIT = 8;
function [17:0] init_rom(input [3:0] idx);
    case (idx)
        4'd0: init_rom = {1'b0, 8'h11, 9'd120};  // 退出睡眠, 等120ms
        4'd1: init_rom = {1'b0, 8'h3A, 9'd0};    // 像素格式
        4'd2: init_rom = {1'b1, 8'h55, 9'd0};    //   RGB565 16bit
        4'd3: init_rom = {1'b0, 8'h36, 9'd0};    // 扫描方向
        4'd4: init_rom = {1'b1, 8'h00, 9'd0};    //   正常方向
        4'd5: init_rom = {1'b0, 8'h21, 9'd0};    // 反显开 (这类IPS屏必需)
        4'd6: init_rom = {1'b0, 8'h13, 9'd10};   // 正常显示模式, 等10ms
        4'd7: init_rom = {1'b0, 8'h29, 9'd10};   // 开显示, 等10ms
        default: init_rom = 18'd0;
    endcase
endfunction

// 窗口设置 + 写显存命令 (0,0)-(239,239)
localparam N_WIN = 11;
function [8:0] win_rom(input [3:0] idx);
    case (idx)
        4'd0:  win_rom = {1'b0, 8'h2A};  // 列地址
        4'd1:  win_rom = {1'b1, 8'h00};
        4'd2:  win_rom = {1'b1, 8'h00};
        4'd3:  win_rom = {1'b1, 8'h00};
        4'd4:  win_rom = {1'b1, 8'hEF};  // 239
        4'd5:  win_rom = {1'b0, 8'h2B};  // 行地址
        4'd6:  win_rom = {1'b1, 8'h00};
        4'd7:  win_rom = {1'b1, 8'h00};
        4'd8:  win_rom = {1'b1, 8'h00};
        4'd9:  win_rom = {1'b1, 8'hEF};  // 239
        4'd10: win_rom = {1'b0, 8'h2C};  // 写显存
        default: win_rom = 9'd0;
    endcase
endfunction

// ============================================================================
// 主状态机
// ============================================================================
localparam M_RES_LOW   = 4'd0;   // 复位脚拉低 20ms

localparam M_RES_HIGH  = 4'd1;   // 复位释放后等 150ms
localparam M_INIT_SEND = 4'd2;
localparam M_INIT_WAIT = 4'd3;
localparam M_INIT_DLY  = 4'd4;
localparam M_WIN_SEND  = 4'd5;
localparam M_WIN_WAIT  = 4'd6;
localparam M_PREFETCH0 = 4'd7;   // 预取第一个像素
localparam M_PREFETCH1 = 4'd8;
localparam M_PREFETCH2 = 4'd9;
localparam M_PX_HI     = 4'd10;
localparam M_PX_HI_W   = 4'd11;
localparam M_PX_LO     = 4'd12;
localparam M_PX_LO_W   = 4'd13;

reg [3:0]  state;
reg [3:0]  rom_idx;
reg [25:0] delay_cnt;
reg [16:0] pix;
reg [15:0] cur_px;

// Verilog-2001 不允许对函数调用结果直接位选, 先落到 wire
wire [17:0] init_entry = init_rom(rom_idx);
wire [8:0]  win_entry  = win_rom(rom_idx);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= M_RES_LOW;
        lcd_cs    <= 1;
        lcd_dc    <= 1;
        lcd_res   <= 0;
        lcd_blk   <= 0;
        spi_go    <= 0;
        spi_byte  <= 0;
        rom_idx   <= 0;
        rd_addr   <= 0;
        pix       <= 0;
        cur_px    <= 0;
        delay_cnt <= 26'd20 * MS;
        frame_done_o <= 0;
    end else begin
        spi_go       <= 0;
        frame_done_o <= 0;

        case (state)
            // ---- 硬件复位 ----
            M_RES_LOW: begin
                lcd_res <= 0;
                lcd_cs  <= 1;
                if (delay_cnt != 0)
                    delay_cnt <= delay_cnt - 1;
                else begin
                    lcd_res   <= 1;
                    delay_cnt <= 26'd150 * MS;
                    state     <= M_RES_HIGH;
                end
            end

            M_RES_HIGH: begin
                if (delay_cnt != 0)
                    delay_cnt <= delay_cnt - 1;
                else begin
                    lcd_blk <= 1;         // 开背光
                    rom_idx <= 0;
                    state   <= M_INIT_SEND;
                end
            end

            // ---- 初始化序列 ----
            M_INIT_SEND: begin
                lcd_cs   <= 0;
                lcd_dc   <= init_entry[17];
                spi_byte <= init_entry[16:9];
                spi_go   <= 1;
                state    <= M_INIT_WAIT;
            end

            M_INIT_WAIT: begin
                if (spi_done) begin
                    if (init_entry[8:0] != 0) begin
                        lcd_cs    <= 1;
                        delay_cnt <= init_entry[8:0] * MS;
                        state     <= M_INIT_DLY;
                    end else begin
                        if (rom_idx == N_INIT-1) begin
                            rom_idx <= 0;
                            state   <= M_WIN_SEND;
                        end else begin
                            rom_idx <= rom_idx + 1;
                            state   <= M_INIT_SEND;
                        end
                    end
                end
            end

            M_INIT_DLY: begin
                if (delay_cnt != 0)
                    delay_cnt <= delay_cnt - 1;
                else begin
                    if (rom_idx == N_INIT-1) begin
                        rom_idx <= 0;
                        state   <= M_WIN_SEND;
                    end else begin
                        rom_idx <= rom_idx + 1;
                        state   <= M_INIT_SEND;
                    end
                end
            end

            // ---- 每帧: 设置窗口 + 写显存命令 ----
            M_WIN_SEND: begin
                lcd_cs   <= 0;
                lcd_dc   <= win_entry[8];
                spi_byte <= win_entry[7:0];
                spi_go   <= 1;
                state    <= M_WIN_WAIT;
            end

            M_WIN_WAIT: begin
                if (spi_done) begin
                    if (rom_idx == N_WIN-1) begin
                        rom_idx <= 0;
                        state   <= M_PREFETCH0;
                    end else begin
                        rom_idx <= rom_idx + 1;
                        state   <= M_WIN_SEND;
                    end
                end
            end

            // ---- 预取像素0 (BRAM 读延迟1拍) ----
            M_PREFETCH0: begin
                rd_addr <= 0;
                state   <= M_PREFETCH1;
            end
            M_PREFETCH1: state <= M_PREFETCH2;   // 等 rd_data 有效
            M_PREFETCH2: begin
                cur_px  <= rd_data;
                rd_addr <= 17'd1;                // 预取下一个
                pix     <= 0;
                state   <= M_PX_HI;
            end

            // ---- 像素流: 每像素两个字节, 高字节在前 ----
            M_PX_HI: begin
                lcd_dc   <= 1;
                spi_byte <= cur_px[15:8];
                spi_go   <= 1;
                state    <= M_PX_HI_W;
            end
            M_PX_HI_W: if (spi_done) state <= M_PX_LO;

            M_PX_LO: begin
                spi_byte <= cur_px[7:0];
                spi_go   <= 1;
                state    <= M_PX_LO_W;
            end
            M_PX_LO_W: begin
                if (spi_done) begin
                    cur_px  <= rd_data;          // 已稳定的下一像素
                    rd_addr <= pix + 17'd2;      // 再预取一个
                    if (pix == N_PIX-1) begin
                        lcd_cs       <= 1;       // 一帧结束, 回去重设窗口
                        frame_done_o <= 1;       // 通知顶层可切换显示 bank
                        state        <= M_WIN_SEND;
                    end else begin
                        pix   <= pix + 1;
                        state <= M_PX_HI;
                    end
                end
            end

            default: state <= M_RES_LOW;
        endcase
    end
end

endmodule
