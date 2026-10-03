`default_nettype none

// Testbench for fhe_capitalize_byte.
// The testbench encrypts and decrypts with its own reference model,
// so this test checks only the homomorphic operation.
// Expected result for each byte: b5_new = b5 AND (NOT b6), all other bits unchanged.
module fhe_capitalize_byte_tb;

    localparam N_TESTS = 1000;

    reg  [255:0] bin;
    reg  [31:0]  x0;
    wire [255:0] bout;

    fhe_capitalize_byte dut (
        .bin  (bin),
        .x0   (x0),
        .bout (bout)
    );

    integer seed   = 3;
    integer errors = 0;
    integer t, i;

    reg [15:0]  p, p_odd;
    reg [127:0] q;
    reg [31:0]  r;
    reg [7:0]   s_in, s_out, expected;
    reg [31:0]  noise5;

    // reference model: encrypt one byte into bin, with new randomness for each bit
    task ref_encrypt_byte(input [7:0] m);
        begin
            q = {$random(seed), $random(seed), $random(seed), $random(seed)};
            r = $random(seed);
            for (i = 0; i < 8; i = i + 1)
                bin[32*i +: 32] = q[16*i +: 16] * p_odd + 2 * r[4*i +: 4] + m[i];
        end
    endtask

    // reference model: decrypt bout
    task ref_decrypt_byte;
        begin
            for (i = 0; i < 8; i = i + 1)
                s_out[i] = (bout[32*i +: 32] % p_odd) % 2;
        end
    endtask

    // the plaintext rule that the circuit computes
    function [7:0] ref_capitalize(input [7:0] m);
        begin
            ref_capitalize    = m;
            ref_capitalize[5] = m[5] & ~m[6];
        end
    endfunction

    // the client makes a new key and the public value x0 = q0 * p_odd < 2^32
    task new_key(input [15:0] key);
        begin
            p     = key;
            p_odd = {key[15:1], 1'b1};
            x0    = (32'hFFFF_FFFF / p_odd) * p_odd;
        end
    endtask

    task run_one(input [7:0] m);
        begin
            s_in = m;
            ref_encrypt_byte(s_in);
            #1;
            ref_decrypt_byte;
            expected = ref_capitalize(s_in);
            noise5   = bout[32*5 +: 32] % p_odd;

            if (s_out !== expected) begin
                $display("ERROR: p=%0d s=%h: decrypted %h, expected %h", p_odd, s_in, s_out, expected);
                errors = errors + 1;
            end
            // slices 0-4 and 6-7 must pass through without change
            if ({bout[255:192], bout[159:0]} !== {bin[255:192], bin[159:0]}) begin
                $display("ERROR: s=%h: a slice other than slice 5 changed", s_in);
                errors = errors + 1;
            end
            // the result must be reduced below x0
            if (bout[32*5 +: 32] >= x0) begin
                $display("ERROR: s=%h: slice 5 = %0d is not less than x0 = %0d", s_in, bout[32*5 +: 32], x0);
                errors = errors + 1;
            end
            // the noise must stay below p/2, or a later operation can fail
            if (noise5 >= p_odd / 2) begin
                $display("ERROR: s=%h: noise %0d is not less than p/2 = %0d", s_in, noise5, p_odd / 2);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Test 1: all lowercase letters must become uppercase
        new_key(16'd40009);
        for (t = "a"; t <= "z"; t = t + 1) begin
            run_one(t);
            if (s_out !== t - 32) begin
                $display("ERROR: '%c' became '%c', expected '%c'", t, s_out, t - 32);
                errors = errors + 1;
            end
        end

        // Test 2: uppercase letters and space must not change
        for (t = "A"; t <= "Z"; t = t + 1) begin
            run_one(t);
            if (s_out !== t) begin
                $display("ERROR: '%c' became '%c'", t, s_out);
                errors = errors + 1;
            end
        end
        run_one(" ");
        if (s_out !== " ") begin
            $display("ERROR: space became %h", s_out);
            errors = errors + 1;
        end

        // Test 3: all 256 byte values follow the bit rule
        for (t = 0; t < 256; t = t + 1)
            run_one(t);

        // Test 4: random bytes with random keys.
        // p[15] = 1 keeps p large, so the noise after one AND (at most 961) is less than p/2.
        for (t = 0; t < N_TESTS; t = t + 1) begin
            new_key(16'h8000 | $random(seed));
            run_one($random(seed));
        end

        if (errors == 0) $display("PASS: fhe_capitalize_byte_tb");
        else             $display("FAIL: fhe_capitalize_byte_tb, %0d errors", errors);
        $finish;
    end

endmodule
