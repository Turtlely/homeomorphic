`default_nettype none

// Pseudo-random number generator for the encryption randomness (q and r).
//
// A xorshift32 generator makes 32 new bits in each clock cycle. The bits
// shift into a 160-bit pool, so the whole pool is new after 5 clock cycles.
// The generator runs all the time, so the values that a user gets depend on
// the time of each request.
//
// SEED sets the start state. The build script gives a new random SEED to
// each bitstream.
//
// This generator is NOT cryptographically secure. Its output is linear, so
// an attacker who sees some outputs can calculate the next outputs.
module fhe_prng #(
    parameter [31:0] SEED = 32'h2545_F491   // must not be 0
) (
    input  wire         clk,
    input  wire         rst,
    output reg  [159:0] pool               // [127:0] = 8 x q, [159:128] = 8 x r
);
    reg  [31:0] state;
    wire [31:0] x1 = state ^ (state << 13);
    wire [31:0] x2 = x1    ^ (x1    >> 17);
    wire [31:0] x3 = x2    ^ (x2    << 5);

    always @(posedge clk) begin
        if (rst) begin
            state <= (SEED == 32'd0) ? 32'h2545_F491 : SEED;
            pool  <= 160'd0;
        end else begin
            state <= x3;
            pool  <= {pool[127:0], x3};
        end
    end
endmodule

`default_nettype wire
