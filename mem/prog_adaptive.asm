; ============================================================================
; prog_adaptive.asm — mcu8 自动阈值控制 v2 (直方图百分位)
;
;   硬件: hist_256 统计 ch0 NMS 幅值 (mag>=128 的强候选, 256 bin × 16bit)
;   算法 (单遍自顶向下扫描, "边预算"法):
;     total = 0
;     for bin = 255 downto 8:
;        total += bin_cnt[bin]        (16-bit 累加, 进位入高字节)
;        if TH_HI 未定 and total >= 800 :  TH_HI = bin×16
;        if total >= 4000              :  TH_LO = bin×16 ; 停
;     未达预算 → TH_HI=600 / TH_LO=200 (保守默认)
;   另保留 SNN 周期启动 (演示路径)
;
;   寄存器约定 (不变):
;     r1/r2 = AXI 地址, r3..r6 = 数据字节, r0 = 子程序临时
;     r7 = 扫描循环 bin 计数
;   scratch: [0]=total_lo [1]=total_hi [2]=TH_HI bin [3]=TH_LO bin
;            [4]=TH_HI 已定标志
; ============================================================================

    JMP  start           ; 入口: 跳过子程序区

; ---- 子程序: axi_write (addr=r2r1, data=r6r5r4r3) ----
axi_write:
aw_poll:
    LD   r0, 0x40
    SHR  r0
    JC   aw_poll
    ST   0x02, r3
    ST   0x03, r4
    ST   0x04, r5
    ST   0x05, r6
    ST   0x00, r1
    ST   0x01, r2
    MOVI r0, 0x06
    ST   0x06, r0
    RET

; ---- 子程序: axi_read (addr=r2r1 → r6..r3) ----
axi_read:
ar_poll:
    LD   r0, 0x40
    SHR  r0
    JC   ar_poll
    ST   0x00, r1
    ST   0x01, r2
    MOVI r0, 0x07
    ST   0x07, r0
ar_wait:
    LD   r0, 0x40
    SHR  r0
    JC   ar_wait
    LD   r3, 0x42
    LD   r4, 0x43
    LD   r5, 0x44
    LD   r6, 0x45
    RET

; ---- (无 hist_read 子程序: mcu8 单 LR 不支持嵌套 CALL, 扫描处内联) ----

; ================================ 主程序 ================================
start:
    ; --- 读 ID 验证总线 ---
    MOVI r1, 0x00
    MOVI r2, 0x00
    CALL axi_read
    MOVI r0, 0x56
    CMP  r6, r0
    JZ   id_pass
    HALT
id_pass:
    ; --- MODE = 1 ---
    MOVI r1, 0x04
    MOVI r3, 0x01
    MOVI r4, 0x00
    MOVI r5, 0x00
    MOVI r6, 0x00
    CALL axi_write
    ; --- 初值 TH_HI=600(0x258) TH_LO=200(0xC8) ---
    MOVI r1, 0x08
    MOVI r3, 0x58
    MOVI r4, 0x02
    MOVI r5, 0x00
    MOVI r6, 0x00
    CALL axi_write
    MOVI r1, 0x0C
    MOVI r3, 0xC8
    MOVI r4, 0x00
    CALL axi_write

; ---------------- 主循环: 等直方图就绪 → 扫描 → 写阈值 → 重启 SNN ----------------
main_loop:
    ; 等 hist_done (0x04C bit0)
hd_poll:
    MOVI r1, 0x84
    MOVI r2, 0x00
    CALL axi_read        ; r3 = bit0
    SHR  r3              ; C <- bit0
    JNC  hd_poll         ; 未就绪继续等 (SHR 后 C=done)

    ; 初始化扫描变量
    MOVI r0, 0
    ST   0x50, r0        ; total_lo = 0
    ST   0x51, r0        ; total_hi = 0
    ST   0x52, r0        ; TH_HI bin = 0 (未定)
    ST   0x53, r0        ; TH_LO bin = 0 (未定)
    ST   0x54, r0        ; 标志 = 0
    MOVI r7, 255         ; bin 计数

    ; --- 扫描: bin 255 downto 8 (内联读: 写 HIST_ADDR=bin 再读 0x048) ---
scan_loop:
    MOVI r1, 0x80
    MOVI r2, 0x00
    MOV  r3, r7          ; 数据 = bin 号
    MOVI r4, 0x00
    MOVI r5, 0x00
    MOVI r6, 0x00
    CALL axi_write
    MOVI r1, 0x80
    MOVI r2, 0x00
    CALL axi_read        ; r3=cnt_lo r4=cnt_hi
    ; total += cnt (16-bit): 进位用 r5 传 (MOVI 不动标志, 但这里先 JC 分支)
    LD   r0, 0x50
    ADD  r0, r3
    ST   0x50, r0        ; total_lo 更新, C=进位
    JC   add_carry
    MOVI r5, 0
    JMP  add_hi
