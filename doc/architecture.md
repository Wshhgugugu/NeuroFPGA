# Sim_GPU 视觉加速系统 · 架构文档 v1.0

## 数据面
OV5640 (DVP RGB565 VGA@30, PCLK≈56MHz 接 W17 时钟脚) → ov5640_ctrl (PCLK 域,
RGB565→灰度 (R>>2+G>>1+B>>2)) → fifo_async (CDC pclk→proc) → canny_top (proc)
→ hysteresis 帧存迭代 → edge 流 → SNN 8x8 池化 → snn_top; 显示走 vga_timing +
color_map + hdmi_tx (TMDS 码字输出, 本板无 HDMI, Phase 9 走 ST7789 LCD)。

## Canny 链 (顺序冻结, RTL 与 golden_model.py 逐位一致)
gaussian_5x5 → scharr_3x3 → gradient_mag_dir → median_3x3 → nms →
double_threshold → hysteresis

## 关键实现决策 (与计划书对应)
- D3 CDC: 数据流只用 fifo_async, 控制位只用 sync_2ff / 值稳定两拍
- 窗口引擎 window_kxk (K=3/5 通用): BRAM bank 行存, bank=行号% (K-1),
  同拍同址读旧写新 (read-first) 取最老行; **边界=零填充** (行计数判零,
  列由行尾补零移位), 与 golden 一致
- 流契约: 每行 W 像素, 行间 ≥2*HALF 空拍, 帧首像素带 sof; 链内级间无背压
  (hysteresis busy 期间整帧丢弃, 由顶层门控)
- D4 高斯: 可分离 [1,4,6,4,1]², (acc+128)>>8 四舍五入, 全移位加
- D5/D6: |Gx|+|Gy| 饱和 12-bit; 方向量化整数比较 10000/4142/24142 (==归下侧)
- D7 迟滞: weak/strong 两张 1-bit 帧图, 帧内迭代 (窗口引擎读图原地晋升,
  发射滞后读 2 行保证安全), 迭代至不动点 — 与 golden 同一不动点 (Python 验证)
- median: 恒等式 median(max 行min, min 行max, median 行med) — 已穷举 362880
  排列 + 2 万随机验证; 19 比较器
- SNN (D8): 速率编码 PWM; LIF Q8.16, 泄漏 v>>4, 不应期 2 步, 饱和 ±(128<<16);
  16 神经元 × 64 通道单 MAC 时分 (1024 拍/步, 64 步/帧); golden_model_snn.py
  定点镜像, tb_lif 尖峰计数逐位一致
- 显示: vga_timing 参数化 (720p60 默认); hdmi_tx TMDS 编码器 (最小跳变 +
  可证有界直流平衡 |disp|≤4, tb_display 往返/平衡/跳变全验证)

## 时钟域
| 域 | 来源 | 说明 |
|---|---|---|
| cfg 50MHz | 板载晶振 | SCCB/寄存器面/软控制 |
| pclk ~56MHz | OV5640 W17 | 采集域 (cfg_done 后释放复位) |
| proc 150MHz | MMCM | canny/snn (仿真可 -d SIMPLIFIED_CLK 直通) |
| pix 74.25MHz | MMCM | 显示时序 |

## 寄存器堆 (AXI4-Lite, 见 register_map.md)
vexriscv_wrapper 默认 SOFT_CTRL=1: 软 FSM 完成配置序列; VexRiscv 预生成
网表接入点已留 (SOFT_CTRL=0 + vexriscv_netlist.v)。

## 已知未决项 (Phase 7 遗留)
1. tb_vision_top 端到端: CDC 读侧使能时序修复后仍剩 ~330/4096 像素错位,
   表现为 dt 链首 4 像素 X 污染 (子级 tb_canny/tb_hyst 均 bit-exact,
   含随机行中气泡; 问题定位在 vision_top FIFO 读/行间隙配合, 待下一轮)
2. 显示帧缓冲 (proc→pix 双时钟帧存) 留 Phase 9 板级适配
3. clk_wiz_vision MMCM 封装待 Vivado IP 生成 (当前仅仿真直通模式)
