// ============================================================================
// axi_stream_pkg — 轻量 AXI-Stream 约定 (计划书 D1)
//   全流水线统一使用: tdata / tvalid / tready / tlast(EOL) / tuser(SOF)
//   tuser[0] = 帧内第一个像素; tlast = 行内最后一个像素
//   背压: 下游 tready 拉低时上游必须保持 tdata/tvalid 不变
// ============================================================================
package axi_stream_pkg;

  // 定点位宽规划 (架构文档 §.3, 冻结)
  localparam int PW_GRAY   = 8;   // 灰度像素
  localparam int PW_GRAD   = 12;  // Scharr Gx/Gy / 幅值
  localparam int PW_DIR    = 2;   // 量化方向
  localparam int PW_CLASS  = 2;   // 双阈值分类 0=非边缘 1=weak 2=strong

  // 图像默认几何 (640x480 摄像头帧; 仿真用 64x64 覆盖)
  localparam int IMG_W_DEFAULT = 640;
  localparam int IMG_H_DEFAULT = 480;

  // Canny 默认阈值 (12-bit 域, 寄存器可配)
  localparam logic [11:0] TH_HIGH_DEFAULT = 12'd600;
  localparam logic [11:0] TH_LOW_DEFAULT  = 12'd200;

endpackage
