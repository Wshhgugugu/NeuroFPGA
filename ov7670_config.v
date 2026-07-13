// ============================================================================
// OV7670 配置模块 (v23) - SCCB 三段式写(8位寄存器地址), 器件地址 0x21
// 输出: VGA RGB565, CLKRC 内部分频使 PCLK 降到过采样友好速度
// 上电时序与 ov5640_config 相同: RST低10ms -> 释放等30ms -> 写表
// 表内 0xFE=延时(数据=毫秒), 0xFF=结束
// ============================================================================
module ov7670_config #(
    parameter CLK_FREQ = 125_000_000
)(
    input  wire clk,
    input  wire rst_n,
    output wire scl,
    inout  wire sda,
    output reg  cam_rst_n,
    output reg  cam_pwdn,
    output reg  done,
    output wire cfg_ack_err
);

localparam integer MS_CYCLES = CLK_FREQ / 1000;

function [15:0] cfg_rom(input [7:0] idx);
    case (idx)
        8'd0:  cfg_rom = {8'h12, 8'h80};  // COM7: 复位全部寄存器
        8'd1:  cfg_rom = {8'hFE, 8'h0A};  // 延时10ms
        8'd2:  cfg_rom = {8'h12, 8'h04};  // COM7: RGB 输出(VGA默认)
        8'd3:  cfg_rom = {8'h11, 8'h01};  // CLKRC: 内部时钟 = XCLK/2 = 12.5MHz -> PCLK 12.5MHz
        8'd4:  cfg_rom = {8'h0C, 8'h00};  // COM3
        8'd5:  cfg_rom = {8'h3E, 8'h00};  // COM14
        8'd6:  cfg_rom = {8'h40, 8'hD0};  // COM15: RGB565 + 全量程 00-FF
        8'd7:  cfg_rom = {8'h3A, 8'h04};  // TSLB: 输出字节序
        8'd8:  cfg_rom = {8'h8C, 8'h00};  // RGB444 关闭
        // ---- 教程补充篇实测必需的三个寄存器 (颜色/白平衡) ----
        8'd9:  cfg_rom = {8'h3D, 8'h88};  // COM13: gamma使能 + UV自动 (RGB模式用0x88)
        8'd10: cfg_rom = {8'hB0, 8'h84};  // 保留寄存器, 教程证明必需
        8'd11: cfg_rom = {8'h6F, 8'h9F};  // AWBCTR0: 高级AWB, 否则白平衡异常
        // ---- 驱动电流降到 1x: 直接压制杜邦线串扰 (教程明确提到) ----
        8'd12: cfg_rom = {8'h09, 8'h00};  // COM2
        // ---- 基本增益/曝光自动 ----
        8'd13: cfg_rom = {8'h13, 8'hE7};  // COM8: AGC/AWB/AEC 全自动
        8'd14: cfg_rom = {8'h1E, 8'h01};  // MVFP: 不镜像不翻转(如上下颠倒改0x11)
        default: cfg_rom = {8'hFF, 8'hFF};
    endcase
endfunction

reg        i2c_start;
wire       i2c_done;
reg  [7:0] rom_idx;
wire [15:0] rom_entry = cfg_rom(rom_idx);

i2c_master #(
    .CLK_FREQ(CLK_FREQ),
    .I2C_FREQ(100_000),
    .ADDR16  (0)
) u_i2c (
    .clk(clk), .rst_n(rst_n), .scl(scl), .sda(sda),
    .start(i2c_start),
    .slave_addr(7'h21),
    .reg_addr({8'h00, rom_entry[15:8]}),
    .wr_data(rom_entry[7:0]),
    .busy(), .done(i2c_done), .ack_err(cfg_ack_err)
);

localparam S_RST_LOW=3'd0, S_RST_WAIT=3'd1, S_CHECK=3'd2,
           S_I2C_WAIT=3'd3, S_DELAY=3'd4, S_DONE=3'd5;
reg [2:0]  state;
reg [25:0] delay_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_RST_LOW; cam_rst_n <= 0; cam_pwdn <= 0;
        done <= 0; i2c_start <= 0; rom_idx <= 0;
        delay_cnt <= 26'd10 * MS_CYCLES;
    end else begin
        i2c_start <= 0;
        case (state)
            S_RST_LOW:  if (delay_cnt != 0) delay_cnt <= delay_cnt - 1;
                        else begin cam_rst_n <= 1; delay_cnt <= 26'd30*MS_CYCLES; state <= S_RST_WAIT; end
            S_RST_WAIT: if (delay_cnt != 0) delay_cnt <= delay_cnt - 1;
                        else state <= S_CHECK;
            S_CHECK:    if (rom_entry[15:8] == 8'hFF) state <= S_DONE;
                        else if (rom_entry[15:8] == 8'hFE) begin
                            delay_cnt <= rom_entry[7:0] * MS_CYCLES; state <= S_DELAY;
                        end else begin i2c_start <= 1; state <= S_I2C_WAIT; end
            S_I2C_WAIT: if (i2c_done) begin rom_idx <= rom_idx + 1; state <= S_CHECK; end
            S_DELAY:    if (delay_cnt != 0) delay_cnt <= delay_cnt - 1;
                        else begin rom_idx <= rom_idx + 1; state <= S_CHECK; end
            S_DONE:     done <= 1;
            default:    state <= S_DONE;
        endcase
    end
end

endmodule
