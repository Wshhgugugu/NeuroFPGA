`timescale 1ns/1ps
// ============================================================================
// custom_alu — 自定义指令运算单元 (RISC-V custom-0, 计划 Phase 6)
//   c.sadd  (funct3=000): 饱和加   res = sat32(a+b)
//   c.pop   (funct3=001): 位计数   res = popcount(a) | (popcount(b)<<16)
//   两操作数 32-bit, 与软件模拟一致 (tb 内对照)
// ============================================================================
module custom_alu (
    input  wire [2:0]  funct3,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] res
);

    // 饱和加
    wire [32:0] sum = {a[31], a} + {b[31], b};
    wire ovf = (a[31] == b[31]) && (sum[31] != a[31]);

    // popcount
    function [5:0] pc32(input [31:0] v);
        pc32 = v[0]+v[1]+v[2]+v[3]+v[4]+v[5]+v[6]+v[7]+v[8]+v[9]+v[10]+v[11]
             + v[12]+v[13]+v[14]+v[15]+v[16]+v[17]+v[18]+v[19]+v[20]+v[21]
             + v[22]+v[23]+v[24]+v[25]+v[26]+v[27]+v[28]+v[29]+v[30]+v[31];
    endfunction

    always @(*) begin
        case (funct3)
            3'd0: res = ovf ? (a[31] ? 32'h80000000 : 32'h7FFFFFFF) : sum[31:0];
            3'd1: res = {26'd0, pc32(b), pc32(a)};
            default: res = 32'd0;
        endcase
    end

endmodule
