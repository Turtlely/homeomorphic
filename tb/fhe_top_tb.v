`default_nettype none

// System testbench for fhe_top.
// The testbench acts as the PC: it sends protocol bytes on UART_RXD and
// receives the replies on UART_TXD. It uses a fast baud rate for simulation.
//
// Tests:
//   1. Ping
//   2. Encrypt "hello world" and decrypt the reply in the testbench
//   3. Send the ciphertexts back for capitalize, decrypt to "HELLO WORLD"
//   4. 64 characters (the maximum) through encrypt and capitalize
//   5. Errors: unknown command, bad length, timeout. Ping must work after each error.
module fhe_top_tb;

    localparam CLOCK_FREQUENCY = 100_000_000;
    localparam BAUD_RATE       = 10_000_000;
    localparam CPB             = CLOCK_FREQUENCY / BAUD_RATE;   // clock cycles per bit
    localparam TIMEOUT_CYCLES  = 5000;
    localparam MAX_LEN         = 64;

    localparam [15:0] P     = 16'd40009;
    localparam [31:0] X0    = (32'hFFFF_FFFF / P) * P;

    reg        clk = 1'b0;
    reg        uart_rxd = 1'b1;     // PC -> FPGA
    wire       uart_txd;            // FPGA -> PC
    wire [3:0] led;

    always #5 clk = ~clk;

    fhe_top #(
        .CLOCK_FREQUENCY (CLOCK_FREQUENCY),
        .BAUD_RATE       (BAUD_RATE),
        .MAX_LEN         (MAX_LEN),
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES),
        .PRNG_SEED       (32'h1234_5678),
        .POR_BITS        (4)
    ) dut (
        .CLK_100MHZ (clk),
        .BTN        (1'b0),
        .UART_RXD   (uart_rxd),
        .UART_TXD   (uart_txd),
        .LED        (led)
    );

    integer errors = 0;
    integer k, i, j;

    // ---------------------------------------------------------------
    // PC side UART
    // ---------------------------------------------------------------
    task send_byte(input [7:0] b);
        begin
            uart_rxd = 1'b0;                               // start bit
            repeat (CPB) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin
                uart_rxd = b[j];
                repeat (CPB) @(posedge clk);
            end
            uart_rxd = 1'b1;                               // stop bit
            repeat (CPB) @(posedge clk);
        end
    endtask

    // the receiver runs in its own process and stores bytes in a FIFO
    reg [7:0] rx_fifo [0:4095];
    integer   rx_wr = 0;
    integer   rx_rd = 0;
    integer   rb;
    reg [7:0] rx_shift;

    initial begin
        repeat (100) @(posedge clk);                       // wait for reset
        forever begin
            @(negedge uart_txd);
            repeat (CPB / 2) @(posedge clk);               // middle of the start bit
            for (rb = 0; rb < 8; rb = rb + 1) begin
                repeat (CPB) @(posedge clk);
                rx_shift[rb] = uart_txd;
            end
            repeat (CPB) @(posedge clk);                   // middle of the stop bit
            if (uart_txd !== 1'b1) begin
                $display("ERROR: framing error from the FPGA");
                errors = errors + 1;
            end
            rx_fifo[rx_wr % 4096] = rx_shift;
            rx_wr = rx_wr + 1;
        end
    end

    task recv_byte(output [7:0] b);
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (rx_rd == rx_wr && wait_cycles < 100000) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (rx_rd == rx_wr) begin
                $display("ERROR: no reply byte from the FPGA");
                errors = errors + 1;
                b = 8'hXX;
            end else begin
                b = rx_fifo[rx_rd % 4096];
                rx_rd = rx_rd + 1;
            end
        end
    endtask

    task expect_byte(input [7:0] expected, input [8*24-1:0] what);
        reg [7:0] b;
        begin
            recv_byte(b);
            if (b !== expected) begin
                $display("ERROR: %0s: received %h, expected %h", what, b, expected);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------------------------------------------------------
    // Client model: decrypt one 256-bit character
    // ---------------------------------------------------------------
    function [7:0] decrypt_char(input [255:0] ct);
        integer n;
        begin
            for (n = 0; n < 8; n = n + 1)
                decrypt_char[n] = (ct[32*n +: 32] % P) % 2;
        end
    endfunction

    // ---------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------
    reg [255:0] ct      [0:MAX_LEN-1];   // ciphertexts from the encrypt reply
    reg [255:0] ct_cap  [0:MAX_LEN-1];   // ciphertexts from the capitalize reply
    reg [7:0]   text    [0:MAX_LEN-1];
    reg [7:0]   b;
    reg [255:0] word;

    task do_encrypt(input integer len);
        begin
            send_byte("E");
            send_byte(P[15:8]);
            send_byte(P[7:0]);
            send_byte(len);
            for (k = 0; k < len; k = k + 1)
                send_byte(text[k]);

            expect_byte("e", "encrypt reply code");
            expect_byte(len, "encrypt reply length");
            for (k = 0; k < len; k = k + 1) begin
                for (i = 0; i < 32; i = i + 1) begin
                    recv_byte(b);
                    word = {word[247:0], b};
                end
                ct[k] = word;
            end
        end
    endtask

    task do_capitalize(input integer len);
        begin
            send_byte("C");
            send_byte(X0[31:24]);
            send_byte(X0[23:16]);
            send_byte(X0[15:8]);
            send_byte(X0[7:0]);
            send_byte(len);
            for (k = 0; k < len; k = k + 1) begin
                word = ct[k];
                for (i = 0; i < 32; i = i + 1) begin
                    send_byte(word[255:248]);
                    word = word << 8;
                end
            end

            expect_byte("c", "capitalize reply code");
            expect_byte(len, "capitalize reply length");
            for (k = 0; k < len; k = k + 1) begin
                for (i = 0; i < 32; i = i + 1) begin
                    recv_byte(b);
                    word = {word[247:0], b};
                end
                ct_cap[k] = word;
            end
        end
    endtask

    task do_ping;
        begin
            send_byte("P");
            expect_byte("p", "ping reply code");
            expect_byte(8'h01, "ping version");
        end
    endtask

    // check the encrypt reply: each character decrypts, and the noise is small
    task check_encrypt(input integer len);
        reg [31:0] noise;
        begin
            for (k = 0; k < len; k = k + 1) begin
                if (decrypt_char(ct[k]) !== text[k]) begin
                    $display("ERROR: encrypt: char %0d decrypts to %h, expected %h",
                             k, decrypt_char(ct[k]), text[k]);
                    errors = errors + 1;
                end
                for (i = 0; i < 8; i = i + 1) begin
                    noise = ct[k][32*i +: 32] % P;
                    if (noise > 31) begin
                        $display("ERROR: encrypt: char %0d bit %0d noise %0d is larger than 31", k, i, noise);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    // check the capitalize reply: uppercase, and slices other than 5 unchanged
    task check_capitalize(input integer len);
        reg [7:0] expected;
        begin
            for (k = 0; k < len; k = k + 1) begin
                expected    = text[k];
                expected[5] = text[k][5] & ~text[k][6];
                if (decrypt_char(ct_cap[k]) !== expected) begin
                    $display("ERROR: capitalize: char %0d decrypts to %h, expected %h",
                             k, decrypt_char(ct_cap[k]), expected);
                    errors = errors + 1;
                end
                if ({ct_cap[k][255:192], ct_cap[k][159:0]} !== {ct[k][255:192], ct[k][159:0]}) begin
                    $display("ERROR: capitalize: char %0d: a slice other than slice 5 changed", k);
                    errors = errors + 1;
                end
            end
        end
    endtask

    reg [8*11-1:0] msg = "hello world";
    reg [8*11-1:0] result;

    initial begin
        repeat (200) @(posedge clk);

        // Test 1: ping
        do_ping;

        // Test 2 and 3: "hello world"
        for (k = 0; k < 11; k = k + 1)
            text[k] = msg[8*(10-k) +: 8];
        do_encrypt(11);
        check_encrypt(11);

        if (ct[2] === ct[3] || ct[2] === ct[9]) begin
            $display("ERROR: the three 'l' characters do not all have different ciphertexts");
            errors = errors + 1;
        end
        $display("encrypt 'h': bus = %h", ct[0]);

        do_capitalize(11);
        check_capitalize(11);
        for (k = 0; k < 11; k = k + 1)
            result[8*(10-k) +: 8] = decrypt_char(ct_cap[k]);
        $display("capitalize 'h': bus = %h", ct_cap[0]);
        $display("sent: %s   received: %s", msg, result);
        if (result !== "HELLO WORLD") begin
            $display("ERROR: expected HELLO WORLD");
            errors = errors + 1;
        end

        // Test 4: maximum length
        for (k = 0; k < MAX_LEN; k = k + 1)
            text[k] = (k % 27 == 26) ? " " : "a" + (k % 27);
        do_encrypt(MAX_LEN);
        check_encrypt(MAX_LEN);
        do_capitalize(MAX_LEN);
        check_capitalize(MAX_LEN);

        // Test 5a: unknown command
        send_byte("Z");
        expect_byte("!", "error code");
        expect_byte(8'd1, "unknown command");
        repeat (TIMEOUT_CYCLES + 100) @(posedge clk);
        do_ping;

        // Test 5b: length 0
        send_byte("E");
        send_byte(P[15:8]);
        send_byte(P[7:0]);
        send_byte(8'd0);
        expect_byte("!", "error code");
        expect_byte(8'd2, "length 0");
        repeat (TIMEOUT_CYCLES + 100) @(posedge clk);
        do_ping;

        // Test 5c: length larger than MAX_LEN; the payload bytes must be ignored
        send_byte("C");
        send_byte(8'h00); send_byte(8'h00); send_byte(8'h00); send_byte(8'h07);
        send_byte(MAX_LEN + 1);
        expect_byte("!", "error code");
        expect_byte(8'd2, "length too large");
        for (k = 0; k < 40; k = k + 1)
            send_byte("P");          // these must not make ping replies
        repeat (TIMEOUT_CYCLES + 100) @(posedge clk);
        do_ping;

        // Test 5d: timeout in the middle of a request
        send_byte("E");
        send_byte(P[15:8]);
        expect_byte("!", "error code");
        expect_byte(8'd3, "timeout");
        do_ping;

        // no extra bytes may remain
        repeat (1000) @(posedge clk);
        if (rx_rd != rx_wr) begin
            $display("ERROR: %0d unexpected bytes from the FPGA", rx_wr - rx_rd);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: fhe_top_tb");
        else             $display("FAIL: fhe_top_tb, %0d errors", errors);
        $finish;
    end

endmodule
