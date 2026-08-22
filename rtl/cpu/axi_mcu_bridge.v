`timescale 1ns/1ps
// ============================================================================
// axi_mcu_bridge — mcu8 MMIO 端口 ↔ AXI4-Lite 主桥 + 16 字节 scratchpad
//
//   端口空间 (写选通 / 组合读):
//     W 0x00  AXI 地址 [7:0]        W 0x01  AXI 地址 [11:8]
//     W 0x02..0x05  写数据字节 b0..b3
//     W 0x06  触发 AXI 写 (单拍)     W 0x07  触发 AXI 读 (单拍)
//     R 0x40  bit0 = AXI busy
//     R 0x41  直通状态 {canny_busy,snn_busy,snn_done,cfg_done,id_ok} bit4..0
//             (经 2FF 同步)
//     R 0x42..0x45  AXI 读结果字节 b0..b3 (锁存)
//     RW 0x50..0x5F  16 字节暂存 (CPU 的"内存")
// ============================================================================
module axi_mcu_bridge (
    input  wire       clk,
    input  wire       rst_n,

    // MCU MMIO (来自 mcu8)
    input  wire [7:0] port_addr,
    input  wire [7:0] port_out,
    input  wire       port_wr,
    output wire [7:0] port_in,

    // AXI4-Lite 主口 (接 axi_crossbar_wrap)
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
    input  wire        m_rready,

    // 直通状态输入 (异步域, 内部 2FF 同步)
    input  wire id_ok, cfg_done, snn_done, snn_busy, canny_busy
);

    assign m_bready = 1'b1;
    assign m_rready = 1'b1;

    // ---------------- 状态同步 (proc→cfg) ----------------
    (* ASYNC_REG = "TRUE" *) reg [4:0] st_p1, st_p2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st_p1 <= 0; st_p2 <= 0; end
        else begin
            st_p1 <= {canny_busy, snn_busy, snn_done, cfg_done, id_ok};
            st_p2 <= st_p1;
        end
    end

    // ---------------- 锁存与 scratch ----------------
    reg [11:0] axi_addr;
    reg [31:0] wr_l, rd_l;
    reg [7:0]  scratch [0:15];
    reg        busy;
    reg        op_write;

    // ---------------- AXI 单拍事务 FSM ----------------
    localparam [2:0] A_IDLE = 0, A_WCMD = 1, A_WWAIT = 2,
                     A_RCMD = 3, A_RWAIT = 4;
    reg [2:0] afs;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_addr <= 0; wr_l <= 0; rd_l <= 0; busy <= 0; op_write <= 0;
            for (k = 0; k < 16; k = k + 1) scratch[k] <= 0;
            afs <= A_IDLE;
            m_awvalid <= 0; m_wvalid <= 0; m_arvalid <= 0;
            m_awaddr <= 0; m_wdata <= 0; m_araddr <= 0;
        end else begin
            // ---- 端口写 (可与其他态并行) ----
            if (port_wr) begin
                case (port_addr)
                    8'h00: axi_addr[7:0]  <= port_out;
                    8'h01: axi_addr[11:8] <= port_out[3:0];
                    8'h02: wr_l[7:0]   <= port_out;
                    8'h03: wr_l[15:8]  <= port_out;
                    8'h04: wr_l[23:16] <= port_out;
                    8'h05: wr_l[31:24] <= port_out;
                    8'h06: if (!busy) begin busy <= 1; op_write <= 1; end
                    8'h07: if (!busy) begin busy <= 1; op_write <= 0; end
                    default: if (port_addr >= 8'h50 && port_addr <= 8'h5F)
                                 scratch[port_addr[3:0]] <= port_out;
                endcase
            end

            // ---- AXI 事务 ----
            case (afs)
                A_IDLE: if (busy) begin
                    if (op_write) begin
                        m_awvalid <= 1; m_wvalid <= 1;
                        m_awaddr  <= axi_addr; m_wdata <= wr_l;
                        afs <= A_WCMD;
                    end else begin
                        m_arvalid <= 1;
                        m_araddr  <= axi_addr;
                        afs <= A_RCMD;
                    end
                end
                A_WCMD: if (m_awready && m_wready) begin
                    m_awvalid <= 0; m_wvalid <= 0;
                    afs <= A_WWAIT;
                end
                A_WWAIT: if (m_bvalid) begin
                    busy <= 0;
                    afs  <= A_IDLE;
                end
                A_RCMD: if (m_arready) begin
                    m_arvalid <= 0;
                    afs <= A_RWAIT;
                end
                A_RWAIT: if (m_rvalid) begin
                    rd_l <= m_rdata;
                    busy <= 0;
                    afs  <= A_IDLE;
                end
                default: afs <= A_IDLE;
            endcase
        end
    end

    // ---------------- 端口读 (组合) ----------------
    assign port_in =
        (port_addr == 8'h40) ? {7'b0, busy} :
        (port_addr == 8'h41) ? {3'b0, st_p2} :
        (port_addr == 8'h42) ? rd_l[7:0]   :
        (port_addr == 8'h43) ? rd_l[15:8]  :
        (port_addr == 8'h44) ? rd_l[23:16] :
        (port_addr == 8'h45) ? rd_l[31:24] :
        (port_addr >= 8'h50 && port_addr <= 8'h5F) ? scratch[port_addr[3:0]] :
        8'h00;

endmodule
