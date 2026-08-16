`timescale 1ns/1ps

module tb_syn;
    reg clk=0; always #5 clk=~clk;
    reg rd_en=0; reg [3:0] n=0; reg [5:0] j=0;
    wire signed [7:0] w;
    synapse_array #(.NNEU(16),.NIN(64)) dut(.clk(clk),.rd_en(rd_en),.cur_n(n),.cur_j(j),.w(w));
    integer k;
    initial begin
        #12;
        $display("mem[0]=%0d mem[1]=%0d mem[1023]=%0d", dut.mem[0], dut.mem[1], dut.mem[1023]);
        $finish;
    end
endmodule
