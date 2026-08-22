#!/usr/bin/env python3
"""asm8.py — mcu8 两遍扫描汇编器 (指令表与 rtl/cpu/mcu8.v 严格一致)

用法: python scripts/asm8.py <input.asm> <output.hex>
输出: 每行一个 18-bit 字 (%05X), 供 $readmemh

语法:
    标签:       label:
    指令:       OP 操作数...        ; 注释到行尾
    MOVI rN, imm8   /  LD rN, port  /  ST port, rN
    二元: ADD/SUB/AND/OR/XOR/CMP rX, rY   立即: ADDI/SUBI/CMPI rX, imm8
    单目: SHL/SHR rX
    跳转: JMP/JZ/JNZ/JC/JNC/CALL label
    RET / HALT / NOP / WAIT imm8
立即数: 0x.. 十六进制 或 十进制
"""
import sys, re

OPS = {
    'NOP': 0x00, 'LD': 0x01, 'ST': 0x02, 'MOVI': 0x03,
    'MOV': 0x04, 'ADD': 0x05, 'ADDI': 0x06, 'SUB': 0x07,
    'SUBI': 0x08, 'AND': 0x09, 'OR': 0x0A, 'XOR': 0x0B,
    'SHL': 0x0C, 'SHR': 0x0D, 'CMP': 0x0E, 'CMPI': 0x0F,
    'JMP': 0x10, 'JZ': 0x11, 'JNZ': 0x12, 'JC': 0x13, 'JNC': 0x14,
    'CALL': 0x15, 'RET': 0x16, 'HALT': 0x17, 'WAIT': 0x18,
}
BRANCH = {'JMP', 'JZ', 'JNZ', 'JC', 'JNC', 'CALL'}
REG_BIN = 0x11  # MOVI r1,0x11 的 MOVI 编码=3=0b000011, 0x11 用于自测

def reg(tok):
    m = re.fullmatch(r'[rR]([0-7])', tok.strip())
    if not m:
        raise ValueError(f"非法寄存器 '{tok}' (应为 r0..r7)")
    return int(m.group(1))

def imm(tok):
    tok = tok.strip()
    return int(tok, 0) & 0xFF

def enc(op, sx=0, sy=0, imm8=0, a10=0):
    o = OPS[op]
    if o in (w for w in [OPS[k] for k in BRANCH]):
        return (o << 12) | (a10 & 0x3FF)
    return (o << 12) | (sx << 9) | (sy << 6) | (imm8 & 0xFF)

def assemble(src):
    # ---- 遍 1: 收标签 ----
    labels, addr = {}, 0
    for line in src.splitlines():
        line = line.split(';')[0].strip()
        if not line:
            continue
        m = re.match(r'^(\w+):$', line)
        if m:
            labels[m.group(1)] = addr
            continue
        addr += 1
    # ---- 遍 2: 编码 ----
    out, addr = [], 0
    for line in src.splitlines():
        line = line.split(';')[0].strip()
        if not line:
            continue
        m = re.match(r'^(\w+):$', line)
        if m:
            continue
        parts = line.replace(',', ' ').split()
        op, args = parts[0].upper(), parts[1:]
        try:
            if op == 'NOP':
                w = enc(op)
            elif op == 'LD':                       # LD rX, port
                w = enc(op, sx=reg(args[0]), imm8=imm(args[1]))
            elif op == 'ST':                       # ST port, rX
                w = enc(op, sx=reg(args[1]), imm8=imm(args[0]))
            elif op in ('MOVI', 'ADDI', 'SUBI', 'CMPI'):
                w = enc(op, sx=reg(args[0]), imm8=imm(args[1]))
            elif op == 'WAIT':                   # WAIT imm8 (无寄存器)
                w = enc(op, imm8=imm(args[0]))
            elif op in ('MOV', 'ADD', 'SUB', 'AND', 'OR', 'XOR', 'CMP'):
                w = enc(op, sx=reg(args[0]), sy=reg(args[1]))
            elif op in ('SHL', 'SHR'):
                w = enc(op, sx=reg(args[0]))
            elif op == 'RET' or op == 'HALT':
                w = enc(op)
            elif op in BRANCH:
                tgt = args[0]
                if tgt not in labels:
                    raise ValueError(f"未定义标签 '{tgt}'")
                w = enc(op, a10=labels[tgt])
            else:
                raise ValueError(f"未知指令 '{op}'")
        except Exception as e:
            raise ValueError(f"[行 '{line}'] {e}")
        out.append(w)
        addr += 1
    return out

def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    src = open(sys.argv[1], encoding='utf-8').read()
    words = assemble(src)
    with open(sys.argv[2], 'w') as f:
        for w in words:
            f.write(f"{w:05X}\n")
    print(f"asm8: {sys.argv[1]} -> {sys.argv[2]} ({len(words)} 条指令)")

if __name__ == '__main__':
    main()
