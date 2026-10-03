`default_nettype none

module fhe_capitalize_byte(
    input   wire    [255:0] bin,
    input   wire    [31:0]  x0,
    output  wire    [255:0] bout
);

wire [31:0] c5   = bin[32*5 +: 32];
wire [31:0] c6   = bin[32*6 +: 32];

wire [63:0] product = c5 * (c6 + 32'd1);
wire [31:0] c5_new = product % x0;
assign bout = {bin[255:192], c5_new, bin[159:0]};

endmodule