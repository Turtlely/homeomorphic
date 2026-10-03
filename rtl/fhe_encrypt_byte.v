`default_nettype none

// encrypt an 8-bit ascii character
module fhe_encrypt_byte (
    input  wire  [7:0]    s,   // 8-bit plaintext ascii character
    input  wire  [15:0]   p,   // 16-bit secret key
    input  wire  [127:0]  q,   // 8 x 16-bit random multiplier
    input  wire  [31:0]   r,   // 8 x 4-bit noise values
    output wire  [255:0]  c    // 8 x 32-bit ciphertext
);
    genvar i;
    generate
        for (i=0; i < 8; i=i+1) begin
            // Encrypt 1 bit into a 32-bit ciphertext
            assign c[32*i +: 32] = q[16*i +: 16]*{p[15:1],1'b1} 
                                 + (r[4*i +: 4] << 1)
                                 + s[i];
        end
    endgenerate
endmodule