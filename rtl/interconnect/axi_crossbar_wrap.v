`timescale 1ns/1ps
// ============================================================================
// axi_crossbar_wrap — 控制面寄存器堆 (AXI4-Lite 从机, doc/register_map.md)
//
//   0x000 ID/VERSION   RO  0x5640_0001
//   0x004 MODE         RW  显示模式 0..3 (经 mode_switch 消隐期生效)
//   0x008 TH_HI        RW  Canny 高阈值 (12-bit)
//   0x00C TH_LO        RW  Canny 低阈值 (12-bit)
//   0x010 SNN_VTH      RW  LIF 阈值 Q8.16
//   0x014 SNN_ACT_W    WO  活动写: [5:0]idx [15:8]data (一次写一路)
//   0x018 STATUS       RO  {canny_busy, snn_busy, cfg_done, id_ok, ...}
//   0x020 SNN_CTRL     WO  bit0: run_start (自清)
//   0x030+ SNN_CNT[n]  RO  神经元 n 尖峰计数 (16 个)
//   非法地址读 0xDEAD, 写丢弃, 并置 STATUS.err
// ============================================================================
module axi_crossbar_wrap #(
    parameter integer NNEU = 16
)(
    input  wire clk,
    input  wire rst_n,

    // AXI4-Lite 从口
    input  wire        s_awvalid,
    input  wire [11:0] s_awaddr,
    output wire        s_awready,
    input  wire        s_wvalid,
    input  wire [31:0] s_wdata,
    output wire        s_wready,
    output reg         s_bvalid,
    input  wire        s_bready,

    input  wire        s_arvalid,
    input  wire [11:0] s_araddr,
    output wire        s_arready,
    output reg         s_rvalid,
    output reg  [31:0] s_rdata,
    input  wire        s_rready,

    // 到各子系统的配置/状态
    output reg  [1:0]  mode_raw,
    output reg  [11:0] th_hi,
    output reg  [11:0] th_lo,
    output reg  signed [23:0] snn_vth,
    output reg         snn_act_wr,
    output reg  [5:0]  snn_act_idx,
    output reg  [7:0]  snn_act_wdata,
    output reg         snn_run_start,

    input  wire        canny_busy,
    input  wire        snn_busy,
    input  wire        snn_done,
    input  wire [7:0]  snn_cnt [0:NNEU-1],
    input  wire        cfg_done,
    input  wire        id_ok,
    input  wire [15:0] chip_id
);

    // 握手: 单拍 ready
    assign s_awready = 1'b1;
    assign s_wready  = 1'b1;
    assign s_arready = 1'b1;

    reg addr_err;

    // ---------------- 写 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_raw <= 0; th_hi <= 12'd600; th_lo <= 12'd200;
            snn_vth <= 24'sd8 <<< 16;
            snn_act_wr <= 0; snn_act_idx <= 0; snn_act_wdata <= 0;
            snn_run_start <= 0;
            s_bvalid <= 0; addr_err <= 0;
        end else begin
            snn_act_wr    <= 1'b0;
            snn_run_start <= 1'b0;
            s_bvalid      <= 1'b0;

            if (s_awvalid && s_wvalid) begin
                s_bvalid <= 1'b1;
                case (s_awaddr)
                    12'h004: mode_raw <= s_wdata[1:0];
                    12'h008: th_hi    <= s_wdata[11:0];
                    12'h00C: th_lo    <= s_wdata[11:0];
                    12'h010: snn_vth  <= s_wdata[23:0];
                    12'h014: begin
                        snn_act_idx   <= s_wdata[5:0];
                        snn_act_wdata <= s_wdata[15:8];
                        snn_act_wr    <= 1'b1;
                    end
                    12'h020: snn_run_start <= s_wdata[0];
                    12'h000, 12'h018, 12'h030, 12'h034, 12'h038, 12'h03C,
                    12'h040, 12'h044, 12'h048, 12'h04C, 12'h050, 12'h054,
                    12'h058, 12'h05C, 12'h060, 12'h064: ; // RO: 忽略写
                    default: addr_err <= 1'b1;
                endcase
            end
        end
    end

    // ---------------- 读 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 0; s_rdata <= 0;
        end else begin
            s_rvalid <= 1'b0;
            if (s_arvalid) begin
                s_rvalid <= 1'b1;
                if (s_araddr >= 12'h030 && s_araddr < 12'h030 + NNEU*4)
                    s_rdata <= {24'd0, snn_cnt[(s_araddr-12'h030)>>2]};
                else case (s_araddr)
                    12'h000: s_rdata <= {chip_id, 16'h0001};
                    12'h018: s_rdata <= {23'd0, addr_err, 3'd0, canny_busy,
                                         snn_busy, snn_done, cfg_done, id_ok};
                    default: s_rdata <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end

endmodule