add_carry:
    MOVI r5, 1
add_hi:
    LD   r0, 0x51
    ADD  r0, r4
    ADD  r0, r5          ; + 进位
    ST   0x51, r0

chk_hi:
    ; TH_HI 未定且 total >= 800 (0x320)?
    LD   r0, 0x54
    MOVI r3, 1
    CMP  r0, r3
    JZ   chk_lo          ; 已定, 跳过
    ; 16-bit 比较: (hi,lo) >= (3, 32)?  800 = 0x0320
    LD   r0, 0x51
    MOVI r3, 3
    CMP  r0, r3
    JC   chk_lo          ; hi < 3 → 不够
    JZ   cmp_lo800       ; hi == 3 → 比 lo
    JMP  set_hi          ; hi > 3 → 够了
cmp_lo800:
    LD   r0, 0x50
    MOVI r3, 0x20        ; 800 & 0xFF = 0x20
    CMP  r0, r3
    JNC  set_hi          ; lo >= 0x20 → 够
    JMP  chk_lo
set_hi:
    MOV  r0, r7
    ST   0x52, r0        ; TH_HI bin = 当前 bin
    MOVI r0, 1
    ST   0x54, r0        ; 标志置位

chk_lo:
    ; total >= 4000 (0x0FA0)?
    LD   r0, 0x51
    MOVI r3, 15          ; 4000>>8 = 15
    CMP  r0, r3
    JC   scan_next       ; hi < 15 → 继续
    JZ   cmp_lo4000
    JMP  set_lo          ; hi > 15 → 够
cmp_lo4000:
    LD   r0, 0x50
    MOVI r3, 0xA0        ; 4000 & 0xFF
    CMP  r0, r3
    JNC  set_lo
    JMP  scan_next

scan_next:
    SUBI r7, 1
    MOVI r0, 8
    CMP  r7, r0
    JC   scan_done       ; r7 < 8 → 到底
    JMP  scan_loop

set_lo:
    MOV  r0, r7
    ST   0x53, r0        ; TH_LO bin
    JMP  apply

scan_done:
    ; 扫到底仍没到预算 → 默认值 (保守)
    MOVI r0, 0
    ST   0x52, r0
    ST   0x53, r0

apply:
    ; --- 写 TH_HI = bin[0x52]×16 (bin=0 → 默认 600) ---
    ; TH = bin<<4: b0 = (bin<<4)&0xFF, b1 = bin>>4
    LD   r0, 0x52
    MOVI r3, 0
    CMP  r0, r3
    JZ   def_hi
    MOV  r5, r0          ; 暂存 bin
    SHL  r0
    SHL  r0
    SHL  r0
    SHL  r0
    MOV  r3, r0          ; b0
    MOV  r0, r5
    SHR  r0
    SHR  r0
    SHR  r0
    SHR  r0
    MOV  r4, r0          ; b1
    JMP  wr_hi
def_hi:
    MOVI r3, 0x58
    MOVI r4, 0x02
wr_hi:
    MOVI r5, 0x00
    MOVI r6, 0x00
    MOVI r1, 0x08
    MOVI r2, 0x00
    CALL axi_write

    ; --- 写 TH_LO = bin[0x53]×16 (0 → 默认 200) ---
    LD   r0, 0x53
    MOVI r3, 0
    CMP  r0, r3
    JZ   def_lo
    MOV  r5, r0
    SHL  r0
    SHL  r0
    SHL  r0
    SHL  r0
    MOV  r3, r0
    MOV  r0, r5
    SHR  r0
    SHR  r0
    SHR  r0
    SHR  r0
    MOV  r4, r0
    JMP  wr_lo
def_lo:
    MOVI r3, 0xC8
    MOVI r4, 0x00
wr_lo:
    MOVI r5, 0x00
    MOVI r6, 0x00
    MOVI r1, 0x0C
    MOVI r2, 0x00
    CALL axi_write

    ; --- 重启 SNN (演示) ---
    MOVI r1, 0x20
    MOVI r3, 0x01
    MOVI r4, 0x00
    MOVI r5, 0x00
    MOVI r6, 0x00
    CALL axi_write

    ; --- 延时 (帧级节流; 直方图 done 是逐帧的, 这里避免总线上过度轮询) ---
    MOVI r0, 4
wait_l:
    WAIT 200
    SUBI r0, 1
    JNZ  wait_l
    JMP  main_loop
