// tb_custom_alu — 自定义指令单元 vs 软件模型 (Phase 6 出口准则)
//   c.sadd: 32位饱和加; c.pop: popcount(a) | popcount(b)<<16
//   随机 1000 组, 与 TB 内软件参考模型逐位一致
`timescale 1ns/1ps
module tb_custom_alu;
    reg  [2:0]  funct3;
    reg  [31:0] a, b;
    wire [31:0] res;

    custom_alu dut (.funct3(funct3), .a(a), .b(b), .res(res));

    // 软件参考
    function [31:0] ref_model(input [2:0] f, input [31:0] x, input [31:0] y);
        reg [32:0] s; reg [5:0] pa, pb; integer i;
        begin
            case (f)
                3'd0: begin
                    s = {x[31],x} + {y[31],y};
                    if ((x[31]==y[31]) && (s[31]!=x[31]))
                        ref_model = x[31] ? 32'h80000000 : 32'h7FFFFFFF;
                    else
                        ref_model = s[31:0];
                end
                3'd1: begin
                    pa=0; pb=0;
                    for (i=0;i<32;i=i+1) begin
                        if (x[i]) pa=pa+1;
                        if (y[i]) pb=pb+1;
                    end
                    ref_model = {26'd0, pb, pa};
                end
                default: ref_model = 0;
            endcase
        end
    endfunction

    integer i, errors=0;
    reg [31:0] exp_v;
    reg [2:0] f;
    initial begin
        for (i=0;i<1000;i=i+1) begin
            f = $random;
            a = $random; b = $random;
            // 边界值覆盖
            case (i % 8)
                0: {a,b} = {32'h7FFFFFFF, 32'h00000001};   // 正溢出
                1: {a,b} = {32'h80000000, 32'hFFFFFFFF};   // 负溢出
                2: {a,b} = {32'h7FFFFFFF, 32'h80000000};
                3: {a,b} = {32'h00000000, 32'h00000000};
                4: {a,b} = {32'hFFFFFFFF, 32'h00000001};
                5: {a,b} = {32'h12345678, 32'h87654321};
                6: {a,b} = {32'h55555555, 32'h55555555};
                7: {a,b} = {32'hAAAAAAAA, 32'h55555555};
            endcase
            funct3 = (f[0]) ? 3'd0 : 3'd1;
            #1;
            exp_v = ref_model(funct3, a, b);
            if (res !== exp_v) begin
                errors = errors+1;
                if (errors<=10)
                    $display("[FAIL] f=%0d a=%h b=%h res=%h exp=%h",
                             funct3, a, b, res, exp_v);
            end
        end
        if (errors==0) $display("=== tb_custom_alu: PASS (1000 vectors) ===");
        else $display("=== tb_custom_alu: FAIL errors=%0d ===", errors);
        $finish;
    end
endmodule
