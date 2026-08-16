`timescale 1ns/1ps
// ============================================================================
// color_map — 显示模式映射 (计划 §.4 模式定义)
//   mode 0: 原始灰度            R=G=B=gray
//   mode 1: Canny 叠加 (红)     edge ? FF0000 : 灰度
//   mode 2: SNN 活动热力图      16 神经元计数 -> 伪彩条 (按行显示计数)
//   mode 3: edge + SNN 混合     edge 红叠加, 其余灰度*SNN 亮度调制
//   输入为显示窗口坐标处的 {gray, edge}; snn 活动为 16x8bit 热度向量
// ============================================================================
module color_map (
    input  wire clk,
    input  wire rst_n,

    input  wire [1:0]  mode,
    input  wire [7:0]  gray,
    input  wire        edge_bit,
    input  wire [7:0]  snn_heat [0:15],  // 每 16 行带一个神经元的计数
    input  wire [12:0] disp_y,           // 显示行号
    input  wire        in_de,            // 显示窗口 DE

    output reg  [23:0] rgb,              // {R,G,B} 8:8:8
    output reg         out_de
);

    reg [1:0] mode_r;
    reg [7:0] gray_r;
    reg       edge_r;
    reg       de_r;
    reg [7:0] heat_r;

    // 热图: 每 V_ACT/16 行取一个神经元计数
    wire [3:0] neu_sel = disp_y[12:4] > 15 ? 4'd15 : disp_y[12:4];
    // 720/16 = 45 行/神经元: y/45 = y*~0.0233 -> 用 y[12:6] 近似 (64行/带)
    wire [3:0] neu_sel2 = disp_y[12:6] > 15 ? 4'd15 : disp_y[12:6];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rgb <= 0; out_de <= 0;
            mode_r <= 0; gray_r <= 0; edge_r <= 0; de_r <= 0; heat_r <= 0;
        end else begin
            mode_r <= mode;
            gray_r <= gray;
            edge_r <= edge_bit;
            de_r   <= in_de;
            heat_r <= snn_heat[neu_sel2];

            out_de <= de_r;   // 两拍流水

            case (mode_r)
                2'd0: rgb <= {gray_r, gray_r, gray_r};
                2'd1: rgb <= edge_r ? 24'hFF2000
                                    : {gray_r, gray_r, gray_r};
                2'd2: begin
                    // 热力条: R=heat, G=heat/2, B=~heat (亮=活动强)
                    rgb <= {heat_r, heat_r[7:1], ~heat_r};
                end
                default: begin
                    // 混合: 边缘红; 灰度用 heat 调制亮度
                    rgb <= edge_r ? 24'hFF4000
                                  : {gray_r & heat_r, gray_r & heat_r[7:1],
                                     gray_r & heat_r};
                end
            endcase
        end
    end

endmodule
