`default_nettype none

// Top level for the Real Digital Urbana board (Spartan-7 XC7S50).
//
// The PC talks to fhe_controller over the USB-UART bridge.
//
// LEDs:
//   LED[0]  heartbeat: blinks when the bitstream is loaded
//   LED[1]  on for a short time after a byte is received
//   LED[2]  on for a short time after a byte is sent
//   LED[3]  on for 1 second after an error or a UART framing error
//
// BTN[0] resets the design.
module fhe_top #(
    parameter        CLOCK_FREQUENCY = 100_000_000,
    parameter        BAUD_RATE       = 115_200,
    parameter        MAX_LEN         = 64,
    parameter        TIMEOUT_CYCLES  = CLOCK_FREQUENCY / 10,   // 100 ms
    parameter [31:0] PRNG_SEED       = 32'h2545_F491,          // the build script sets a random value
    parameter        POR_BITS        = 16                      // power-on reset length: 2^POR_BITS cycles
) (
    input  wire       CLK_100MHZ,
    input  wire [0:0] BTN,
    input  wire       UART_RXD,
    output wire       UART_TXD,
    output wire [3:0] LED
);
    wire clk = CLK_100MHZ;

    // ---------------------------------------------------------------
    // Reset: power-on reset and BTN[0]
    // ---------------------------------------------------------------
    reg [POR_BITS-1:0] por_count = 0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_sync = 2'b00;
    reg rst = 1'b1;

    always @(posedge clk) begin
        if (!(&por_count))
            por_count <= por_count + 1'b1;
        btn_sync <= {btn_sync[0], BTN[0]};
        rst      <= btn_sync[1] || !(&por_count);
    end

    // ---------------------------------------------------------------
    // UART and controller
    // ---------------------------------------------------------------
    wire [7:0] rx_data, tx_data;
    wire       rx_valid, framing_error;
    wire       tx_valid, tx_ready;
    wire       ctrl_busy, ctrl_error;

    uart_rx #(
        .CLOCK_FREQUENCY (CLOCK_FREQUENCY),
        .BAUD_RATE       (BAUD_RATE)
    ) u_uart_rx (
        .clk           (clk),
        .rst           (rst),
        .rx            (UART_RXD),
        .data          (rx_data),
        .data_valid    (rx_valid),
        .framing_error (framing_error)
    );

    uart_tx #(
        .CLOCK_FREQUENCY (CLOCK_FREQUENCY),
        .BAUD_RATE       (BAUD_RATE)
    ) u_uart_tx (
        .clk   (clk),
        .rst   (rst),
        .data  (tx_data),
        .valid (tx_valid),
        .ready (tx_ready),
        .tx    (UART_TXD)
    );

    fhe_controller #(
        .MAX_LEN        (MAX_LEN),
        .TIMEOUT_CYCLES (TIMEOUT_CYCLES),
        .PRNG_SEED      (PRNG_SEED)
    ) u_controller (
        .clk      (clk),
        .rst      (rst),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready),
        .busy     (ctrl_busy),
        .error    (ctrl_error)
    );

    // ---------------------------------------------------------------
    // LEDs
    // ---------------------------------------------------------------
    localparam ACTIVITY_CYCLES = CLOCK_FREQUENCY / 20;   // 50 ms
    localparam ERROR_CYCLES    = CLOCK_FREQUENCY;        // 1 s

    reg [25:0]                            heartbeat = 0;
    reg [$clog2(ACTIVITY_CYCLES+1)-1:0]   rx_led_count = 0;
    reg [$clog2(ACTIVITY_CYCLES+1)-1:0]   tx_led_count = 0;
    reg [$clog2(ERROR_CYCLES+1)-1:0]      err_led_count = 0;

    always @(posedge clk) begin
        heartbeat <= heartbeat + 1'b1;

        if (rx_valid)
            rx_led_count <= ACTIVITY_CYCLES;
        else if (rx_led_count != 0)
            rx_led_count <= rx_led_count - 1'b1;

        if (tx_valid && tx_ready)
            tx_led_count <= ACTIVITY_CYCLES;
        else if (tx_led_count != 0)
            tx_led_count <= tx_led_count - 1'b1;

        if (ctrl_error || framing_error)
            err_led_count <= ERROR_CYCLES;
        else if (err_led_count != 0)
            err_led_count <= err_led_count - 1'b1;
    end

    assign LED[0] = heartbeat[25];
    assign LED[1] = (rx_led_count  != 0);
    assign LED[2] = (tx_led_count  != 0);
    assign LED[3] = (err_led_count != 0);
endmodule

`default_nettype wire
