`default_nettype none

// Command controller: receives requests from the PC over the UART,
// runs the encryptor or the homomorphic capitalize unit, and sends the result back.
//
// Protocol (all multi-byte numbers are big-endian):
//
//   PC -> FPGA                                   FPGA -> PC
//   'P'                                          'p', VERSION
//   'E', p[15:8], p[7:0], LEN, LEN chars         'e', LEN, LEN x 32 ciphertext bytes
//   'C', x0 (4 bytes), LEN, LEN x 32 bytes       'c', LEN, LEN x 32 ciphertext bytes
//   (error)                                      '!', code
//
// One character is a 256-bit bus of 8 ciphertexts (bus[32*i +: 32] encrypts bit i).
// The bus is sent as 32 bytes, most significant byte first (bus[255:248] first).
//
// Error codes: 1 = unknown command, 2 = LEN is 0 or larger than MAX_LEN,
//              3 = timeout (the PC stopped in the middle of a request).
// After error 1 or 2, the controller ignores all bytes until the line is
// quiet for TIMEOUT_CYCLES.
module fhe_controller #(
    parameter        MAX_LEN        = 64,
    parameter        TIMEOUT_CYCLES = 10_000_000,
    parameter [31:0] PRNG_SEED      = 32'h2545_F491
) (
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] rx_data,
    input  wire       rx_valid,

    output reg  [7:0] tx_data,
    output wire       tx_valid,
    input  wire       tx_ready,

    output wire       busy,
    output wire       error     // one-cycle pulse when the controller sends an error
);
    localparam [7:0] CMD_PING       = "P",
                     CMD_ENCRYPT    = "E",
                     CMD_CAPITALIZE = "C",
                     RSP_PING       = "p",
                     RSP_ENCRYPT    = "e",
                     RSP_CAPITALIZE = "c",
                     RSP_ERROR      = "!",
                     VERSION        = 8'h01;

    localparam [7:0] ERR_COMMAND = 8'd1,
                     ERR_LENGTH  = 8'd2,
                     ERR_TIMEOUT = 8'd3;

    localparam BUF_BYTES = MAX_LEN * 32;
    localparam ADDR_W    = $clog2(BUF_BYTES);
    localparam NB_W      = $clog2(BUF_BYTES + 1);
    localparam TIMER_W   = $clog2(TIMEOUT_CYCLES + 1);

    localparam [3:0] S_IDLE       = 4'd0,
                     S_HEADER     = 4'd1,
                     S_LENGTH     = 4'd2,
                     S_PAYLOAD    = 4'd3,
                     S_REPLY2     = 4'd4,
                     S_LOAD_START = 4'd5,
                     S_LOAD       = 4'd6,
                     S_ENC_SETUP  = 4'd7,
                     S_ENC_WAIT   = 4'd8,
                     S_CAP_START  = 4'd9,
                     S_CAP_WAIT   = 4'd10,
                     S_SEND       = 4'd11,
                     S_DRAIN      = 4'd12;

    reg [3:0]         state, after_reply;

    reg [7:0]         cmd;
    reg [31:0]        header;        // p or x0, shifted in one byte at a time
    reg [2:0]         header_left;
    reg [15:0]        key_p;
    reg [31:0]        x0;
    reg [7:0]         len;
    reg [NB_W-1:0]    nbytes;        // payload size in bytes
    reg [NB_W-1:0]    addr;          // payload write address
    reg [7:0]         char_idx;

    reg [7:0]         reply0, reply1;
    reg               reply_idx;

    reg [ADDR_W-1:0]  rd_addr;
    reg [5:0]         load_cnt;
    reg [255:0]       in_reg;        // input of the operation for one character
    reg [255:0]       out_reg;       // result for one character, sent MSB first
    reg [4:0]         send_cnt;

    reg [TIMER_W-1:0] timer;

    wire tx_fire = tx_valid && tx_ready;

    assign busy  = (state != S_IDLE);
    assign error = (state == S_REPLY2) && (reply0 == RSP_ERROR) && (reply_idx == 1'b1) && tx_fire;

    // ---------------------------------------------------------------
    // Payload buffer (block RAM): plaintext bytes or ciphertext bytes
    // ---------------------------------------------------------------
    reg [7:0] buffer [0:BUF_BYTES-1];
    reg [7:0] buf_rdata;
    wire      buf_we = (state == S_PAYLOAD) && rx_valid;

    always @(posedge clk) begin
        if (buf_we)
            buffer[addr[ADDR_W-1:0]] <= rx_data;
        buf_rdata <= buffer[rd_addr];
    end

    // ---------------------------------------------------------------
    // Encryption: random q and r from the PRNG, combinational encryptor
    // ---------------------------------------------------------------
    wire [159:0] pool;
    reg  [7:0]   enc_s;
    reg  [127:0] enc_q;
    reg  [31:0]  enc_r;
    wire [255:0] enc_c;

    fhe_prng #(
        .SEED (PRNG_SEED)
    ) u_prng (
        .clk  (clk),
        .rst  (rst),
        .pool (pool)
    );

    fhe_encrypt_byte u_encrypt (
        .s (enc_s),
        .p (key_p),
        .q (enc_q),
        .r (enc_r),
        .c (enc_c)
    );

    // ---------------------------------------------------------------
    // Homomorphic capitalize (sequential)
    // ---------------------------------------------------------------
    wire         cap_start = (state == S_CAP_START);
    wire         cap_busy, cap_done;
    wire [255:0] cap_bout;

    fhe_capitalize_seq u_capitalize (
        .clk   (clk),
        .rst   (rst),
        .start (cap_start),
        .bin   (in_reg),
        .x0    (x0),
        .busy  (cap_busy),
        .done  (cap_done),
        .bout  (cap_bout)
    );

    // ---------------------------------------------------------------
    // Transmit data
    // ---------------------------------------------------------------
    assign tx_valid = (state == S_REPLY2) || (state == S_SEND);

    always @(*) begin
        if (state == S_SEND)
            tx_data = out_reg[255:248];
        else
            tx_data = reply_idx ? reply1 : reply0;
    end

    // ---------------------------------------------------------------
    // Timeout timer: counts quiet cycles while a request is incomplete
    // ---------------------------------------------------------------
    wire timed_state = (state == S_HEADER) || (state == S_LENGTH) ||
                       (state == S_PAYLOAD) || (state == S_DRAIN);
    wire timeout     = (timer == TIMEOUT_CYCLES - 1);

    always @(posedge clk) begin
        if (rst || rx_valid || !timed_state)
            timer <= 0;
        else if (!timeout)
            timer <= timer + 1'b1;
    end

    // ---------------------------------------------------------------
    // Main state machine
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            after_reply <= S_IDLE;
            cmd         <= 8'd0;
            header      <= 32'd0;
            header_left <= 3'd0;
            key_p       <= 16'd1;
            x0          <= 32'd1;
            len         <= 8'd0;
            nbytes      <= 0;
            addr        <= 0;
            char_idx    <= 8'd0;
            reply0      <= 8'd0;
            reply1      <= 8'd0;
            reply_idx   <= 1'b0;
            rd_addr     <= 0;
            load_cnt    <= 6'd0;
            in_reg      <= 256'd0;
            out_reg     <= 256'd0;
            send_cnt    <= 5'd0;
            enc_s       <= 8'd0;
            enc_q       <= 128'd0;
            enc_r       <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    reply_idx <= 1'b0;
                    if (rx_valid) begin
                        cmd <= rx_data;
                        case (rx_data)
                            CMD_PING: begin
                                reply0      <= RSP_PING;
                                reply1      <= VERSION;
                                after_reply <= S_IDLE;
                                state       <= S_REPLY2;
                            end
                            CMD_ENCRYPT: begin
                                header_left <= 3'd2;
                                state       <= S_HEADER;
                            end
                            CMD_CAPITALIZE: begin
                                header_left <= 3'd4;
                                state       <= S_HEADER;
                            end
                            default: begin
                                reply0      <= RSP_ERROR;
                                reply1      <= ERR_COMMAND;
                                after_reply <= S_DRAIN;
                                state       <= S_REPLY2;
                            end
                        endcase
                    end
                end

                S_HEADER: begin
                    if (rx_valid) begin
                        header      <= {header[23:0], rx_data};
                        header_left <= header_left - 1'b1;
                        if (header_left == 3'd1)
                            state <= S_LENGTH;
                    end else if (timeout) begin
                        reply0      <= RSP_ERROR;
                        reply1      <= ERR_TIMEOUT;
                        after_reply <= S_IDLE;
                        state       <= S_REPLY2;
                    end
                end

                S_LENGTH: begin
                    if (rx_valid) begin
                        if (rx_data == 8'd0 || rx_data > MAX_LEN) begin
                            reply0      <= RSP_ERROR;
                            reply1      <= ERR_LENGTH;
                            after_reply <= S_DRAIN;
                            state       <= S_REPLY2;
                        end else begin
                            len    <= rx_data;
                            nbytes <= (cmd == CMD_ENCRYPT) ? rx_data : {rx_data, 5'b0};
                            addr   <= 0;
                            if (cmd == CMD_ENCRYPT)
                                key_p <= header[15:0];
                            else
                                x0 <= header;
                            state <= S_PAYLOAD;
                        end
                    end else if (timeout) begin
                        reply0      <= RSP_ERROR;
                        reply1      <= ERR_TIMEOUT;
                        after_reply <= S_IDLE;
                        state       <= S_REPLY2;
                    end
                end

                S_PAYLOAD: begin
                    if (rx_valid) begin
                        addr <= addr + 1'b1;
                        if (addr == nbytes - 1'b1) begin
                            reply0      <= (cmd == CMD_ENCRYPT) ? RSP_ENCRYPT : RSP_CAPITALIZE;
                            reply1      <= len;
                            after_reply <= S_LOAD_START;
                            char_idx    <= 8'd0;
                            state       <= S_REPLY2;
                        end
                    end else if (timeout) begin
                        reply0      <= RSP_ERROR;
                        reply1      <= ERR_TIMEOUT;
                        after_reply <= S_IDLE;
                        state       <= S_REPLY2;
                    end
                end

                // send reply0, then reply1
                S_REPLY2: begin
                    if (tx_fire) begin
                        if (reply_idx) begin
                            reply_idx <= 1'b0;
                            state     <= after_reply;
                        end else begin
                            reply_idx <= 1'b1;
                        end
                    end
                end

                // read the input bytes of one character from the buffer
                S_LOAD_START: begin
                    rd_addr  <= (cmd == CMD_ENCRYPT) ? char_idx : {char_idx, 5'b0};
                    load_cnt <= 6'd0;
                    state    <= S_LOAD;
                end

                // the buffer has one cycle of read latency, so byte k arrives when load_cnt = k + 1
                S_LOAD: begin
                    rd_addr  <= rd_addr + 1'b1;
                    load_cnt <= load_cnt + 1'b1;
                    if (load_cnt != 6'd0)
                        in_reg <= {in_reg[247:0], buf_rdata};
                    if (load_cnt == ((cmd == CMD_ENCRYPT) ? 6'd1 : 6'd32))
                        state <= (cmd == CMD_ENCRYPT) ? S_ENC_SETUP : S_CAP_START;
                end

                // register the encryptor inputs with new random values
                S_ENC_SETUP: begin
                    enc_s <= in_reg[7:0];
                    enc_q <= pool[127:0];
                    enc_r <= pool[159:128];
                    state <= S_ENC_WAIT;
                end

                S_ENC_WAIT: begin
                    out_reg  <= enc_c;
                    send_cnt <= 5'd0;
                    state    <= S_SEND;
                end

                S_CAP_START: begin
                    state <= S_CAP_WAIT;
                end

                S_CAP_WAIT: begin
                    if (cap_done) begin
                        out_reg  <= cap_bout;
                        send_cnt <= 5'd0;
                        state    <= S_SEND;
                    end
                end

                // send 32 bytes, most significant byte first
                S_SEND: begin
                    if (tx_fire) begin
                        out_reg  <= out_reg << 8;
                        send_cnt <= send_cnt + 1'b1;
                        if (send_cnt == 5'd31) begin
                            if (char_idx == len - 1'b1) begin
                                state <= S_IDLE;
                            end else begin
                                char_idx <= char_idx + 1'b1;
                                state    <= S_LOAD_START;
                            end
                        end
                    end
                end

                // ignore bytes until the line is quiet
                S_DRAIN: begin
                    if (timeout)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
