// ============================================================================
// I2C (SCCB) 主控制器 - 只写模式, 16位寄存器地址 (OV5640)
//
// 传输格式: START | 器件地址+W | 寄存器地址高8位 | 寄存器地址低8位 | 数据 | STOP
// 每字节后有 ACK 位 (第9个SCL脉冲, 主机释放SDA)
//
// 时序: 每位占4个相位(quarter), SDA 只在 SCL 低电平期间变化,
//       SCL 空闲时保持高电平(标准 I2C, 不再自由翻转)
// SDA 开漏输出: 只拉低或释放, 依靠上拉电阻回高
// ============================================================================
module i2c_master #(
    parameter CLK_FREQ = 100_000_000,
    parameter I2C_FREQ = 100_000,
    parameter ADDR16   = 1            // 1=16位寄存器地址(OV5640), 0=8位(OV7670)
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg         scl,
    inout  wire        sda,

    input  wire        start,        // 单周期脉冲, 触发一次写传输
    input  wire [6:0]  slave_addr,   // 7位器件地址 (OV5640 = 0x3C)
    input  wire [15:0] reg_addr,     // 16位寄存器地址
    input  wire [7:0]  wr_data,      // 写入数据
    output reg         busy,
    output reg         done,         // 传输结束单周期脉冲
    output reg         ack_err       // 本次传输中出现过 NACK (保持到下次 start)
);

// 4相位 tick: 每个 I2C 位周期分成4段
localparam integer QUARTER = CLK_FREQ / (I2C_FREQ * 4);

reg [15:0] qcnt;
reg        qtick;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        qcnt  <= 0;
        qtick <= 0;
    end else if (busy) begin
        if (qcnt == QUARTER - 1) begin
            qcnt  <= 0;
            qtick <= 1;
        end else begin
            qcnt  <= qcnt + 1;
            qtick <= 0;
        end
    end else begin
        qcnt  <= 0;
        qtick <= 0;
    end
end

// ============================================================================
// 状态机
// ============================================================================
localparam S_IDLE  = 3'd0;
localparam S_START = 3'd1;   // 起始条件: SCL高电平时 SDA 1->0
localparam S_BIT   = 3'd2;   // 发送位 (bit_idx 0..7 数据, 8=ACK)
localparam S_STOP  = 3'd3;   // 停止条件: SCL高电平时 SDA 0->1
localparam S_DONE  = 3'd4;

reg [2:0] state;
reg [1:0] phase;       // 位内相位 0..3
reg [3:0] bit_idx;     // 0..8 (8 = ACK位)
reg [1:0] byte_idx;    // 0:器件地址 1:寄存器高 2:寄存器低 3:数据
reg [7:0] cur_byte;
reg       sda_low;     // 1 = 拉低SDA, 0 = 释放(高阻)

assign sda = sda_low ? 1'b0 : 1'bz;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state    <= S_IDLE;
        scl      <= 1'b1;
        sda_low  <= 1'b0;
        busy     <= 0;
        done     <= 0;
        ack_err  <= 0;
        phase    <= 0;
        bit_idx  <= 0;
        byte_idx <= 0;
        cur_byte <= 0;
    end else begin
        done <= 0;

        case (state)
            // ----------------------------------------------------------
            S_IDLE: begin
                scl     <= 1'b1;
                sda_low <= 1'b0;
                if (start) begin
                    busy     <= 1;
                    ack_err  <= 0;
                    cur_byte <= {slave_addr, 1'b0};   // 写操作
                    byte_idx <= 0;
                    bit_idx  <= 0;
                    phase    <= 0;
                    state    <= S_START;
                end
            end

            // ----------------------------------------------------------
            // 起始: p0 SDA拉低(SCL仍高) p1 保持 p2 SCL拉低 p3 -> S_BIT
            S_START: if (qtick) begin
                phase <= phase + 1;
                case (phase)
                    2'd0: sda_low <= 1'b1;
                    2'd2: scl     <= 1'b0;
                    2'd3: state   <= S_BIT;   // phase 回绕到 0
                    default: ;
                endcase
            end

            // ----------------------------------------------------------
            // 每位: p0 SCL低,设置SDA  p1 SCL升高  p2 SCL高中点(采样ACK)  p3 SCL拉低
            S_BIT: if (qtick) begin
                phase <= phase + 1;
                case (phase)
                    2'd0: begin
                        if (bit_idx < 4'd8)
                            sda_low <= ~cur_byte[3'd7 - bit_idx[2:0]];  // MSB先发
                        else
                            sda_low <= 1'b0;   // ACK位: 释放SDA给从机
                    end
                    2'd1: scl <= 1'b1;
                    2'd2: begin
                        if (bit_idx == 4'd8 && sda)
                            ack_err <= 1'b1;   // 从机未应答
                    end
                    2'd3: begin
                        scl <= 1'b0;
                        if (bit_idx == 4'd8) begin
                            bit_idx <= 0;
                            if (byte_idx == (ADDR16 ? 2'd3 : 2'd2)) begin
                                state <= S_STOP;
                            end else begin
                                byte_idx <= byte_idx + 1;
                                cur_byte <= (byte_idx == 2'd0) ? (ADDR16 ? reg_addr[15:8] : reg_addr[7:0]) :
                                            (byte_idx == 2'd1) ? (ADDR16 ? reg_addr[7:0]  : wr_data)      :
                                                                 wr_data;
                            end
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end
                endcase
            end

            // ----------------------------------------------------------
            // 停止: p0 SCL低,SDA拉低  p1 SCL升高  p2 SDA释放(0->1) p3 完成
            S_STOP: if (qtick) begin
                phase <= phase + 1;
                case (phase)
                    2'd0: sda_low <= 1'b1;
                    2'd1: scl     <= 1'b1;
                    2'd2: sda_low <= 1'b0;
                    2'd3: state   <= S_DONE;
                endcase
            end

            // ----------------------------------------------------------
            S_DONE: begin
                busy  <= 0;
                done  <= 1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
