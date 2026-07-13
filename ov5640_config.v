// ============================================================================
// OV5640 配置模块
//  1. 控制摄像头上电时序: PWDN=0, RST 拉低 10ms 后释放, 再等 30ms
//  2. 通过 I2C(SCCB) 写入寄存器表: VGA 640x480, RGB565, 低速 PCLK
//
// 寄存器表说明:
//  - 基于广泛使用的 OV5640 DVP RGB565 VGA 配置
//  - 0x3035 = 0x51 (系统分频 /5): 帧率约 6fps, PCLK 降到 ~10MHz,
//    保证 100MHz 系统时钟过采样可靠。想加速可改 0x21 (/2, ~15fps)
//  - 表中 16'hFFFE 表示延时(数据字段=毫秒数), 16'hFFFF 表示结束
// ============================================================================
module ov5640_config #(
    parameter CLK_FREQ = 100_000_000
)(
    input  wire clk,
    input  wire rst_n,

    // I2C 接口
    output wire scl,
    inout  wire sda,

    // 摄像头复位/电源控制
    output reg  cam_rst_n,     // 低有效复位
    output reg  cam_pwdn,      // 高有效掉电

    output reg  done,          // 配置完成, 保持高电平
    output wire cfg_ack_err    // I2C 曾出现 NACK (调试用)
);

localparam integer MS_CYCLES = CLK_FREQ / 1000;   // 1ms 周期数

