// ============================================================================
// ov5640_init_table.vh — OV5640 DVP RGB565 VGA@30fps 寄存器表
//   移植自 OV5640 工程已上板验证的 ov5640_config.v cfg_rom (2026-07-15 v3 表)
//   表项: {16'h REG, 8'h VAL}; 16'hFFFE=延时(ms); 16'hFFFF=结束
//   修改须知: PCLK≈56MHz, 须接时钟专用脚 W17(P侧 MRCC)
// ============================================================================
// synopsis translate_off
`ifndef OV5640_INIT_TABLE_VH
`define OV5640_INIT_TABLE_VH
// synopsis translate_on

    function [23:0] ov5640_cfg_rom(input [7:0] idx);
        case (idx)
            // ---- 复位与时钟源 ----
            8'd0:   ov5640_cfg_rom = {16'h3103, 8'h11};  // 系统时钟来自晶振
            8'd1:   ov5640_cfg_rom = {16'h3008, 8'h82};  // 软件复位
            8'd2:   ov5640_cfg_rom = {16'hFFFE, 8'h0A};  // 延时 10ms
            8'd3:   ov5640_cfg_rom = {16'h3008, 8'h42};  // 掉电模式(配置期间)
            8'd4:   ov5640_cfg_rom = {16'h3103, 8'h03};  // 系统时钟来自PLL
            8'd5:   ov5640_cfg_rom = {16'h3017, 8'hFF};  // IO输出使能
            8'd6:   ov5640_cfg_rom = {16'h3018, 8'hFF};  // IO输出使能
            // ---- PLL: XVCLK 24MHz -> PCLK≈56MHz (30fps VGA) ----
            8'd7:   ov5640_cfg_rom = {16'h3034, 8'h1A};
            8'd8:   ov5640_cfg_rom = {16'h3035, 8'h11};  // /1 -> PCLK≈56MHz
            8'd9:   ov5640_cfg_rom = {16'h3036, 8'h46};  // PLL 倍频 70
            8'd10:  ov5640_cfg_rom = {16'h3037, 8'h13};  // 预分频/3, 根分频/2
            8'd11:  ov5640_cfg_rom = {16'h3108, 8'h01};  // 时钟根分频
            // ---- 模拟/内核控制 (厂商推荐值) ----
            8'd12:  ov5640_cfg_rom = {16'h3630, 8'h36};
            8'd13:  ov5640_cfg_rom = {16'h3631, 8'h0E};
            8'd14:  ov5640_cfg_rom = {16'h3632, 8'hE2};
            8'd15:  ov5640_cfg_rom = {16'h3633, 8'h12};
            8'd16:  ov5640_cfg_rom = {16'h3621, 8'hE0};
            8'd17:  ov5640_cfg_rom = {16'h3704, 8'hA0};
            8'd18:  ov5640_cfg_rom = {16'h3703, 8'h5A};
            8'd19:  ov5640_cfg_rom = {16'h3715, 8'h78};
            8'd20:  ov5640_cfg_rom = {16'h3717, 8'h01};
            8'd21:  ov5640_cfg_rom = {16'h370B, 8'h60};
            8'd22:  ov5640_cfg_rom = {16'h3705, 8'h1A};
            8'd23:  ov5640_cfg_rom = {16'h3905, 8'h02};
            8'd24:  ov5640_cfg_rom = {16'h3906, 8'h10};
            8'd25:  ov5640_cfg_rom = {16'h3901, 8'h0A};
            8'd26:  ov5640_cfg_rom = {16'h3731, 8'h12};
            8'd27:  ov5640_cfg_rom = {16'h3600, 8'h08};
            8'd28:  ov5640_cfg_rom = {16'h3601, 8'h33};
            8'd29:  ov5640_cfg_rom = {16'h302D, 8'h60};
            8'd30:  ov5640_cfg_rom = {16'h3620, 8'h52};
            8'd31:  ov5640_cfg_rom = {16'h371B, 8'h20};
            8'd32:  ov5640_cfg_rom = {16'h471C, 8'h50};
            8'd33:  ov5640_cfg_rom = {16'h3A13, 8'h43};
            8'd34:  ov5640_cfg_rom = {16'h3A18, 8'h00};
            8'd35:  ov5640_cfg_rom = {16'h3A19, 8'hF8};
            8'd36:  ov5640_cfg_rom = {16'h3635, 8'h13};
            8'd37:  ov5640_cfg_rom = {16'h3636, 8'h03};
            8'd38:  ov5640_cfg_rom = {16'h3634, 8'h40};
            8'd39:  ov5640_cfg_rom = {16'h3622, 8'h01};
            // ---- 50/60Hz 光带检测 ----
            8'd40:  ov5640_cfg_rom = {16'h3C01, 8'hA4};
            8'd41:  ov5640_cfg_rom = {16'h3C04, 8'h28};
            8'd42:  ov5640_cfg_rom = {16'h3C05, 8'h98};
            8'd43:  ov5640_cfg_rom = {16'h3C06, 8'h00};
            8'd44:  ov5640_cfg_rom = {16'h3C07, 8'h08};
            8'd45:  ov5640_cfg_rom = {16'h3C08, 8'h00};
            8'd46:  ov5640_cfg_rom = {16'h3C09, 8'h1C};
            8'd47:  ov5640_cfg_rom = {16'h3C0A, 8'h9C};
            8'd48:  ov5640_cfg_rom = {16'h3C0B, 8'h40};
            // ---- 采样/镜像: 2x2 binning, VGA ----
            8'd49:  ov5640_cfg_rom = {16'h3820, 8'h41};  // 垂直 binning
            8'd50:  ov5640_cfg_rom = {16'h3821, 8'h07};  // 水平镜像+binning
            8'd51:  ov5640_cfg_rom = {16'h3814, 8'h31};  // X 隔行采样
            8'd52:  ov5640_cfg_rom = {16'h3815, 8'h31};  // Y 隔行采样
            // ---- 传感器窗口 (全幅) ----
            8'd53:  ov5640_cfg_rom = {16'h3800, 8'h00};
            8'd54:  ov5640_cfg_rom = {16'h3801, 8'h00};
            8'd55:  ov5640_cfg_rom = {16'h3802, 8'h00};
            8'd56:  ov5640_cfg_rom = {16'h3803, 8'h04};
            8'd57:  ov5640_cfg_rom = {16'h3804, 8'h0A};
            8'd58:  ov5640_cfg_rom = {16'h3805, 8'h3F};
            8'd59:  ov5640_cfg_rom = {16'h3806, 8'h07};
            8'd60:  ov5640_cfg_rom = {16'h3807, 8'h9B};
            // ---- 输出尺寸 640x480 ----
            8'd61:  ov5640_cfg_rom = {16'h3808, 8'h02};
            8'd62:  ov5640_cfg_rom = {16'h3809, 8'h80};
            8'd63:  ov5640_cfg_rom = {16'h380A, 8'h01};
            8'd64:  ov5640_cfg_rom = {16'h380B, 8'hE0};
            // ---- 总行长/总帧长 ----
            8'd65:  ov5640_cfg_rom = {16'h380C, 8'h07};
            8'd66:  ov5640_cfg_rom = {16'h380D, 8'h68};  // HTS = 1896
            8'd67:  ov5640_cfg_rom = {16'h380E, 8'h03};
            8'd68:  ov5640_cfg_rom = {16'h380F, 8'hD8};  // VTS = 984
            // ---- ISP 窗口偏移 ----
            8'd69:  ov5640_cfg_rom = {16'h3810, 8'h00};
            8'd70:  ov5640_cfg_rom = {16'h3811, 8'h10};
            8'd71:  ov5640_cfg_rom = {16'h3812, 8'h00};
            8'd72:  ov5640_cfg_rom = {16'h3813, 8'h06};
            // ---- 分辨率相关魔法值 ----
            8'd73:  ov5640_cfg_rom = {16'h3618, 8'h00};
            8'd74:  ov5640_cfg_rom = {16'h3612, 8'h29};
            8'd75:  ov5640_cfg_rom = {16'h3708, 8'h64};
            8'd76:  ov5640_cfg_rom = {16'h3709, 8'h52};
            8'd77:  ov5640_cfg_rom = {16'h370C, 8'h03};
            // ---- 自动曝光 (30fps 消频参数) ----
            8'd78:  ov5640_cfg_rom = {16'h3A02, 8'h03};
            8'd79:  ov5640_cfg_rom = {16'h3A03, 8'hD8};
            8'd80:  ov5640_cfg_rom = {16'h3A08, 8'h01};
            8'd81:  ov5640_cfg_rom = {16'h3A09, 8'h25};
            8'd82:  ov5640_cfg_rom = {16'h3A0A, 8'h00};
            8'd83:  ov5640_cfg_rom = {16'h3A0B, 8'hF4};
            8'd84:  ov5640_cfg_rom = {16'h3A0E, 8'h03};
            8'd85:  ov5640_cfg_rom = {16'h3A0D, 8'h04};
            8'd86:  ov5640_cfg_rom = {16'h3A14, 8'h03};
            8'd87:  ov5640_cfg_rom = {16'h3A15, 8'hD8};
            // ---- 黑电平校正 ----
            8'd88:  ov5640_cfg_rom = {16'h4001, 8'h02};
            8'd89:  ov5640_cfg_rom = {16'h4004, 8'h02};
            // ---- 系统使能 ----
            8'd90:  ov5640_cfg_rom = {16'h3000, 8'h00};
            8'd91:  ov5640_cfg_rom = {16'h3002, 8'h1C};
            8'd92:  ov5640_cfg_rom = {16'h3004, 8'hFF};
            8'd93:  ov5640_cfg_rom = {16'h3006, 8'hC3};
            8'd94:  ov5640_cfg_rom = {16'h300E, 8'h58};  // DVP 使能, MIPI 关闭
            8'd95:  ov5640_cfg_rom = {16'h302E, 8'h08};
            // ---- 输出格式: RGB565 ----
            8'd96:  ov5640_cfg_rom = {16'h4300, 8'h6F};  // RGB565
            8'd97:  ov5640_cfg_rom = {16'h501F, 8'h01};  // ISP 输出 RGB
            8'd98:  ov5640_cfg_rom = {16'h4713, 8'h03};
            8'd99:  ov5640_cfg_rom = {16'h4407, 8'h04};
            8'd100: ov5640_cfg_rom = {16'h440E, 8'h00};
            8'd101: ov5640_cfg_rom = {16'h460B, 8'h35};
            8'd102: ov5640_cfg_rom = {16'h460C, 8'h22};
            8'd103: ov5640_cfg_rom = {16'h3824, 8'h02};  // DVP PCLK 分频
            // ---- ISP 功能使能 ----
            8'd104: ov5640_cfg_rom = {16'h5000, 8'h27};  // 伽马/坏点开, LSC关
            8'd105: ov5640_cfg_rom = {16'h5001, 8'hA3};  // AWB/颜色矩阵/SDE
            // ---- 自动白平衡 ----
            8'd106: ov5640_cfg_rom = {16'h5180, 8'hFF};
            8'd107: ov5640_cfg_rom = {16'h5181, 8'hF2};
            8'd108: ov5640_cfg_rom = {16'h5182, 8'h00};
            8'd109: ov5640_cfg_rom = {16'h5183, 8'h14};
            8'd110: ov5640_cfg_rom = {16'h5184, 8'h25};
            8'd111: ov5640_cfg_rom = {16'h5185, 8'h24};
            8'd112: ov5640_cfg_rom = {16'h5186, 8'h09};
            8'd113: ov5640_cfg_rom = {16'h5187, 8'h09};
            8'd114: ov5640_cfg_rom = {16'h5188, 8'h09};
            8'd115: ov5640_cfg_rom = {16'h5189, 8'h75};
            8'd116: ov5640_cfg_rom = {16'h518A, 8'h54};
            8'd117: ov5640_cfg_rom = {16'h518B, 8'hE0};
            8'd118: ov5640_cfg_rom = {16'h518C, 8'hB2};
            8'd119: ov5640_cfg_rom = {16'h518D, 8'h42};
            8'd120: ov5640_cfg_rom = {16'h518E, 8'h3D};
            8'd121: ov5640_cfg_rom = {16'h518F, 8'h56};
            8'd122: ov5640_cfg_rom = {16'h5190, 8'h46};
            8'd123: ov5640_cfg_rom = {16'h5191, 8'hF8};
            8'd124: ov5640_cfg_rom = {16'h5192, 8'h04};
            8'd125: ov5640_cfg_rom = {16'h5193, 8'h70};
            8'd126: ov5640_cfg_rom = {16'h5194, 8'hF0};
            8'd127: ov5640_cfg_rom = {16'h5195, 8'hF0};
            8'd128: ov5640_cfg_rom = {16'h5196, 8'h03};
            8'd129: ov5640_cfg_rom = {16'h5197, 8'h01};
            8'd130: ov5640_cfg_rom = {16'h5198, 8'h04};
            8'd131: ov5640_cfg_rom = {16'h5199, 8'h12};
            8'd132: ov5640_cfg_rom = {16'h519A, 8'h04};
            8'd133: ov5640_cfg_rom = {16'h519B, 8'h00};
            8'd134: ov5640_cfg_rom = {16'h519C, 8'h06};
            8'd135: ov5640_cfg_rom = {16'h519D, 8'h82};
            8'd136: ov5640_cfg_rom = {16'h519E, 8'h38};
            // ---- 颜色矩阵 ----
            8'd137: ov5640_cfg_rom = {16'h5381, 8'h1E};
            8'd138: ov5640_cfg_rom = {16'h5382, 8'h5B};
            8'd139: ov5640_cfg_rom = {16'h5383, 8'h08};
            8'd140: ov5640_cfg_rom = {16'h5384, 8'h0A};
            8'd141: ov5640_cfg_rom = {16'h5385, 8'h7E};
            8'd142: ov5640_cfg_rom = {16'h5386, 8'h88};
            8'd143: ov5640_cfg_rom = {16'h5387, 8'h7C};
            8'd144: ov5640_cfg_rom = {16'h5388, 8'h6C};
            8'd145: ov5640_cfg_rom = {16'h5389, 8'h10};
            8'd146: ov5640_cfg_rom = {16'h538A, 8'h01};
            8'd147: ov5640_cfg_rom = {16'h538B, 8'h98};
            // ---- 锐化/降噪 ----
            8'd148: ov5640_cfg_rom = {16'h5300, 8'h08};
            8'd149: ov5640_cfg_rom = {16'h5301, 8'h30};
            8'd150: ov5640_cfg_rom = {16'h5302, 8'h10};
            8'd151: ov5640_cfg_rom = {16'h5303, 8'h00};
            8'd152: ov5640_cfg_rom = {16'h5304, 8'h08};
            8'd153: ov5640_cfg_rom = {16'h5305, 8'h30};
            8'd154: ov5640_cfg_rom = {16'h5306, 8'h08};
            8'd155: ov5640_cfg_rom = {16'h5307, 8'h16};
            8'd156: ov5640_cfg_rom = {16'h5309, 8'h08};
            8'd157: ov5640_cfg_rom = {16'h530A, 8'h30};
            8'd158: ov5640_cfg_rom = {16'h530B, 8'h04};
            8'd159: ov5640_cfg_rom = {16'h530C, 8'h06};
            // ---- 伽马 ----
            8'd160: ov5640_cfg_rom = {16'h5480, 8'h01};
            8'd161: ov5640_cfg_rom = {16'h5481, 8'h08};
            8'd162: ov5640_cfg_rom = {16'h5482, 8'h14};
            8'd163: ov5640_cfg_rom = {16'h5483, 8'h28};
            8'd164: ov5640_cfg_rom = {16'h5484, 8'h51};
            8'd165: ov5640_cfg_rom = {16'h5485, 8'h65};
            8'd166: ov5640_cfg_rom = {16'h5486, 8'h71};
            8'd167: ov5640_cfg_rom = {16'h5487, 8'h7D};
            8'd168: ov5640_cfg_rom = {16'h5488, 8'h87};
            8'd169: ov5640_cfg_rom = {16'h5489, 8'h91};
            8'd170: ov5640_cfg_rom = {16'h548A, 8'h9A};
            8'd171: ov5640_cfg_rom = {16'h548B, 8'hAA};
            8'd172: ov5640_cfg_rom = {16'h548C, 8'hB8};
            8'd173: ov5640_cfg_rom = {16'h548D, 8'hCD};
            8'd174: ov5640_cfg_rom = {16'h548E, 8'hDD};
            8'd175: ov5640_cfg_rom = {16'h548F, 8'hEA};
            8'd176: ov5640_cfg_rom = {16'h5490, 8'h1D};
            // ---- 特殊效果(饱和度) ----
            8'd177: ov5640_cfg_rom = {16'h5580, 8'h02};
            8'd178: ov5640_cfg_rom = {16'h5583, 8'h40};
            8'd179: ov5640_cfg_rom = {16'h5584, 8'h10};
            8'd180: ov5640_cfg_rom = {16'h5589, 8'h10};
            8'd181: ov5640_cfg_rom = {16'h558A, 8'h00};
            8'd182: ov5640_cfg_rom = {16'h558B, 8'hF8};
            // ---- AE 目标阈值 ----
            8'd183: ov5640_cfg_rom = {16'h3A0F, 8'h30};
            8'd184: ov5640_cfg_rom = {16'h3A10, 8'h28};
            8'd185: ov5640_cfg_rom = {16'h3A1B, 8'h30};
            8'd186: ov5640_cfg_rom = {16'h3A1E, 8'h26};
            8'd187: ov5640_cfg_rom = {16'h3A11, 8'h60};
            8'd188: ov5640_cfg_rom = {16'h3A1F, 8'h14};
            // ---- 唤醒 ----
            8'd189: ov5640_cfg_rom = {16'h3008, 8'h02};
            8'd190: ov5640_cfg_rom = {16'hFFFE, 8'h0A};  // 延时 10ms
            8'd191: ov5640_cfg_rom = {16'h503D, 8'h00};  // 测试图案关
            8'd192: ov5640_cfg_rom = {16'h302C, 8'h42};  // DVP 驱动 2x
            8'd193: ov5640_cfg_rom = {16'h3503, 8'h00};  // AEC+AGC 全自动
            8'd194: ov5640_cfg_rom = {16'h3500, 8'h00};
            8'd195: ov5640_cfg_rom = {16'h3501, 8'h01};
            8'd196: ov5640_cfg_rom = {16'h3502, 8'hE0};
            8'd197: ov5640_cfg_rom = {16'h350A, 8'h00};
            8'd198: ov5640_cfg_rom = {16'h350B, 8'h20};
            8'd199: ov5640_cfg_rom = {16'h3C00, 8'h04};
            default: ov5640_cfg_rom = {16'hFFFF, 8'hFF}; // 结束
        endcase
    endfunction

// synopsis translate_off
`endif
// synopsis translate_on
