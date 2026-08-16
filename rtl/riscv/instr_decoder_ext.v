`timescale 1ns/1ps
// ============================================================================
// instr_decoder_ext — 自定义指令译码 (custom-0 = opcode 0x0B)
//   编码: funct7=0000000, rs2/rs1 任意, funct3: 000=c.sadd 001=c.pop
//   输出 alu_en 与 funct3, 供 VexRiscv custom 指令槽接入
// ============================================================================
module instr_decoder_ext (
    input  wire [31:0] instr,
    output wire        is_custom,   // custom-0 段
    output wire        alu_en,      // 本 ALU处理的指令
    output wire [2:0]  funct3,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd
);

    assign is_custom = (instr[6:0] == 7'b0001011);   // 0x0B custom-0
    assign alu_en    = is_custom && (instr[31:25] == 7'b0000000) &&
                        (instr[14:12] == 3'd0 || instr[14:12] == 3'd1);
    assign funct3    = instr[14:12];
    assign rs1       = instr[19:15];
    assign rs2       = instr[24:20];
    assign rd        = instr[11:7];

endmodule
