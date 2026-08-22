; ============================================================================
; prog_adaptive.asm — mcu8 自适应阈值控制程序
;
;   功能闭环: SNN 脉冲计数 → Canny 双阈值自适应
;     activity = (SNN_CNT[0]>>1) + (SNN_CNT[1]>>1)      (0..254)
;     activity > 96  → 边缘太多 → TH_HI += 16
;     activity < 32  → 边缘太少 → TH_HI -= 16
;     夹在 [224, 976] (th16: 14..61), 步长 16
;
;   寄存器约定:
;     r1/r2  = AXI 地址 lo/hi (子程序输入, 不被子程序改写)
;     r3..r6 = 数据字节 b0..b3 (子程序输入/输出)
;     r0     = 子程序内部临时
;     r7     = th16 影子寄存器 (TH_HI/16, 永久保存)
; ============================================================================

; ================================ 主程序 ================================
    JMP  start           ; 入口: 跳过子程序区

; ---- 子程序: axi_write  (addr=r2r1, data=r6r5r4r3) ----
axi_write:
aw_poll:
    LD   r0, 0x40        ; 桥状态口
    SHR  r0              ; C <- bit0 (busy)
    JC   aw_poll
    ST   0x02, r3
    ST   0x03, r4
    ST   0x04, r5
    ST   0x05, r6
    ST   0x00, r1
    ST   0x01, r2
    MOVI r0, 0x06
    ST   0x06, r0        ; 触发写
    RET

; ---- 子程序: axi_read  (addr=r2r1 → 结果 r6..r3) ----
axi_read:
ar_poll:
    LD   r0, 0x40
    SHR  r0
    JC   ar_poll
    ST   0x00, r1
    ST   0x01, r2
    MOVI r0, 0x07
    ST   0x07, r0        ; 触发读
ar_wait:
    LD   r0, 0x40
    SHR  r0
    JC   ar_wait
    LD   r3, 0x42        ; 结果字节 b0..b3
    LD   r4, 0x43
    LD   r5, 0x44
    LD   r6, 0x45
    RET

; ================================ 主程序 ================================
start:
    ; --- 读 ID (0x000) 验证总线通 ---
    MOVI r1, 0x00
    MOVI r2, 0x00
    CALL axi_read        ; ID = {chip_id, 16'h0001} → r6=ID[31:24]
    MOVI r0, 0x56
    CMP  r6, r0
    JZ   id_pass
    HALT                 ; ID 非 0x56xxxxxx: 总线异常, 停机
id_pass:
    ; --- MODE = 1 (0x004) ---
    MOVI r1, 0x04
    MOVI r2, 0x00
    MOVI r3, 0x01
    MOVI r4, 0x00
    MOVI r5, 0x00
    MOVI r6, 0x00
    CALL axi_write
    ; --- TH_LO = 200 (0x00C) ---
    MOVI r1, 0x0C
    MOVI r3, 0xC8
    MOVI r4, 0x00
    MOVI r5, 0x00
    MOVI r6, 0x00
    CALL axi_write
    ; --- th16 初值 = 37 (TH_HI=592) ---
    MOVI r7, 37

; ---------------- 自适应主循环 ----------------
main_loop:
    ; 写 TH_HI = r7*16 (0x008):  b0 = r7<<4, b1 = r7>>4
    MOV  r0, r7
    SHL  r0
    SHL  r0
    SHL  r0
    SHL  r0
    MOV  r3, r0          ; b0
    MOV  r0, r7
    SHR  r0
    SHR  r0
    SHR  r0
    SHR  r0
    MOV  r4, r0          ; b1
    MOVI r5, 0x00
    MOVI r6, 0x00
    MOVI r1, 0x08
    MOVI r2, 0x00
    CALL axi_write
    ; 启动 SNN: 0x020 = 1
    MOVI r1, 0x20
    MOVI r3, 0x01
    MOVI r4, 0x00
    MOVI r5, 0x00
    MOVI r6, 0x00
    CALL axi_write
    ; 读 SNN_CNT[0] (0x030) → scratch[0]
    MOVI r1, 0x30
    MOVI r2, 0x00
    CALL axi_read
    ST   0x50, r3
    ; 读 SNN_CNT[1] (0x034) → scratch[1]
    MOVI r1, 0x34
    MOVI r2, 0x00
    CALL axi_read
    ST   0x51, r3
    ; activity = (s0>>1)+(s1>>1)
    LD   r0, 0x50
    SHR  r0
    LD   r3, 0x51
    SHR  r3
    ADD  r3, r0          ; r3 = activity
    ; --- activity > 96 → 升阈值 ---
    MOVI r0, 96
    CMP  r3, r0
    JC   chk_lo          ; C=1 表示 activity<96
    MOVI r0, 61          ; th16 上界 61 (TH_HI=976)
    CMP  r7, r0
    JNC  do_delay        ; r7>=61 → 夹住
    ADDI r7, 1
    JMP  do_delay
    ; --- activity < 32 → 降阈值 ---
chk_lo:
    MOVI r0, 32
    CMP  r3, r0
    JNC  do_delay        ; activity>=32 → 不动
    MOVI r0, 14          ; th16 下界 14 (TH_HI=224)
    CMP  r7, r0
    JC   do_delay        ; r7<=14 → 夹住
    SUBI r7, 1
    ; --- 延时 (~8×51k 拍 @50MHz ≈ 8ms, 每帧一调) ---
do_delay:
    MOVI r0, 8
wait_l:
    WAIT 200             ; 200×256 = 51200 拍
    SUBI r0, 1
    JNZ  wait_l
    JMP  main_loop
