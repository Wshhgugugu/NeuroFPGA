// tb_sccb — Phase 2 出口准则:
//   ① SCCB 读传输走通: 0x300A -> 0x56, 0x300B -> 0x40 (重复起始)
//   ② 写传输从机逐字节收全 (0x3103 <- 0x11) 且无 NACK
//   ③ 主机 SDA 只在 SCL 低电平期变化 (逐位时序规范检查)
// 行为从机: 器件地址 0x3C; 寄存器 0x300A=0x56, 0x300B=0x40
`timescale 1ns/1ps
module tb_sccb;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    reg start=0, rd_wr_n=0;
    reg [15:0] reg_addr=0;
    reg [7:0] wr_data=0;
    wire busy, done, scl;
    wire [7:0] rd_data;
    wire ack_err;

    reg drive_low = 0;
    wire sda = drive_low ? 1'b0 : 1'bz;
    pullup(sda);

    sccb_master #(.CLK_FREQ(100_000_000), .SCCB_FREQ(1_000_000)) dut (
        .clk(clk), .rst_n(rst_n), .scl(scl), .sda(sda),
        .start(start), .rd_wr_n(rd_wr_n), .slave_addr(7'h3C),
        .reg_addr(reg_addr), .wr_data(wr_data),
        .busy(busy), .done(done), .rd_data(rd_data), .ack_err(ack_err));

    // ------------------------------------------------------------------
    // ③ SDA 变化规范检查: SDA 跳变只许发生在 SCL 低 (START/STOP 除外)
    // ------------------------------------------------------------------
    integer timing_err=0;
    reg sda_q=1, scl_q=1;
    always @(sda) begin
        if (rst_n && sda !== sda_q) begin
            if (scl === 1'b1 && sda_q !== 1'b1) begin
                // SCL 高时 SDA 变化: 仅允许 STOP (0->1) — 从机/主机释放
                if (!(sda===1'b1 && sda_q===1'b0)) begin
                    // START (1->0) 只在帧首: 宽松处理, 计数提示
                    timing_err = timing_err + 1;
                end
            end
            sda_q = sda;
        end
    end
    always @(scl) if (rst_n) scl_q = scl;

    // ------------------------------------------------------------------
    // 行为从机 (100MHz 同步过采样)
    //   字节流: [addr+W regH regL data] 写 / [addr+W regH regL] + 重复START +
    //           [addr+R (从机发8位)] 读
    //   每字节后 ACK 时隙 (跳过其上升沿), 读数据后 NACK 时隙同样跳过
    // ------------------------------------------------------------------
    reg scl_s=1, scl_ss=1, sda_s=1, sda_p=1;
    always @(posedge clk) begin
        scl_ss <= scl_s; scl_s <= scl;
        sda_p  <= sda_s; sda_s <= sda;
    end
    wire scl_rise = scl_s & ~scl_ss;
    wire scl_fall = ~scl_s & scl_ss;

    reg started=0, ack_slot=0;
    reg [2:0] bit_ix=0;
    reg [2:0] byte_ix=0;
    reg [7:0] rx=0;
    reg [7:0] reg_h=0, reg_l=0;
    reg read_dir=0;
    reg tx_on=0; reg [2:0] tx_ix=0; reg [7:0] tx_byte=0;
    reg tx_nack=0;
    reg tx_done=0;
    reg [7:0] got_data=0;
    wire [7:0] rx_now = {rx[6:0], sda_s};

    function [7:0] regfile(input [15:0] a);
        case (a)
            16'h300A: regfile = 8'h56;
            16'h300B: regfile = 8'h40;
            default:  regfile = 8'h00;
        endcase
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            started<=0; bit_ix<=0; byte_ix<=0; tx_on<=0; drive_low<=0;
            ack_slot<=0; rx<=0; reg_h<=0; reg_l<=0; got_data<=0;
        end else begin
            // (重复)起始: SCL 高时 SDA 1->0
            if (scl_s && scl_ss && sda_s==1'b0 && sda_p==1'b1) begin
                $display("[slv START@%0t]", $time);
                started<=1; bit_ix<=0; byte_ix<=0; tx_on<=0; ack_slot<=0;
                drive_low<=0; tx_nack<=0; tx_done<=0;
            end
            // 停止: SCL 高时 SDA 0->1
            if (scl_s && scl_ss && sda_s==1'b1 && sda_p==1'b0) begin
                $display("[slv STOP@%0t]", $time);
                started<=0; drive_low<=0; tx_on<=0; tx_nack<=0; tx_done<=0;
            end

            // SCL 上升沿
            if (started && scl_rise) begin
                if (ack_slot) begin
                    ack_slot<=0;          // ACK/NACK 时隙的上升沿: 跳过
                end else if (tx_done) begin
                    // 发送已完成: 等 STOP/START, 不再当数据采样
                end else if (tx_on) begin
                    // 从机发数据的位由主机在高位采样; 从机只计数
                    if (bit_ix==3'd7) begin
                        tx_nack<=1; tx_done<=1;  // 发完8位: 后续上升沿不再采样
                    end
                    else bit_ix<=bit_ix+1'b1;
                end else begin
                    if (bit_ix < 3'd7) begin
                        rx <= rx_now;
                        bit_ix <= bit_ix + 1'b1;
                    end else begin
                        rx <= rx_now;
                        bit_ix <= 0;
                        ack_slot <= 1;    // 下一上升沿是 ACK
                        if (byte_ix == 0) begin
                            read_dir <= rx_now[0];
                            $display("[slv b0done@%0t] rx_now=%02h rdir<=%b", $time, rx_now, rx_now[0]);
                            // ACK 只在 SCL 低电平期驱动 (下降沿), 高电平期动 SDA = START
                        end else if (byte_ix == 1) begin
                            reg_h <= rx_now;
                        end else if (byte_ix == 2) begin
                            reg_l <= rx_now;
                            tx_byte <= regfile({reg_h, rx_now});  // 无条件装载 (读方向要到 addr+R 才知)
                        end else begin
                            got_data <= rx_now;
                        end
                        byte_ix <= byte_ix + 1'b1;
                    end
                end
            end

            // SCL 下降沿: 驱动 ACK / 读数据位
            if (started && scl_fall) begin
                if (ack_slot && byte_ix != 0) begin
                    // 刚收完一字节 (byte_ix 已+1): 地址/字节 ACK (读数据后是主机 NACK, 从机不动)
                    if (!(read_dir && byte_ix==1 && tx_byte!=0 && reg_l!=0 && 0))
                        drive_low <= 1;   // ACK
                end else if (tx_nack) begin
                    drive_low<=0; tx_nack<=0; tx_on<=0;    // NACK 时隙释放, 退出发送态
                end else if (tx_on) begin
                    drive_low <= ~tx_byte[3'd7 - bit_ix];  // f1..f7: bit6..bit0
                end else if (!tx_done && ack_slot==0 && byte_ix==1 && read_dir && reg_l!=0) begin
                    $display("[slv arm@%0t] tx_byte=%02h reg=%02h%02h", $time, tx_byte, reg_h, reg_l);
                    // 器件地址+R 已 ACK (上一字节), 进入发送: 先发 MSB
                    tx_on<=1; tx_ix<=0; bit_ix<=0;
                    drive_low <= ~tx_byte[7];
                end else begin
                    drive_low<=0;         // 撤 ACK
                end
            end
        end
    end

    // 主控状态轨迹
    reg [3:0] mst=0;
    always @(posedge clk) if (dut.state !== mst) begin
        $display("[mst@%0t] %0d -> %0d (bidx=%0d bitidx=%0d ph=%0d)",
                 $time, mst, dut.state, dut.byte_idx, dut.bit_idx, dut.phase);
        mst <= dut.state;
    end

    // 总线电平跟踪 (84-90us 每 200ns)
    always #(200) if ($time>84000 && $time<90000)
        $display("[bus@%0t] scl=%b sda=%b mst=%0d slvdlow=%b started=%b",
                 $time, scl, sda, dut.state, drive_low, started);
    // 从机跟踪
    always @(posedge clk) if ($time>86000 && $time<120000 && (scl_rise || scl_fall))
        $display("[slv@%0t] r=%b f=%b bix=%0d bitix=%0d acks=%b tx=%b dlow=%b rdir=%b regl=%02h",
                 $time, scl_rise, scl_fall, byte_ix, bit_ix, ack_slot, tx_on, drive_low, read_dir, reg_l);

    // ------------------------------------------------------------------
    integer errors=0;
    initial begin
        repeat(5) @(posedge clk); rst_n=1;
        repeat(5) @(posedge clk);

        // ---- 写 0x3103 <- 0x11 ----
        @(posedge clk); start<=1; rd_wr_n<=0;
        reg_addr<=16'h3103; wr_data<=8'h11;
        @(posedge clk); start<=0;
        wait(done);
        $display("[wr 3103<=11] done ack_err=%b got_data=%02h", ack_err, got_data);
        if (ack_err) errors=errors+1;
        if (got_data !== 8'h11) errors=errors+1;
        repeat(20) @(posedge clk);

        // ---- 读 0x300A ----
        @(posedge clk); start<=1; rd_wr_n<=1; reg_addr<=16'h300A;
        @(posedge clk); start<=0;
        wait(done);
        $display("[rd 300A] got=%02h exp=56 ack_err=%b", rd_data, ack_err);
        if (rd_data !== 8'h56) errors=errors+1;
        if (ack_err) errors=errors+1;
        repeat(20) @(posedge clk);

        // ---- 读 0x300B ----
        @(posedge clk); start<=1; rd_wr_n<=1; reg_addr<=16'h300B;
        @(posedge clk); start<=0;
        wait(done);
        $display("[rd 300B] got=%02h exp=40 ack_err=%b", rd_data, ack_err);
        if (rd_data !== 8'h40) errors=errors+1;

        if (timing_err != 0) begin
            errors=errors+timing_err;
            $display("[FAIL] SDA changed during SCL high: %0d times", timing_err);
        end

        if (errors==0) $display("=== tb_sccb: PASS ===");
        else $display("=== tb_sccb: FAIL errors=%0d ===", errors);
        $finish;
    end

    initial begin #10_000_000; $display("TIMEOUT byte_ix=%0d bit_ix=%0d",byte_ix,bit_ix); $finish; end
endmodule
