`timescale 1ns/1ps
// ============================================================================
// mcu8 — 自研 8 位控制 MCU (PicoBlaze 定位, 无外部依赖)
//
//   用途: 控制面闭环 (读 SNN 脉冲计数 → 自适应调 Canny 阈值), 取代外置软核
//   架构: 8×8bit 寄存器 + Z/C 标志 + 1024×18 程序 ROM (正好 1 个 RAMB18)
//         两态执行 (FETCH→EXEC), 约 2 拍/指令; 50MHz 下 25 MIPS
//   指令编码 (18-bit): iw[17:12]=op, iw[11:9]=sX, iw[8:6]=sY,
//                      iw[7:0]=imm8, 跳转类 iw[9:0]=addr10
//   汇编器: scripts/asm8.py (指令表与此处严格一致)
//
//   MMIO 约定: LD sX, imm8 (读端口 imm8), ST imm8, sX (写端口 imm8)
//   端口空间由 axi_mcu_bridge 定义 (AXI 读写触发/结果/状态/scratch)
// ============================================================================
module mcu8 #(
    parameter PROG = "prog.hex"      // $readmemh 路径 (相对运行目录)
)(
    input  wire       clk,
    input  wire       rst_n,

    // MMIO 端口 (EXEC 拍组合驱动; port_in 须同拍就绪 — 桥用锁存值)
    output wire [7:0] port_addr,
    output wire [7:0] port_out,
    output wire       port_wr,       // 写选通 (EXEC 1 拍)
    output wire       port_rd,       // 读选通 (EXEC 1 拍)
    input  wire [7:0] port_in,

    output wire       halted,
    output wire       active
);

    // ---------------- 指令操作码 (与 asm8.py 一致) ----------------
    localparam [5:0]
        OP_NOP  = 6'h00, OP_LD   = 6'h01, OP_ST   = 6'h02, OP_MOVI = 6'h03,
        OP_MOV  = 6'h04, OP_ADD  = 6'h05, OP_ADDI = 6'h06, OP_SUB  = 6'h07,
        OP_SUBI = 6'h08, OP_AND  = 6'h09, OP_OR   = 6'h0A, OP_XOR  = 6'h0B,
        OP_SHL  = 6'h0C, OP_SHR  = 6'h0D, OP_CMP  = 6'h0E, OP_CMPI = 6'h0F,
        OP_JMP  = 6'h10, OP_JZ   = 6'h11, OP_JNZ  = 6'h12, OP_JC   = 6'h13,
        OP_JNC  = 6'h14, OP_CALL = 6'h15, OP_RET  = 6'h16, OP_HALT = 6'h17,
        OP_WAIT = 6'h18;

    localparam [1:0] S_BOOT = 2'd0,   // 复位后预取第一条指令
                     S_FETCH = 2'd1,  // ir 装载
                     S_EXEC  = 2'd2,  // 执行
                     S_WAIT  = 2'd3;  // WAIT 延时

    reg [1:0]  state;
    reg [9:0]  pc;
    reg [9:0]  lr;                    // 链接寄存器 (单层调用, 无栈)
    reg [17:0] ir;
    reg [7:0]  regs [0:7];
    reg        f_z, f_c;
    reg [15:0] wait_cnt;
    reg        halt_r;

    // ---------------- 程序 ROM (1024×18 → 1 个 RAMB18) ----------------
    (* rom_style = "block" *) reg [17:0] rom [0:1023];
    initial $readmemh(PROG, rom);

    // 跳转地址转发: EXEC 拍若发生重定向, ROM 同拍改读目标地址
    reg [17:0] rom_q;
    wire        is_call = (ir[17:12] == OP_CALL);
    wire        is_ret  = (ir[17:12] == OP_RET);
    wire [9:0]  a10     = ir[9:0];
    wire        jcc_taken;
    // 条件跳转判定
    reg cond;
    always @(*) begin
        case (ir[17:12])
            OP_JZ:   cond = f_z;
            OP_JNZ:  cond = ~f_z;
            OP_JC:   cond = f_c;
            OP_JNC:  cond = ~f_c;
            OP_JMP:  cond = 1'b1;
            default: cond = 1'b0;
        endcase
    end
    assign jcc_taken = (state == S_EXEC) &&
                       (cond || is_call || is_ret) &&
                       !halt_r;
    wire [9:0] redirect = is_ret ? lr : a10;

    always @(posedge clk)
        rom_q <= rom[(state == S_EXEC && jcc_taken) ? redirect : pc];

    // ---------------- 译码 ----------------
    wire [5:0] op  = ir[17:12];
    wire [2:0] sx  = ir[11:9];
    wire [2:0] sy  = ir[8:6];
    wire [7:0] imm = ir[7:0];

    wire [7:0] sxv = regs[sx];
    wire [7:0] syv = regs[sy];
    wire       imm_op = (op == OP_MOVI) || (op == OP_ADDI) || (op == OP_SUBI) ||
                        (op == OP_CMPI) || (op == OP_LD)    || (op == OP_ST)  ||
                        (op == OP_WAIT);
    wire [7:0] operand = imm_op ? imm : syv;

    // ALU
    reg  [7:0] alu_r;
    reg        alu_c, alu_z;
    reg        alu_wren;              // 写回 regs[sx]
    reg        flag_z_en, flag_c_en;
    always @(*) begin
        alu_r = sxv; alu_c = f_c; alu_z = f_z;
        alu_wren = 1'b0; flag_z_en = 1'b0; flag_c_en = 1'b0;
        case (op)
            OP_MOVI: begin alu_r = imm; alu_wren = 1; end
            OP_MOV:  begin alu_r = syv; alu_wren = 1; end
            OP_LD:   begin alu_r = port_in; alu_wren = 1; end
            OP_ADD, OP_ADDI: begin
                {alu_c, alu_r} = {1'b0, sxv} + {1'b0, operand};
                alu_wren = 1; flag_z_en = 1; flag_c_en = 1;
            end
            OP_SUB, OP_SUBI: begin
                {alu_c, alu_r} = {1'b0, sxv} - {1'b0, operand};  // C=借位
                alu_wren = 1; flag_z_en = 1; flag_c_en = 1;
            end
            OP_AND: begin alu_r = sxv & syv; alu_wren=1; flag_z_en=1; end
            OP_OR:  begin alu_r = sxv | syv; alu_wren=1; flag_z_en=1; end
            OP_XOR: begin alu_r = sxv ^ syv; alu_wren=1; flag_z_en=1; end
            OP_SHL: begin alu_r = {sxv[6:0],1'b0}; alu_c = sxv[7];
                          alu_wren=1; flag_z_en=1; flag_c_en=1; end
            OP_SHR: begin alu_r = {1'b0,sxv[7:1]}; alu_c = sxv[0];
                          alu_wren=1; flag_z_en=1; flag_c_en=1; end
            OP_CMP, OP_CMPI: begin
                alu_z = (sxv == operand); alu_c = (sxv < operand);
                flag_z_en = 1; flag_c_en = 1;      // 不写回
            end
            default: ;
        endcase
        // Z 标志统一按结果重算 (CMP 上面已显式算过, 不覆盖其语义:
        // CMP 的 alu_r 不是结果, 必须跳过)
        if (flag_z_en && op != OP_CMP && op != OP_CMPI)
            alu_z = (alu_r == 8'h00);
    end

    // ---------------- 端口组合驱动 (EXEC 拍) ----------------
    wire in_exec = (state == S_EXEC) && rst_n && !halt_r;
    assign port_addr = in_exec ? imm : 8'h00;
    assign port_out  = in_exec ? sxv : 8'h00;
    assign port_wr   = in_exec && (op == OP_ST);
    assign port_rd   = in_exec && (op == OP_LD);

    // ---------------- 主状态机 ----------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_BOOT; pc <= 0; lr <= 0; ir <= 0;
            f_z <= 0; f_c <= 0; wait_cnt <= 0; halt_r <= 0;
            for (i = 0; i < 8; i = i + 1) regs[i] <= 0;
        end else begin
            case (state)
                S_BOOT: state <= S_FETCH;          // rom_q 已加载 instr[0]

                S_FETCH: begin
                    ir    <= rom_q;
                    pc    <= pc + 1'b1;
                    state <= S_EXEC;
                end

                S_EXEC: begin
                    // (端口为组合驱动, 见上方 assign; EXEC 无需时序动作)

                    // 写回 / 标志
                    if (alu_wren) regs[sx] <= alu_r;
                    if (flag_z_en) f_z <= alu_z;
                    if (flag_c_en) f_c <= alu_c;

                    // PC 重定向
                    if (jcc_taken) pc <= redirect;
                    if (is_call)   lr  <= pc;      // pc 已 +1 = 返回地址

                    // 次态
                    if (op == OP_HALT)       begin halt_r <= 1; state <= S_WAIT; end
                    else if (op == OP_WAIT)  begin
                        wait_cnt <= {imm, 8'h00} - 1'b1;
                        state    <= S_WAIT;
                    end else state <= S_FETCH;
                end

                S_WAIT: begin
                    if (halt_r) state <= S_WAIT;   // HALT: 永久停
                    else if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
                    else state <= S_FETCH;
                end

                default: state <= S_BOOT;
            endcase
        end
    end

    assign halted = halt_r;
    assign active = rst_n && !halt_r;

endmodule
