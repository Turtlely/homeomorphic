`default_nettype none

// Testbench for fhe_encrypt_byte.
// Checks each 32-bit ciphertext against a reference model:
//   c = q*p_odd + 2r + m,   (c mod p_odd) = 2r + m,   (c mod p_odd) mod 2 = m
module fhe_encrypt_byte_tb;

    localparam N_TESTS = 1000;

    reg  [7:0]   s;
    reg  [15:0]  p;
    reg  [127:0] q;
    reg  [31:0]  r;
    wire [255:0] c;

    fhe_encrypt_byte dut (
        .s (s),
        .p (p),
        .q (q),
        .r (r),
        .c (c)
    );

    integer seed   = 1;
    integer errors = 0;
    integer t, i;

    reg  [15:0]  p_odd;
    reg  [31:0]  c_i, c_ref, noise;
    reg  [255:0] c_saved;

    // reference model for one bit
    function [31:0] ref_encrypt_bit(input m, input [15:0] p_odd, input [15:0] q, input [3:0] r);
        ref_encrypt_bit = q * p_odd + 2 * r + m;
    endfunction

    // new random q and r for each bit
    task randomize_qr;
        begin
            q = {$random(seed), $random(seed), $random(seed), $random(seed)};
            r = $random(seed);
        end
    endtask

    // compare every ciphertext slice with the reference model
    task check_all_bits;
        begin
            p_odd = {p[15:1], 1'b1};
            for (i = 0; i < 8; i = i + 1) begin
                c_i   = c[32*i +: 32];
                c_ref = ref_encrypt_bit(s[i], p_odd, q[16*i +: 16], r[4*i +: 4]);
                noise = c_i % p_odd;

                if (c_i !== c_ref) begin
                    $display("ERROR: s=%h bit %0d: c=%0d, expected %0d", s, i, c_i, c_ref);
                    errors = errors + 1;
                end
                if (noise !== 2 * r[4*i +: 4] + s[i]) begin
                    $display("ERROR: s=%h bit %0d: noise=%0d, expected %0d",
                             s, i, noise, 2 * r[4*i +: 4] + s[i]);
                    errors = errors + 1;
                end
                if (noise[0] !== s[i]) begin
                    $display("ERROR: s=%h bit %0d: decrypts to %b, expected %b", s, i, noise[0], s[i]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        // Test 1: random characters, keys, and randomness.
        // p[15] = 1 keeps p large, so the noise is always less than p/2.
        for (t = 0; t < N_TESTS; t = t + 1) begin
            s = $random(seed);
            p = 16'h8000 | $random(seed);
            randomize_qr;
            #1;
            check_all_bits;
        end

        // Test 2: largest values. The sum must still fit in 32 bits.
        s = 8'hFF;
        p = 16'hFFFF;
        q = {128{1'b1}};
        r = {32{1'b1}};
        #1;
        check_all_bits;

        // Test 3: an even key must give the same output as key + 1.
        s = "h";
        p = 16'd40008;
        randomize_qr;
        #1;
        c_saved = c;
        p = 16'd40009;
        #1;
        if (c !== c_saved) begin
            $display("ERROR: even key 40008 and odd key 40009 give different ciphertexts");
            errors = errors + 1;
        end

        // Test 4: the same character with new randomness must give a new ciphertext.
        // If this fails, the ciphertext leaks the plaintext.
        s = "h";
        randomize_qr;
        #1;
        c_saved = c;
        randomize_qr;
        #1;
        if (c === c_saved) begin
            $display("ERROR: two encryptions of the same character are identical");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: fhe_encrypt_byte_tb");
        else             $display("FAIL: fhe_encrypt_byte_tb, %0d errors", errors);
        $finish;
    end

endmodule
