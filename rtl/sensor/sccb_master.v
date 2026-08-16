`timescale 1ns/1ps
// ============================================================================
// sccb_master — SCCB(I2C 兼容) 主控制器, 16 位寄存器地址, 支持 读/写
//   (基于 OV5640 工程已验证的 i2c_master FSM 扩展读传输)
//
// 写: START | addr+W | reg[15:8] | reg[7:0] | data | STOP
// 读: START | addr+W | reg[15:8] | reg[7:0] | RESTART | addr+R | rd(NACK) | STOP
//
// 时序: 每位 4 相位, SDA 仅在 SCL 低时变化; SDA 开漏(高阻释放)
// ============================================================================
module sccb_master #(
    parameter integer CLK_FREQ = 100_000_000,
    parameter integer SCCB_FREQ = 100_000
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg         scl,
    inout  wire        sda,

    input  wire        start,        // 单周期脉冲
    input  wire        rd_wr_n,      // 0=写 1=读
    input  wire [6:0]  slave_addr,
    input  wire [15:0] reg_addr,
    input  wire [7:0]  wr_data,
    output wire        busy,
    output reg         done,         // 单周期脉冲
    output reg  [7:0]  rd_data,
    output reg         ack_err      // 本次传输出现 NACK (保持到下次 start)
);

    localparam integer QUARTER = CLK_FREQ / (SCCB_FREQ * 4);

    // ---- 4 相位 tick ----
    reg [15:0] qcnt;
    reg        qtick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qcnt <= 0; qtick <= 0;
        end else if (busy) begin
            if (qcnt == QUARTER - 1) begin
                qcnt <= 0;  qtick <= 1;
            end else begin
                qcnt <= qcnt + 1; qtick <= 0;
            end
        end else begin
            qcnt <= 0; qtick <= 0;
        end
    end

    localparam S_IDLE  = 4'd0;
    localparam S_START = 4'd1;
    localparam S_BIT   = 4'd2;   // 发送一位 (bit_idx 0..8)
    localparam S_RSTART= 4'd3;   // 重复起始 (读传输)
    localparam S_RDBIT = 4'd4;   // 接收一位
    localparam S_STOP  = 4'd5;
    localparam S_DONE  = 4'd6;

    reg [3:0]  state;
    reg [1:0]  phase;
    reg [3:0]  bit_idx;
    reg [2:0]  byte_idx;   // 写: 0=器件地址 1=reg_h 2=reg_l 3=data
                           // 读: 0..2 同上, 之后 RSTART, 3=器件地址(R), 再收数据
    reg [7:0]  cur_byte;
    reg        sda_low;
    reg        rden_r;
    reg [7:0]  shreg;

    assign sda  = sda_low ? 1'b0 : 1'bz;
    assign busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; scl <= 1'b1; sda_low <= 1'b0;
            done <= 0; ack_err <= 0; rd_data <= 0;
            phase <= 0; bit_idx <= 0; byte_idx <= 0;
            cur_byte <= 0; rden_r <= 0; shreg <= 0;
        end else begin
            done <= 0;
            case (state)
                S_IDLE: begin
                    scl <= 1'b1; sda_low <= 1'b0;
                    if (start) begin
                        ack_err  <= 0;
                        rden_r   <= rd_wr_n;
                        cur_byte <= {slave_addr, 1'b0};
                        byte_idx <= 0; bit_idx <= 0; phase <= 0;
                        state    <= S_START;
                    end
                end

                // START: SCL 高时 SDA 1->0, 随后 SCL 拉低
                S_START: if (qtick) begin
                    phase <= phase + 1;
                    case (phase)
                        2'd0: sda_low <= 1'b1;
                        2'd2: scl     <= 1'b0;
                        2'd3: state   <= S_BIT;
                        default: ;
                    endcase
                end

                // 数据位: p0 设 SDA, p1 SCL 高, p2 采样, p3 SCL 低
                S_BIT: if (qtick) begin
                    phase <= phase + 1;
                    case (phase)
                        2'd0: begin
                            if (bit_idx < 4'd8)
                                sda_low <= ~cur_byte[3'd7 - bit_idx[2:0]];
                            else
                                sda_low <= 1'b0;   // ACK 位释放给从机
                        end
                        2'd1: scl <= 1'b1;
                        2'd2: begin
                            if (bit_idx == 4'd8 && sda)
                                ack_err <= 1'b1;
                        end
                        2'd3: begin
                            scl <= 1'b0;
                            if (bit_idx == 4'd8) begin
                                bit_idx <= 0;
                                if (!rden_r && byte_idx == 3'd3) begin
                                    state <= S_STOP;      // 写完数据
                                end else if (rden_r && byte_idx == 3'd3) begin
                                    state <= S_RDBIT;     // 器件地址+R 已应答 -> 收数
                                end else if (byte_idx == 3'd2) begin
                                    // 地址发完: 读 -> RSTART, 写 -> 数据
                                    byte_idx <= 3'd3;
                                    if (rden_r) state <= S_RSTART;
                                    else
                                        cur_byte <= wr_data;
                                end else begin
                                    byte_idx <= byte_idx + 1;
                                    cur_byte <= (byte_idx == 3'd0) ? reg_addr[15:8] :
                                                (byte_idx == 3'd1) ? reg_addr[7:0]  : wr_data;
                                end
                            end else begin
                                bit_idx <= bit_idx + 1;
                            end
                        end
                    endcase
                end

                // 重复起始: SCL 低 -> 升高 -> SDA 拉低(START) -> SCL 拉低,
                // 随后以 S_BIT 发送 器件地址+R
                S_RSTART: if (qtick) begin
                    phase <= phase + 1;
                    case (phase)
                        2'd0: sda_low <= 1'b0;   // 释放(ACK 位后已是)
                        2'd1: scl     <= 1'b1;
                        2'd2: sda_low <= 1'b1;   // SCL 高时 SDA 1->0
                        2'd3: begin
                            scl     <= 1'b0;
                            cur_byte <= {slave_addr, 1'b1};  // 读方向
                            state    <= S_BIT;
                        end
                        default: ;
                    endcase
                end

                S_RDBIT: if (qtick) begin
                    phase <= phase + 1;
                    case (phase)
                        2'd0: sda_low <= 1'b0;    // 全程释放 SDA 由从机驱动
                        2'd1: scl     <= 1'b1;
                        2'd2: begin
                            shreg <= {shreg[6:0], sda};
                            if (bit_idx == 4'd8) rd_data <= shreg;
                        end
                        2'd3: begin
                            scl <= 1'b0;
                            if (bit_idx == 4'd8) begin
                                // NACK 已在进入前设置: 最后一位才拉低
                                state <= S_STOP;
                            end else begin
                                bit_idx <= bit_idx + 1;
                                sda_low <= (bit_idx == 4'd7);  // 第9位=NACK
                            end
                        end
                    endcase
                end

                S_STOP: if (qtick) begin
                    phase <= phase + 1;
                    case (phase)
                        2'd0: sda_low <= 1'b1;
                        2'd1: scl     <= 1'b1;
                        2'd2: sda_low <= 1'b0;
                        2'd3: state   <= S_DONE;
                    endcase
                end

                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
