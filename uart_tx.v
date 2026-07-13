// ============================================================================
// UART 发送器 - 115200 8N1 (诊断输出用)
// ============================================================================
module uart_tx #(
    parameter CLK_FREQ = 125_000_000,
    parameter BAUD     = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       send,      // 单周期脉冲
    output reg        busy,
    output reg        txd
);

localparam integer DIV = CLK_FREQ / BAUD;

reg [$clog2(DIV)-1:0] bcnt;
reg [3:0] bit_idx;
reg [9:0] sh;                    // {停止位, 数据LSB先, 起始位}

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy    <= 0;
        txd     <= 1'b1;
        bcnt    <= 0;
        bit_idx <= 0;
        sh      <= 10'h3FF;
    end else if (!busy) begin
        txd <= 1'b1;
        if (send) begin
            busy    <= 1;
            sh      <= {1'b1, data, 1'b0};
            bit_idx <= 0;
            bcnt    <= 0;
        end
    end else begin
        txd <= sh[0];
        if (bcnt == DIV-1) begin
            bcnt <= 0;
            sh   <= {1'b1, sh[9:1]};
            if (bit_idx == 4'd9)
                busy <= 0;
            else
                bit_idx <= bit_idx + 1;
        end else begin
            bcnt <= bcnt + 1;
        end
    end
end

endmodule
