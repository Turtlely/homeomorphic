`default_nettype none

// 8-N-1 UART receiver.
// Samples each bit in the middle of the bit period.
// data_valid is high for one clock cycle when a byte is received.
module uart_rx #(
    parameter CLOCK_FREQUENCY = 100_000_000,
    parameter BAUD_RATE       = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,             // serial input (idle high)
    output reg  [7:0] data,
    output reg        data_valid,     // one-cycle pulse
    output reg        framing_error   // one-cycle pulse: stop bit was 0
);
    localparam CLKS_PER_BIT = (CLOCK_FREQUENCY + BAUD_RATE / 2) / BAUD_RATE;
    localparam COUNT_WIDTH  = $clog2(CLKS_PER_BIT + 1);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    // two flip-flops to synchronize the asynchronous input
    (* ASYNC_REG = "TRUE" *) reg rx_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rx_sync = 1'b1;

    reg [1:0]             state;
    reg [COUNT_WIDTH-1:0] count;
    reg [2:0]             bit_index;
    reg [7:0]             shift;

    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            count         <= 0;
            bit_index     <= 0;
            shift         <= 8'd0;
            data          <= 8'd0;
            data_valid    <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            data_valid    <= 1'b0;
            framing_error <= 1'b0;

            case (state)
                S_IDLE: begin
                    count <= 0;
                    if (!rx_sync)
                        state <= S_START;
                end

                // wait half a bit, then check that the start bit is still 0
                S_START: begin
                    if (count == CLKS_PER_BIT / 2 - 1) begin
                        count     <= 0;
                        bit_index <= 0;
                        state     <= rx_sync ? S_IDLE : S_DATA;
                    end else begin
                        count <= count + 1'b1;
                    end
                end

                // sample 8 data bits, least significant bit first
                S_DATA: begin
                    if (count == CLKS_PER_BIT - 1) begin
                        count <= 0;
                        shift <= {rx_sync, shift[7:1]};
                        if (bit_index == 3'd7)
                            state <= S_STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end else begin
                        count <= count + 1'b1;
                    end
                end

                S_STOP: begin
                    if (count == CLKS_PER_BIT - 1) begin
                        count <= 0;
                        state <= S_IDLE;
                        if (rx_sync) begin
                            data       <= shift;
                            data_valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                    end else begin
                        count <= count + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
