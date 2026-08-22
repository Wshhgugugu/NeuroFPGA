# 寄存器手册 (axi_crossbar_wrap, AXI4-Lite, 基址 0x40000000)

| 偏移 | 名称 | 类型 | 复位值 | 说明 |
|---|---|---|---|---|
| 0x000 | ID      | RO | 0x5640_0001 | chip_id[15:0]=0x5640, 版本 1 |
| 0x004 | MODE    | RW | 0 | 显示模式 0..3 (mode_switch 场消隐期生效) |
| 0x008 | TH_HI   | RW | 600 | Canny 高阈值 [11:0] (==th 归 strong) |
| 0x00C | TH_LO   | RW | 200 | Canny 低阈值 [11:0] (==th 归 weak) |
| 0x010 | SNN_VTH | RW | 8<<16 | LIF 阈值 Q8.16 |
| 0x014 | SNN_ACT_W| WO | - | [5:0]通道号 [15:8]活动值 (一次一路) |
| 0x018 | STATUS  | RO | - | [0]id_ok [1]cfg_done [2]snn_done [3]snn_busy |
|      |         |    |   | [4]canny_busy [8]addr_err |
| 0x020 | SNN_CTRL| WO | - | bit0: run_start 脉冲 (自清) |
| 0x030+4n | SNN_CNT[n] | RO | 0 | 神经元 n 尖峰计数, n=0..15 |

| 0x080 | HIST_ADDR | RW | 0 | 写: 直方图 bin 地址 [7:0]; 读: 该 bin 计数 [15:0] |
| 0x084 | HIST_DONE | RO | 0 | bit0: 本帧直方图就绪 (冻结至下一帧 sof) |

(注: 0x048~0x06C 属 SNN_CNT 区间, 新寄存器避开; 直方图帧间冻结, CPU 从容读取)

非法地址: 读 0xDEAD_BEEF, 写丢弃并置 STATUS.addr_err。
