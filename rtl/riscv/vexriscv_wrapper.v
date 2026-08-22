`timescale 1ns/1ps
// ============================================================================
// vexriscv_wrapper — VexRiscv 集成壳 (计划 Phase 6)
//
//   集成方式 (按计划风险 R5 的稳妥路径):
//     1. 官方预生成 VexRiscv (RV32I, AXI4-Lite 总线, `vexriscv_netlist.v`)
//        以黑盒实例接入, 本壳提供时钟/复位/总线转接;
//     2. 无网表时 (仿真/早期开发), `SOFT_CTRL=1` 用轻量软 FSM 替代 CPU:
//        上电 -> 配阈值 -> 切 mode, 走通整个寄存器面;
//     3. custom_alu/instr_decoder_ext 已独立验证, 待 SpinalHDL 生成核的
//        custom 指令槽接线 (v2.0).
// ============================================================================
module vexriscv_wrapper #(
    parameter integer SOFT_CTRL = 1    // 1=软 FSM (默认, 无网表可综合)
)(
    input  wire clk,
    input  wire rst_n,

    // AXI-Lite 主口 (到 axi_crossbar_wrap 的寄存器堆)
    output reg         m_awvalid,
    output reg  [11:0] m_awaddr,
    input  wire        m_awready,
    output reg         m_wvalid,
    output reg  [31:0] m_wdata,
    input  wire        m_wready,
    input  wire        m_bvalid,
    output wire        m_bready,

    output reg         m_arvalid,
    output reg  [11:0] m_araddr,
    input  wire        m_arready,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,
    output wire        m_rready

`ifndef SYNTHESIS
    ,
    output reg  [31:0] dbg_soft_pc = 0
`endif
);

    assign m_bready = 1'b1;
    assign m_rready = 1'b1;

    generate
    if (SOFT_CTRL) begin : g_soft
        // --------------------------------------------------------------
        // 轻量控制序列: 读 ID (0x00) -> 写 th_hi (0x08) -> 写 th_lo (0x0C)
        //               -> 写 mode=1 (0x04) -> 写 SNN 启动 (0x20) -> 停在循环
        // 地址表见 doc/register_map.md
        // --------------------------------------------------------------
        localparam [3:0] S_RST = 0, S_RD_ID_A = 1, S_RD_ID_W = 2,
                         S_WR0_A = 3, S_WR0_W = 4, S_WAIT = 5, S_DONE = 6;
        reg [3:0]   state;
        reg [2:0]   step;
        reg [31:0]  id_val;
        reg [44:0]  seq_r;      // 函数结果暂存 (函数调用不可位选)

        // 序列表: {addr, wdata, is_write}
        function [44:0] seq(input [2:0] idx);
            case (idx)
                3'd0: seq = {1'b1, 12'h008, 32'd600};   // TH_HI = 600
                3'd1: seq = {1'b1, 12'h00C, 32'd200};   // TH_LO = 200
                3'd2: seq = {1'b1, 12'h004, 32'd1};     // MODE = 1 (Canny)
                3'd3: seq = {1'b0, 12'h000, 32'd0};     // 读 ID
                default: seq = {1'b1, 12'h020, 32'd1};  // SNN 起动
            endcase
        endfunction

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                state <= S_RST; step <= 0;
                m_awvalid <= 0; m_awaddr <= 0; m_wvalid <= 0; m_wdata <= 0;
                m_arvalid <= 0; m_araddr <= 0; id_val <= 0;
            end else begin
                case (state)
                    S_RST: begin
                        step <= 0;
                        state <= S_WR0_A;
                    end
                    // ---- 写序列 ----
                    S_WR0_A: begin
                        seq_r = seq(step);
                        if (seq_r[44]) begin
                            m_awvalid <= 1;
                            m_awaddr  <= seq_r[43:32];
                            m_wvalid  <= 1;
                            m_wdata   <= seq_r[31:0];
                            state <= S_WR0_W;
                        end else begin
                            m_arvalid <= 1;
                            m_araddr  <= seq_r[43:32];
                            state <= S_RD_ID_W;
                        end
                    end
                    S_WR0_W: if (m_bvalid) begin
                        m_awvalid <= 0; m_wvalid <= 0;
                        if (step == 3'd4) state <= S_DONE;
                        else begin step <= step + 1; state <= S_WR0_A; end
                    end
                    // ---- 读 ID ----
                    S_RD_ID_A: begin
                        m_arvalid <= 1; m_araddr <= 12'h000; state <= S_RD_ID_W;
                    end
                    S_RD_ID_W: if (m_rvalid) begin
                        m_arvalid <= 0; id_val <= m_rdata;
                        if (step == 3'd4) state <= S_DONE;
                        else begin step <= step + 1; state <= S_WR0_A; end
                    end
                    // ---- SNN 启动等 ----
                    S_WAIT: state <= S_DONE;
                    S_DONE: begin end  // 保持
                    default: state <= S_RST;
                endcase
            end
        end

        `ifndef SYNTHESIS
        always @(posedge clk) dbg_soft_pc <= {state, step, id_val};
        `endif
    end else begin : g_netlist
        // VexRiscv 预生成网表实例 (v2.0 接入点)
        // vexriscv_netlist u_cpu (.clk, .reset, .io_awValid(m_awvalid), ...);
        initial begin
            $display("vexriscv_wrapper: netlist path requires vexriscv_netlist.v");
        end
        assign m_awvalid = 0; assign m_wvalid = 0; assign m_arvalid = 0;
        assign m_awaddr = 0; assign m_wdata = 0; assign m_araddr = 0;
    end
    endgenerate

endmodule