// ============================================================================
// 寄存器表 (函数式 ROM)
// ============================================================================
function [23:0] cfg_rom(input [7:0] idx);
    case (idx)
        // ---- 复位与时钟源 ----
        8'd0:   cfg_rom = {16'h3103, 8'h11};  // 系统时钟来自晶振
        8'd1:   cfg_rom = {16'h3008, 8'h82};  // 软件复位
        8'd2:   cfg_rom = {16'hFFFE, 8'h0A};  // 延时 10ms
        8'd3:   cfg_rom = {16'h3008, 8'h42};  // 掉电模式(配置期间)
        8'd4:   cfg_rom = {16'h3103, 8'h03};  // 系统时钟来自PLL
        8'd5:   cfg_rom = {16'h3017, 8'hFF};  // IO输出使能
        8'd6:   cfg_rom = {16'h3018, 8'hFF};  // IO输出使能
        // ---- PLL: XVCLK 24MHz -> 低速输出 ----
        8'd7:   cfg_rom = {16'h3034, 8'h1A};
        // v22: 回到 /4 (PCLK约14MHz)。v21实验证明 0x3824 分频比不能超过2
        //   (行时序预算溢出会停DVP), "内部快输出慢"不可行; /4 下曾观察到
        //   晃动摄像头画面变化 => 疑似模拟读出在 /4 已复活, 本版做光学验证
        8'd8:   cfg_rom = {16'h3035, 8'h41};
        8'd9:   cfg_rom = {16'h3036, 8'h46};  // PLL 倍频 70
        8'd10:  cfg_rom = {16'h3037, 8'h13};  // 预分频/3, 根分频/2
        8'd11:  cfg_rom = {16'h3108, 8'h01};  // 时钟根分频
        // ---- 模拟/内核控制 (厂商推荐值) ----
        8'd12:  cfg_rom = {16'h3630, 8'h36};
        8'd13:  cfg_rom = {16'h3631, 8'h0E};
        8'd14:  cfg_rom = {16'h3632, 8'hE2};
        8'd15:  cfg_rom = {16'h3633, 8'h12};
        8'd16:  cfg_rom = {16'h3621, 8'hE0};
        8'd17:  cfg_rom = {16'h3704, 8'hA0};
        8'd18:  cfg_rom = {16'h3703, 8'h5A};
        8'd19:  cfg_rom = {16'h3715, 8'h78};
        8'd20:  cfg_rom = {16'h3717, 8'h01};
        8'd21:  cfg_rom = {16'h370B, 8'h60};
        8'd22:  cfg_rom = {16'h3705, 8'h1A};
        8'd23:  cfg_rom = {16'h3905, 8'h02};
        8'd24:  cfg_rom = {16'h3906, 8'h10};
        8'd25:  cfg_rom = {16'h3901, 8'h0A};
        8'd26:  cfg_rom = {16'h3731, 8'h12};
        8'd27:  cfg_rom = {16'h3600, 8'h08};
        8'd28:  cfg_rom = {16'h3601, 8'h33};
        8'd29:  cfg_rom = {16'h302D, 8'h60};
        8'd30:  cfg_rom = {16'h3620, 8'h52};
        8'd31:  cfg_rom = {16'h371B, 8'h20};
        8'd32:  cfg_rom = {16'h471C, 8'h50};
        8'd33:  cfg_rom = {16'h3A13, 8'h43};
        8'd34:  cfg_rom = {16'h3A18, 8'h00};
        8'd35:  cfg_rom = {16'h3A19, 8'hF8};
        8'd36:  cfg_rom = {16'h3635, 8'h13};
        8'd37:  cfg_rom = {16'h3636, 8'h03};
        8'd38:  cfg_rom = {16'h3634, 8'h40};
        8'd39:  cfg_rom = {16'h3622, 8'h01};
        // ---- 50/60Hz 光带检测 ----
        8'd40:  cfg_rom = {16'h3C01, 8'hA4};  // v18: 对齐Linux驱动权威值(原0x34错)
        8'd41:  cfg_rom = {16'h3C04, 8'h28};
        8'd42:  cfg_rom = {16'h3C05, 8'h98};
        8'd43:  cfg_rom = {16'h3C06, 8'h00};
        8'd44:  cfg_rom = {16'h3C07, 8'h08};
        8'd45:  cfg_rom = {16'h3C08, 8'h00};
        8'd46:  cfg_rom = {16'h3C09, 8'h1C};
        8'd47:  cfg_rom = {16'h3C0A, 8'h9C};
        8'd48:  cfg_rom = {16'h3C0B, 8'h40};
        // ---- 采样/镜像: 2x2 binning, VGA ----
        8'd49:  cfg_rom = {16'h3820, 8'h41};  // 垂直: binning (bit1翻转,如需上下翻转改0x47)
        8'd50:  cfg_rom = {16'h3821, 8'h07};  // 水平: 镜像+binning (不要镜像改0x01)
        8'd51:  cfg_rom = {16'h3814, 8'h31};  // X 隔行采样
        8'd52:  cfg_rom = {16'h3815, 8'h31};  // Y 隔行采样
        // ---- 传感器窗口 (全幅 2624x1948) ----
        8'd53:  cfg_rom = {16'h3800, 8'h00};
        8'd54:  cfg_rom = {16'h3801, 8'h00};
        8'd55:  cfg_rom = {16'h3802, 8'h00};
        8'd56:  cfg_rom = {16'h3803, 8'h04};
        8'd57:  cfg_rom = {16'h3804, 8'h0A};
        8'd58:  cfg_rom = {16'h3805, 8'h3F};
        8'd59:  cfg_rom = {16'h3806, 8'h07};
        8'd60:  cfg_rom = {16'h3807, 8'h9B};
        // ---- 输出尺寸 640x480 ----
        8'd61:  cfg_rom = {16'h3808, 8'h02};
        8'd62:  cfg_rom = {16'h3809, 8'h80};
        8'd63:  cfg_rom = {16'h380A, 8'h01};
        8'd64:  cfg_rom = {16'h380B, 8'hE0};
        // ---- 总行长/总帧长 ----
        8'd65:  cfg_rom = {16'h380C, 8'h07};
        8'd66:  cfg_rom = {16'h380D, 8'h68};  // HTS = 1896
        8'd67:  cfg_rom = {16'h380E, 8'h03};
        8'd68:  cfg_rom = {16'h380F, 8'hD8};  // VTS = 984
        // ---- ISP 窗口偏移 ----
        8'd69:  cfg_rom = {16'h3810, 8'h00};
        8'd70:  cfg_rom = {16'h3811, 8'h10};
        8'd71:  cfg_rom = {16'h3812, 8'h00};
        8'd72:  cfg_rom = {16'h3813, 8'h06};
        // ---- 分辨率相关魔法值 ----
        8'd73:  cfg_rom = {16'h3618, 8'h00};
        8'd74:  cfg_rom = {16'h3612, 8'h29};
        8'd75:  cfg_rom = {16'h3708, 8'h64};
        8'd76:  cfg_rom = {16'h3709, 8'h52};
        8'd77:  cfg_rom = {16'h370C, 8'h03};
        // ---- 自动曝光 ----
        // v15: banding 步长按 /8 降速后的行周期(约555us)重算:
        //   50Hz半周期10ms/555us=18行? 用 PCLK 6.95M 实测: B50=37, B60=31
        //   步长错误会把 AEC 卡死在超长曝光(表现为画面全白不收敛)
        8'd78:  cfg_rom = {16'h3A02, 8'h03};
        8'd79:  cfg_rom = {16'h3A03, 8'hD8};
        8'd80:  cfg_rom = {16'h3A08, 8'h00};  // B50 步长高字节
        8'd81:  cfg_rom = {16'h3A09, 8'h25};  // B50 步长 = 37 行
        8'd82:  cfg_rom = {16'h3A0A, 8'h00};  // B60 步长高字节
        8'd83:  cfg_rom = {16'h3A0B, 8'h1F};  // B60 步长 = 31 行
        8'd84:  cfg_rom = {16'h3A0E, 8'h1A};  // 50Hz 最大band数 = 26
        8'd85:  cfg_rom = {16'h3A0D, 8'h20};  // 60Hz 最大band数 = 32
        8'd86:  cfg_rom = {16'h3A14, 8'h03};
        8'd87:  cfg_rom = {16'h3A15, 8'hD8};
        // ---- 黑电平校正 ----
        8'd88:  cfg_rom = {16'h4001, 8'h02};
        8'd89:  cfg_rom = {16'h4004, 8'h02};
        // ---- 系统使能 ----
        8'd90:  cfg_rom = {16'h3000, 8'h00};
        8'd91:  cfg_rom = {16'h3002, 8'h1C};
        8'd92:  cfg_rom = {16'h3004, 8'hFF};
        8'd93:  cfg_rom = {16'h3006, 8'hC3};
        8'd94:  cfg_rom = {16'h300E, 8'h58};  // DVP 使能, MIPI 关闭
        8'd95:  cfg_rom = {16'h302E, 8'h08};  // v18: 对齐Linux驱动权威值(原0x00错, 疑似破坏模拟读出)
        // ---- 输出格式: RGB565 ----
        8'd96:  cfg_rom = {16'h4300, 8'h6F};  // RGB565 (颜色R/B颠倒的话改0x61)
        8'd97:  cfg_rom = {16'h501F, 8'h01};  // ISP 输出 RGB
        // ---- JPEG(不用但保持默认兼容) / PCLK 分频 ----
        8'd98:  cfg_rom = {16'h4713, 8'h03};
        8'd99:  cfg_rom = {16'h4407, 8'h04};
        8'd100: cfg_rom = {16'h440E, 8'h00};
        8'd101: cfg_rom = {16'h460B, 8'h35};
        8'd102: cfg_rom = {16'h460C, 8'h22};  // PCLK 分频受 0x3824 控制
        8'd103: cfg_rom = {16'h3824, 8'h02};  // DVP PCLK 分频 (不可超过2, 见v21教训)
        // ---- ISP 功能使能 ----
        // v18: LSC镜头阴影校正关闭(bit7=0) — 之前开着但没编程校正表,
        //      ISP拿垃圾系数做径向增益 = 屏幕上"同心圆环"伪像的来源
        8'd104: cfg_rom = {16'h5000, 8'h27};  // 伽马/坏点开, LSC关
        8'd105: cfg_rom = {16'h5001, 8'hA3};  // AWB/颜色矩阵/SDE
        // ---- 自动白平衡 ----
        8'd106: cfg_rom = {16'h5180, 8'hFF};
        8'd107: cfg_rom = {16'h5181, 8'hF2};
        8'd108: cfg_rom = {16'h5182, 8'h00};
        8'd109: cfg_rom = {16'h5183, 8'h14};
        8'd110: cfg_rom = {16'h5184, 8'h25};
        8'd111: cfg_rom = {16'h5185, 8'h24};
        8'd112: cfg_rom = {16'h5186, 8'h09};
        8'd113: cfg_rom = {16'h5187, 8'h09};
        8'd114: cfg_rom = {16'h5188, 8'h09};
        8'd115: cfg_rom = {16'h5189, 8'h75};
        8'd116: cfg_rom = {16'h518A, 8'h54};
        8'd117: cfg_rom = {16'h518B, 8'hE0};
        8'd118: cfg_rom = {16'h518C, 8'hB2};
        8'd119: cfg_rom = {16'h518D, 8'h42};
        8'd120: cfg_rom = {16'h518E, 8'h3D};
        8'd121: cfg_rom = {16'h518F, 8'h56};
        8'd122: cfg_rom = {16'h5190, 8'h46};
        8'd123: cfg_rom = {16'h5191, 8'hF8};
        8'd124: cfg_rom = {16'h5192, 8'h04};
        8'd125: cfg_rom = {16'h5193, 8'h70};
        8'd126: cfg_rom = {16'h5194, 8'hF0};
        8'd127: cfg_rom = {16'h5195, 8'hF0};
        8'd128: cfg_rom = {16'h5196, 8'h03};
        8'd129: cfg_rom = {16'h5197, 8'h01};
        8'd130: cfg_rom = {16'h5198, 8'h04};
        8'd131: cfg_rom = {16'h5199, 8'h12};
        8'd132: cfg_rom = {16'h519A, 8'h04};
        8'd133: cfg_rom = {16'h519B, 8'h00};
        8'd134: cfg_rom = {16'h519C, 8'h06};
        8'd135: cfg_rom = {16'h519D, 8'h82};
        8'd136: cfg_rom = {16'h519E, 8'h38};
        // ---- 颜色矩阵 ----
        8'd137: cfg_rom = {16'h5381, 8'h1E};
        8'd138: cfg_rom = {16'h5382, 8'h5B};
        8'd139: cfg_rom = {16'h5383, 8'h08};
        8'd140: cfg_rom = {16'h5384, 8'h0A};
        8'd141: cfg_rom = {16'h5385, 8'h7E};
        8'd142: cfg_rom = {16'h5386, 8'h88};
        8'd143: cfg_rom = {16'h5387, 8'h7C};
        8'd144: cfg_rom = {16'h5388, 8'h6C};
        8'd145: cfg_rom = {16'h5389, 8'h10};
        8'd146: cfg_rom = {16'h538A, 8'h01};
        8'd147: cfg_rom = {16'h538B, 8'h98};
        // ---- 锐化/降噪 ----
        8'd148: cfg_rom = {16'h5300, 8'h08};
        8'd149: cfg_rom = {16'h5301, 8'h30};
        8'd150: cfg_rom = {16'h5302, 8'h10};
        8'd151: cfg_rom = {16'h5303, 8'h00};
        8'd152: cfg_rom = {16'h5304, 8'h08};
        8'd153: cfg_rom = {16'h5305, 8'h30};
        8'd154: cfg_rom = {16'h5306, 8'h08};
        8'd155: cfg_rom = {16'h5307, 8'h16};
        8'd156: cfg_rom = {16'h5309, 8'h08};
        8'd157: cfg_rom = {16'h530A, 8'h30};
        8'd158: cfg_rom = {16'h530B, 8'h04};
        8'd159: cfg_rom = {16'h530C, 8'h06};
        // ---- 伽马 ----
        8'd160: cfg_rom = {16'h5480, 8'h01};
        8'd161: cfg_rom = {16'h5481, 8'h08};
        8'd162: cfg_rom = {16'h5482, 8'h14};
        8'd163: cfg_rom = {16'h5483, 8'h28};
        8'd164: cfg_rom = {16'h5484, 8'h51};
        8'd165: cfg_rom = {16'h5485, 8'h65};
        8'd166: cfg_rom = {16'h5486, 8'h71};
        8'd167: cfg_rom = {16'h5487, 8'h7D};
        8'd168: cfg_rom = {16'h5488, 8'h87};
        8'd169: cfg_rom = {16'h5489, 8'h91};
        8'd170: cfg_rom = {16'h548A, 8'h9A};
        8'd171: cfg_rom = {16'h548B, 8'hAA};
        8'd172: cfg_rom = {16'h548C, 8'hB8};
        8'd173: cfg_rom = {16'h548D, 8'hCD};
        8'd174: cfg_rom = {16'h548E, 8'hDD};
        8'd175: cfg_rom = {16'h548F, 8'hEA};
        8'd176: cfg_rom = {16'h5490, 8'h1D};
        // ---- 特殊效果(饱和度) ----
        8'd177: cfg_rom = {16'h5580, 8'h02};
        8'd178: cfg_rom = {16'h5583, 8'h40};
        8'd179: cfg_rom = {16'h5584, 8'h10};
        8'd180: cfg_rom = {16'h5589, 8'h10};
        8'd181: cfg_rom = {16'h558A, 8'h00};
        8'd182: cfg_rom = {16'h558B, 8'hF8};
        // ---- AE 目标阈值 ----
        8'd183: cfg_rom = {16'h3A0F, 8'h30};
        8'd184: cfg_rom = {16'h3A10, 8'h28};
        8'd185: cfg_rom = {16'h3A1B, 8'h30};
        8'd186: cfg_rom = {16'h3A1E, 8'h26};
        8'd187: cfg_rom = {16'h3A11, 8'h60};
        8'd188: cfg_rom = {16'h3A1F, 8'h14};
        // ---- 唤醒 ----
        8'd189: cfg_rom = {16'h3008, 8'h02};
        8'd190: cfg_rom = {16'hFFFE, 8'h0A};  // 延时 10ms
        // v14: 测试图案关闭, 恢复实景 (调试时可改回 0x80 = 8色彩条)
        8'd191: cfg_rom = {16'h503D, 8'h00};
        // v14: DVP 引脚驱动强度降为 1x, 从源头减弱杜邦线串扰
        8'd192: cfg_rom = {16'h302C, 8'h02};
        // v17 诊断: 手动固定曝光/增益, 绕开疑似失灵的自动曝光
        //   曝光 = 0x1E0/16 = 30行 x 555us ≈ 17ms, 增益 2x — 典型室内值
        //   (确认曝光问题后可改回 0x3503=0x00 恢复自动)
        8'd193: cfg_rom = {16'h3503, 8'h03};  // AEC+AGC 手动
        8'd194: cfg_rom = {16'h3500, 8'h00};
        8'd195: cfg_rom = {16'h3501, 8'h01};
        8'd196: cfg_rom = {16'h3502, 8'hE0};
        8'd197: cfg_rom = {16'h350A, 8'h00};
        8'd198: cfg_rom = {16'h350B, 8'h20};
        // v18: 补齐权威表中的 50Hz 频闪配置
        8'd199: cfg_rom = {16'h3C00, 8'h04};
        default: cfg_rom = {16'hFFFF, 8'hFF}; // 结束
    endcase
