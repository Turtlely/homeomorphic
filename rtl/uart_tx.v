`default_nettype none

// 8-N-1 UART transmitter with a valid/ready handshake.
// A byte is accepted on a clock edge where valid and ready are both high.
module uart_tx #(
    parameter CLOCK_FREQUENCY = 100_000_000,
    parameter BAUD_RATE       = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,   // high when the transmitter can accept a byte
    output reg        tx       // serial output (idle high)
);
    localparam CLKS_PER_BIT = (CLOCK_FREQUENCY + BAUD_RATE / 2) / BAUD_RATE;
    localparam COUNT_WIDTH  = $clog2(CLKS_PER_BIT + 1);

    reg                   busy;
    reg [9:0]             frame;       // {stop bit, data, start bit}
    reg [3:0]             bit_index;
    reg [COUNT_WIDTH-1:0] count;

    assign ready = !busy;

    always @(posedge clk) begin
        if (rst) begin
            busy      <= 1'b0;
            tx        <= 1'b1;
            frame     <= 10'h3FF;
            bit_index <= 0;
            count     <= 0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (valid) begin
                frame     <= {1'b1, data, 1'b0};
                tx        <= 1'b0;                // start bit
                busy      <= 1'b1;
                bit_index <= 0;
                count     <= 0;
            end
        end else if (count == CLKS_PER_BIT - 1) begin
            count <= 0;
            if (bit_index == 4'd9) begin
                busy <= 1'b0;                     // stop bit is complete
                tx   <= 1'b1;
            end else begin
                bit_index <= bit_index + 1'b1;
                tx        <= frame[bit_index + 1'b1];
            end
        end else begin
            count <= count + 1'b1;
        end
    end
endmodule

`default_nettype wire
