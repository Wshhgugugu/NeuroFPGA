`timescale 1ns/1ps
// ============================================================================
// ov5640_ctrl — OV5640 采集控制 (PCLK 域同步采集, 架构移植自已验证工程)
//
//   ① 上电时序 + SCCB 寄存器表下载 + 读 chip ID 校验 (cfg_clk 域)
//   ② PCLK 域: RGB565 (低字节先出) 重组 -> 灰度化 -> AXI-Stream 输出
//   ③ 分帧: HREF 长静默判场消隐 (不依赖 VSYNC 线, 实测其不可靠)
//
// 灰度化 (定点, 冻结): gray = (R>>2) + (G>>1) + (B>>2)
//   R[15:11] G[10:5] B[4:0] -> (R5<<1 | R5) 近似除4: (R5*3)>>2 取 R5 + R5>>1
//   实现取: R8=R5*8, 权重和 = R8/4 + G8/2 + B8/4, 移位实现
// ============================================================================
module ov5640_ctrl #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480,
    parameter integer CFG_CLK_FREQ = 100_000_000,  // cfg_clk 频率
    parameter         CHECK_CHIP_ID = 1            // 1=配置前读 ID 校验
)(
    // ---- 配置/系统侧 (cfg_clk 域) ----
    input  wire        cfg_clk,
    input  wire        cfg_rst_n,
    output reg  [15:0] chip_id,        // 读回的 0x300A/0x300B (期望 0x5640)
    output reg         id_ok,          // ID 校验通过
    output reg         cfg_done,       // 寄存器表全部写完
    output wire        cfg_ack_err,    // SCCB NACK (调试)

    // ---- SCCB ----
    output wire        scl,
    inout  wire        sda,

    // ---- 摄像头复位/电源 (cfg_clk 域寄存) ----
    output reg         cam_rst_n,      // 低有效
    output reg         cam_pwdn,       // 高有效

    // ---- DVP 采集侧 (pclk 域, 引脚已 BUFG) ----
    input  wire        pclk,
    input  wire        pclk_rst_n,     // 异步复位 (建议保持到 cfg_done)
    input  wire        vsync,          // 仅活动指示
    input  wire        href,
    input  wire [7:0]  data_in,

    // ---- 像素流输出 (pclk 域, 8-bit 灰度 AXI-Stream) ----
    output reg         m_axis_tvalid,
    output reg  [7:0]  m_axis_tdata,
    output reg         m_axis_tlast,   // 行尾
    output reg         m_axis_tuser,   // 帧首
    input  wire        m_axis_tready
);

    localparam integer MS_CYCLES = CFG_CLK_FREQ / 1000;

`include "ov5640_init_table.vh"

    reg [7:0] sccb_rd_lo;

    // ------------------------------------------------------------------
    // SCCB 主控制器
    // ------------------------------------------------------------------
    reg         sccb_start = 0;
    reg         sccb_rd = 0;
    reg  [15:0] sccb_reg = 0;
    reg  [7:0]  sccb_wdata = 0;
    wire        sccb_busy;
    wire        sccb_done;
    wire [7:0]  sccb_rdata;

    sccb_master #(
        .CLK_FREQ  (CFG_CLK_FREQ),
        .SCCB_FREQ (100_000)
    ) u_sccb (
        .clk(cfg_clk), .rst_n(cfg_rst_n),
        .scl(scl), .sda(sda),
        .start(sccb_start), .rd_wr_n(sccb_rd),
        .slave_addr(7'h3C),          // OV5640: 0x78>>1
        .reg_addr(sccb_reg), .wr_data(sccb_wdata),
        .busy(sccb_busy), .done(sccb_done),
        .rd_data(sccb_rdata), .ack_err(cfg_ack_err)
    );

    // ------------------------------------------------------------------
    // 配置状态机 (cfg_clk 域): 上电时序 -> ID -> 寄存器表
    // ------------------------------------------------------------------
    localparam [3:0] C_RST_LOW  = 4'd0;
    localparam [3:0] C_RST_WAIT = 4'd1;
    localparam [3:0] C_ID1      = 4'd2;   // 读 0x300A
    localparam [3:0] C_ID2      = 4'd3;   // 读 0x300B
    localparam [3:0] C_CHECK    = 4'd4;
    localparam [3:0] C_ENTRY    = 4'd5;
    localparam [3:0] C_WR_WAIT  = 4'd6;
    localparam [3:0] C_DELAY    = 4'd7;
    localparam [3:0] C_DONE     = 4'd8;

    reg  [3:0]  cstate = C_RST_LOW;
    reg  [7:0]  rom_idx = 0;
    reg  [25:0] delay_cnt = 0;
    reg  [7:0]  id_hi = 0;
    wire [23:0] rom_entry = ov5640_cfg_rom(rom_idx);

    always @(posedge cfg_clk or negedge cfg_rst_n) begin
        if (!cfg_rst_n) begin
            cstate <= C_RST_LOW;
            cam_rst_n <= 1'b0;
            cam_pwdn  <= 1'b0;
            sccb_start <= 1'b0;
            sccb_rd <= 0; sccb_reg <= 0; sccb_wdata <= 0;
            rom_idx <= 0;
            delay_cnt <= 26'd10 * MS_CYCLES;
            chip_id <= 16'hFFFF;
            id_ok <= 1'b0;
            cfg_done <= 1'b0;
            id_hi <= 0;
        end else begin
            sccb_start <= 1'b0;
            case (cstate)
                C_RST_LOW:
                    if (delay_cnt != 0) delay_cnt <= delay_cnt - 1;
                    else begin
                        cam_rst_n <= 1'b1;
                        delay_cnt <= 26'd30 * MS_CYCLES;
                        cstate <= C_RST_WAIT;
                    end

                C_RST_WAIT:
                    if (delay_cnt != 0) delay_cnt <= delay_cnt - 1;
                    else if (CHECK_CHIP_ID) begin
                        sccb_start <= 1'b1;
                        sccb_rd <= 1'b1;
                        sccb_reg <= 16'h300A;
                        cstate <= C_ID1;
                    end else
                        cstate <= C_ENTRY;

                C_ID1:
                    if (sccb_done) begin
                        id_hi <= sccb_rdata;
                        sccb_start <= 1'b1;
                        sccb_rd <= 1'b1;
                        sccb_reg <= 16'h300B;
                        cstate <= C_ID2;
                    end

                C_ID2:
                    if (sccb_done) begin
                        chip_id <= {id_hi, sccb_rdata};
                        cstate <= C_CHECK;
                    end

                C_CHECK: begin
                    id_ok <= (chip_id == 16'h5640);
                    cstate <= C_ENTRY;
                end

                C_ENTRY: begin
                    if (rom_entry[23:8] == 16'hFFFF)
                        cstate <= C_DONE;
                    else if (rom_entry[23:8] == 16'hFFFE) begin
                        delay_cnt <= rom_entry[7:0] * MS_CYCLES;
                        cstate <= C_DELAY;
                    end else begin
                        sccb_start <= 1'b1;
                        sccb_rd <= 1'b0;
                        sccb_reg <= rom_entry[23:8];
                        sccb_wdata <= rom_entry[7:0];
                        cstate <= C_WR_WAIT;
                    end
                end

                C_WR_WAIT:
                    if (sccb_done) begin
                        rom_idx <= rom_idx + 1;
                        cstate <= C_ENTRY;
                    end

                C_DELAY:
                    if (delay_cnt != 0) delay_cnt <= delay_cnt - 1;
                    else begin
                        rom_idx <= rom_idx + 1;
                        cstate <= C_ENTRY;
                    end

                C_DONE: cfg_done <= 1'b1;
                default: cstate <= C_DONE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // PCLK 域采集: 复位同步 + 引脚寄存 (IOB)
    // ------------------------------------------------------------------
    reg prst_s1 = 0, prst_s2 = 0;
    always @(posedge pclk or negedge pclk_rst_n) begin
        if (!pclk_rst_n) begin prst_s1 <= 0; prst_s2 <= 0; end
        else begin prst_s1 <= 1'b1; prst_s2 <= prst_s1; end
    end
    wire prst_n = prst_s2;

    (* IOB = "TRUE" *) reg       hs_i;
    (* IOB = "TRUE" *) reg [7:0] d_i;
    always @(posedge pclk) begin
        hs_i <= href;
        d_i  <= data_in;
    end
    reg hs_d;
    always @(posedge pclk) hs_d <= hs_i;
    wire hs_rise = hs_i & ~hs_d;
    wire hs_fall = ~hs_i & hs_d;

    // 分帧: HREF 静默 > GAP_PCLK = 场消隐 (行消隐≈616 pclk, 场消隐≈95万 pclk)
    localparam integer GAP_PCLK = 5000;
    reg [19:0] gap_cnt;
    wire frame_gap = (gap_cnt >= GAP_PCLK[19:0]);
    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n)       gap_cnt <= 0;
        else if (hs_i)     gap_cnt <= 0;
        else if (!frame_gap) gap_cnt <= gap_cnt + 1;
    end
    wire frame_start = hs_rise & frame_gap;

    // RGB565 重组: 低字节先出
    reg       byte_sel;
    reg [7:0] byte_lo;
    reg [9:0] px;
    reg [9:0] ln;
    reg       synced;

    wire [15:0] rgb565 = {d_i, byte_lo};      // 后到的是高字节
    // 灰度: R8>>2 + G8>>1 + B8>>2  (R8=R5*8 等, 全移位)
    wire [7:0] r8 = {rgb565[15:11], rgb565[15:13]};
    wire [7:0] g8 = {rgb565[10:5],  rgb565[10:9]};
    wire [7:0] b8 = {rgb565[4:0],   rgb565[4:2]};
    wire [9:0] gray_acc = r8[7:2] + g8[7:1] + b8[7:2];
    wire [7:0] gray = |gray_acc[9:8] ? 8'hFF : gray_acc[7:0];

    // 输出寄存
    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            m_axis_tvalid <= 0; m_axis_tdata <= 0;
            m_axis_tlast <= 0; m_axis_tuser <= 0;
            byte_sel <= 0; byte_lo <= 0;
            px <= 0; ln <= 0; synced <= 0;
        end else begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;

            if (frame_start) begin
                px <= 0; ln <= 0;
                byte_lo <= d_i;      // 首行首字节当拍就在总线上
                byte_sel <= 1'b1;
                synced <= 1'b1;
            end else if (hs_i) begin
                if (!byte_sel) begin
                    byte_lo <= d_i;
                    byte_sel <= 1'b1;
                end else if (synced) begin
                    // 摄像头字节流不可停顿: 本接口不吸收背压, tready 必须由
                    // 下游 fifo_async 写侧驱动 (= ~full), 深 FIFO 下恒为 1
                    byte_sel <= 1'b0;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= gray;
                    m_axis_tuser  <= (ln == 0) && (px == 0);
                    m_axis_tlast  <= (px == IMG_W-1) || (px == 10'd1023);
                    px <= px + 1;
                end
            end

            if (hs_fall) begin
                byte_sel <= 1'b0;
                px <= 0;
                ln <= ln + 1;
            end
        end
    end

    // 未使用引脚警告抑制
    wire _unused = |{vsync, sccb_rd_lo, 1'b0};

endmodule
