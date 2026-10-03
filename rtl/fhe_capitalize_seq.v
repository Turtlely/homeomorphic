`default_nettype none

// Sequential version of fhe_capitalize_byte for the FPGA.
//
// It computes the same result:
//   c5_new = (c5 * (c6 + 1)) mod x0
//
// fhe_capitalize_byte uses "*" and "%" in one clock cycle. A 64-by-32 "%"
// becomes a very large and slow divider. This module uses one small adder
// for each step:
//   1. Shift-and-add multiply:  33 clock cycles
//   2. Restoring modulo:        64 clock cycles
//
// x0 must not be 0.
module fhe_capitalize_seq (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,    // one-cycle pulse; bin and x0 are read on this cycle
    input  wire [255:0] bin,      // 8 x 32-bit ciphertexts; bin[32*i +: 32] encrypts bit i
    input  wire [31:0]  x0,       // public modulus x0 = q0 * p
    output reg          busy,
    output reg          done,     // one-cycle pulse when bout is valid
    output reg  [255:0] bout
);
    localparam [1:0] S_IDLE = 2'd0,
                     S_MUL  = 2'd1,
                     S_MOD  = 2'd2;

    reg [1:0]   state;
    reg [6:0]   step;

    reg [255:0] bin_r;
    reg [31:0]  x0_r;

    reg [63:0]  mcand;      // multiplicand: c5, shifted left 1 bit each step
    reg [32:0]  mplier;     // multiplier: c6 + 1, shifted right 1 bit each step
    reg [63:0]  product;    // after S_MUL: c5 * (c6 + 1); in S_MOD: shifts left

    reg [32:0]  rem;        // partial remainder, always less than x0 after a step

    // one step of restoring division: bring down the next bit, subtract x0 if possible
    wire [32:0] rem_shift = {rem[31:0], product[63]};
    wire [32:0] rem_next  = (rem_shift >= {1'b0, x0_r}) ? rem_shift - {1'b0, x0_r} : rem_shift;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            bout    <= 256'd0;
            step    <= 0;
            bin_r   <= 256'd0;
            x0_r    <= 32'd0;
            mcand   <= 64'd0;
            mplier  <= 33'd0;
            product <= 64'd0;
            rem     <= 33'd0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        bin_r   <= bin;
                        x0_r    <= x0;
                        mcand   <= {32'd0, bin[32*5 +: 32]};          // c5
                        mplier  <= {1'b0, bin[32*6 +: 32]} + 33'd1;   // c6 + 1 (NOT b6)
                        product <= 64'd0;
                        step    <= 0;
                        busy    <= 1'b1;
                        state   <= S_MUL;
                    end
                end

                // product = c5 * (c6 + 1), one multiplier bit in each cycle
                S_MUL: begin
                    if (mplier[0])
                        product <= product + mcand;
                    mcand  <= mcand << 1;
                    mplier <= mplier >> 1;
                    if (step == 7'd32) begin
                        step  <= 0;
                        rem   <= 33'd0;
                        state <= S_MOD;
                    end else begin
                        step <= step + 1'b1;
                    end
                end

                // rem = product mod x0, one product bit in each cycle (MSB first)
                S_MOD: begin
                    rem     <= rem_next;
                    product <= product << 1;
                    if (step == 7'd63) begin
                        bout  <= {bin_r[255:192], rem_next[31:0], bin_r[159:0]};
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        step <= step + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
