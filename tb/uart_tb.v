`default_nettype none

// Testbench for uart_tx and uart_rx: loopback (tx output drives rx input).
// Sends all 256 byte values back to back and checks each received byte.
module uart_tb;

    localparam CLOCK_FREQUENCY = 100_000_000;
    localparam BAUD_RATE       = 10_000_000;    // 10 clock cycles per bit: fast simulation

    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg  [7:0] tx_data;
    reg        tx_valid = 1'b0;
    wire       tx_ready;
    wire       line;
    wire [7:0] rx_data;
    wire       rx_valid, framing_error;

    always #5 clk = ~clk;   // 100 MHz

    uart_tx #(
        .CLOCK_FREQUENCY (CLOCK_FREQUENCY),
        .BAUD_RATE       (BAUD_RATE)
    ) u_tx (
        .clk   (clk),
        .rst   (rst),
        .data  (tx_data),
        .valid (tx_valid),
        .ready (tx_ready),
        .tx    (line)
    );

    uart_rx #(
        .CLOCK_FREQUENCY (CLOCK_FREQUENCY),
        .BAUD_RATE       (BAUD_RATE)
    ) u_rx (
        .clk           (clk),
        .rst           (rst),
        .rx            (line),
        .data          (rx_data),
        .data_valid    (rx_valid),
        .framing_error (framing_error)
    );

    integer errors   = 0;
    integer received = 0;
    integer t;

    // check each received byte: byte number k must have the value k
    always @(posedge clk) begin
        if (rx_valid) begin
            if (rx_data !== received[7:0]) begin
                $display("ERROR: byte %0d: received %h, expected %h", received, rx_data, received[7:0]);
                errors = errors + 1;
            end
            received = received + 1;
        end
        if (framing_error) begin
            $display("ERROR: framing error");
            errors = errors + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // send 0..255 with the valid/ready handshake.
        // Drive and sample on the falling edge, so there is no race with the rising edge.
        for (t = 0; t < 256; t = t + 1) begin
            @(negedge clk);
            tx_data  = t;
            tx_valid = 1'b1;
            while (!tx_ready) @(negedge clk);
            @(negedge clk);              // the rising edge before this accepted the byte
            tx_valid = 1'b0;
        end

        // wait for the last byte to arrive
        repeat (200) @(posedge clk);

        if (received != 256) begin
            $display("ERROR: received %0d bytes, expected 256", received);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: uart_tb");
        else             $display("FAIL: uart_tb, %0d errors", errors);
        $finish;
    end

endmodule
