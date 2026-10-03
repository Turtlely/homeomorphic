`default_nettype none

module fhe_decrypt_byte(
    input  wire  [255:0]    e,
    input  wire  [15:0]     p,
    output wire  [7:0]      s
);
    genvar i;
    generate
        for (i = 0; i < 8; i=i+1) begin
            wire [15:0] noise = e[32*i +: 32] % {p[15:1], 1'b1};
            assign s[i] = noise[0];
        end
    endgenerate
endmodule