endfunction

// ============================================================================
// I2C 主控制器实例
// ============================================================================
reg         i2c_start;
wire        i2c_busy;
wire        i2c_done;
reg  [7:0]  rom_idx;
wire [23:0] rom_entry = cfg_rom(rom_idx);

i2c_master #(
    .CLK_FREQ(CLK_FREQ),
    .I2C_FREQ(100_000)
) u_i2c (
    .clk        (clk),
    .rst_n      (rst_n),
    .scl        (scl),
    .sda        (sda),
    .start      (i2c_start),
    .slave_addr (7'h3C),            // OV5640: 0x78>>1
    .reg_addr   (rom_entry[23:8]),
    .wr_data    (rom_entry[7:0]),
    .busy       (i2c_busy),
    .done       (i2c_done),
    .ack_err    (cfg_ack_err)
);

// ============================================================================
// 上电时序 + 配置状态机
// ============================================================================
localparam S_RST_LOW  = 3'd0;  // RST 拉低 10ms
localparam S_RST_WAIT = 3'd1;  // RST 释放后等 30ms (SCCB 就绪)
localparam S_CHECK    = 3'd2;  // 检查当前表项
localparam S_I2C_WAIT = 3'd3;  // 等待 I2C 完成
localparam S_DELAY    = 3'd4;  // 表内延时
localparam S_DONE     = 3'd5;  // 全部完成(保持)

reg [2:0]  state;
reg [25:0] delay_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_RST_LOW;
        cam_rst_n <= 1'b0;
        cam_pwdn  <= 1'b0;                    // 一直供电
        done      <= 1'b0;
        i2c_start <= 1'b0;
        rom_idx   <= 8'd0;
        delay_cnt <= 26'd10 * MS_CYCLES;      // 10ms
    end else begin
        i2c_start <= 1'b0;

        case (state)
            // 复位保持低 10ms
            S_RST_LOW: begin
                if (delay_cnt != 0)
                    delay_cnt <= delay_cnt - 1;
                else begin
                    cam_rst_n <= 1'b1;
                    delay_cnt <= 26'd30 * MS_CYCLES;   // 30ms
                    state     <= S_RST_WAIT;
                end
            end

            // 复位释放后等待 SCCB 就绪
            S_RST_WAIT: begin
                if (delay_cnt != 0)
                    delay_cnt <= delay_cnt - 1;
                else
                    state <= S_CHECK;
            end

            // 取表项: 普通寄存器 / 延时 / 结束
            S_CHECK: begin
                if (rom_entry[23:8] == 16'hFFFF) begin
                    state <= S_DONE;
                end else if (rom_entry[23:8] == 16'hFFFE) begin
                    delay_cnt <= rom_entry[7:0] * MS_CYCLES;
                    state     <= S_DELAY;
                end else begin
                    i2c_start <= 1'b1;
                    state     <= S_I2C_WAIT;
                end
            end

            S_I2C_WAIT: begin
                if (i2c_done) begin
                    rom_idx <= rom_idx + 1;
                    state   <= S_CHECK;
                end
            end

            S_DELAY: begin
                if (delay_cnt != 0)
                    delay_cnt <= delay_cnt - 1;
                else begin
                    rom_idx <= rom_idx + 1;
                    state   <= S_CHECK;
                end
            end

            // 完成后保持, 不再重复配置
            S_DONE: begin
                done <= 1'b1;
            end

            default: state <= S_DONE;
        endcase
    end
end

endmodule
