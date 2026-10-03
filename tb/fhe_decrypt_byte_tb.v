`default_nettype none

// Testbench for fhe_decrypt_byte.
// The testbench makes the ciphertexts with its own reference model,
// so this test does not depend on fhe_encrypt_byte.
module fhe_decrypt_byte_tb;

    localparam N_TESTS = 1000;

    reg  [255:0] e;
    reg  [15:0]  p;
    wire [7:0]   s;

    fhe_decrypt_byte dut (
        .e (e),
        .p (p),
        .s (s)
    );

    integer seed   = 2;
    integer errors = 0;
    integer t, i;

    reg [7:0]   s_in;
    reg [127:0] q;
    reg [31:0]  r;

    // reference model: encrypt one byte into e, with new randomness for each bit
    task ref_encrypt_byte(input [7:0] m, input [15:0] key);
        reg [15:0] p_odd;
        begin
            p_odd = {key[15:1], 1'b1};
            q = {$random(seed), $random(seed), $random(seed), $random(seed)};
            r = $random(seed);
            for (i = 0; i < 8; i = i + 1)
                e[32*i +: 32] = q[16*i +: 16] * p_odd + 2 * r[4*i +: 4] + m[i];
        end
    endtask

    task check(input [7:0] expected);
        begin
            #1;
            if (s !== expected) begin
                $display("ERROR: p=%0d: decrypted %h, expected %h", p, s, expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Test 1: all 256 characters with one key
        p = 16'd40009;
        for (t = 0; t < 256; t = t + 1) begin
            s_in = t;
            ref_encrypt_byte(s_in, p);
            check(s_in);
        end

        // Test 2: random characters and random keys
        for (t = 0; t < N_TESTS; t = t + 1) begin
            s_in = $random(seed);
            p    = 16'h8000 | $random(seed);
            ref_encrypt_byte(s_in, p);
            check(s_in);
        end

        // Test 3: largest ciphertext values
        p    = 16'hFFFF;
        s_in = 8'hFF;
        for (i = 0; i < 8; i = i + 1)
            e[32*i +: 32] = 16'hFFFF * 16'hFFFF + 2 * 4'hF + 1;
        check(s_in);

        // Test 4: an even key. The decryptor must use key + 1, the same as the encryptor.
        p    = 16'd40008;
        s_in = "w";
        ref_encrypt_byte(s_in, p);
        check(s_in);

        if (errors == 0) $display("PASS: fhe_decrypt_byte_tb");
        else             $display("FAIL: fhe_decrypt_byte_tb, %0d errors", errors);
        $finish;
    end

endmodule
