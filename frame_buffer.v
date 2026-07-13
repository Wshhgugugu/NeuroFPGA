// ============================================================================
// 帧缓存 - 三缓冲 (乒乓/三重缓冲), 240x240 RGB565 x 3 bank
//   57600 x 16bit x 3 = 172800 x 16bit, 约 78 个 BRAM36 (7020 共 140)
//   摄像头写一块、LCD 读另一块、第三块空闲轮转 -> 彻底消除画面撕裂
//
// bank 选择由顶层 bank 管理器通过高位地址给出:
//   地址 = bank_base(idx) + 帧内偏移(0..57599)
// 上电初始化为竖彩条, 摄像头出图前显示彩条 (三块都填)
// ============================================================================
module frame_buffer (
    input  wire        clk,

    input  wire        wr_en,
    input  wire [17:0] wr_addr,      // 0..172799 (含 bank 偏移)
    input  wire [15:0] wr_data,

    input  wire [17:0] rd_addr,      // 0..172799 (含 bank 偏移)
    output reg  [15:0] rd_data
);

reg [15:0] mem [0:172799];

integer i;
initial begin
    for (i = 0; i < 172800; i = i + 1) begin
        case (((i % 57600) % 240) / 60)
            0: mem[i] = 16'hF800;   // 红
            1: mem[i] = 16'h07E0;   // 绿
            2: mem[i] = 16'h001F;   // 蓝
            default: mem[i] = 16'hFFFF; // 白
        endcase
    end
end

always @(posedge clk) begin
    if (wr_en)
        mem[wr_addr] <= wr_data;
    rd_data <= mem[rd_addr];
end

endmodule
