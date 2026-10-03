`default_nettype none

// End-to-end testbench: encrypt -> capitalize -> decrypt.
// Sends "hello world" through all three RTL modules and expects "HELLO WORLD".
module fhe_chain_tb;

    localparam LEN = 11;

    reg  [8*LEN-1:0] msg      = "hello world";
    reg  [8*LEN-1:0] expected = "HELLO WORLD";
    reg  [8*LEN-1:0] result;

    // client side
    reg  [7:0]   s;
    reg  [15:0]  p = 16'd40009;   // secret key: only the client has it
    reg  [127:0] q;
    reg  [31:0]  r;
    reg  [31:0]  x0;              // public value: the server gets it
    wire [255:0] c;

    // server side
    wire [255:0] c_cap;

    // client side again
    wire [7:0]   s_out;

    fhe_encrypt_byte u_encrypt (
        .s (s),
        .p (p),
        .q (q),
        .r (r),
        .c (c)
    );

    fhe_capitalize_byte u_capitalize (
        .bin  (c),
        .x0   (x0),
        .bout (c_cap)
    );

    fhe_decrypt_byte u_decrypt (
        .e (c_cap),
        .p (p),
        .s (s_out)
    );

    integer seed = 4;
    integer k;

    initial begin
        $dumpfile("build/fhe_chain_tb.vcd");
        $dumpvars(0, fhe_chain_tb);

        x0 = (32'hFFFF_FFFF / {p[15:1], 1'b1}) * {p[15:1], 1'b1};

        // the first character is in the highest byte of a string
        for (k = LEN - 1; k >= 0; k = k - 1) begin
            s = msg[8*k +: 8];
            q = {$random(seed), $random(seed), $random(seed), $random(seed)};
            r = $random(seed);
            #10;
            result[8*k +: 8] = s_out;
            $display("'%c' -> c5 = %0d -> c5_new = %0d -> '%c'",
                     s, c[32*5 +: 32], c_cap[32*5 +: 32], s_out);
        end

        $display("sent:     %s", msg);
        $display("received: %s", result);

        if (result === expected) $display("PASS: fhe_chain_tb");
        else                     $display("FAIL: fhe_chain_tb, expected %s", expected);
        $finish;
    end

endmodule
