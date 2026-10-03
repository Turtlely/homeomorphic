`default_nettype none

// Testbench for fhe_capitalize_seq.
// Compares the sequential unit with the combinational fhe_capitalize_byte,
// which is the reference. Both units get the same inputs.
module fhe_capitalize_seq_tb;

    localparam N_TESTS = 500;

    reg          clk = 1'b0;
    reg          rst = 1'b1;
    reg          start = 1'b0;
    reg  [255:0] bin;
    reg  [31:0]  x0;
    wire         busy, done;
    wire [255:0] bout_seq, bout_ref;

    always #5 clk = ~clk;

    fhe_capitalize_seq dut (
        .clk   (clk),
        .rst   (rst),
        .start (start),
        .bin   (bin),
        .x0    (x0),
        .busy  (busy),
        .done  (done),
        .bout  (bout_seq)
    );

    fhe_capitalize_byte ref_model (
        .bin  (bin),
        .x0   (x0),
        .bout (bout_ref)
    );

    integer seed   = 5;
    integer errors = 0;
    integer t, cycles;

    task run_one;
        begin
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            cycles = 0;
            while (!done) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > 200) begin
                    $display("ERROR: no done pulse after 200 cycles");
                    errors = errors + 1;
                    disable run_one;
                end
            end
            if (bout_seq !== bout_ref) begin
                $display("ERROR: c5=%h c6=%h x0=%h: slice 5 = %h, expected %h",
                         bin[32*5 +: 32], bin[32*6 +: 32], x0, bout_seq[32*5 +: 32], bout_ref[32*5 +: 32]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst <= 1'b0;

        // Test 1: random inputs and random x0
        for (t = 0; t < N_TESTS; t = t + 1) begin
            bin = {$random(seed), $random(seed), $random(seed), $random(seed),
                   $random(seed), $random(seed), $random(seed), $random(seed)};
            x0  = $random(seed);
            if (x0 == 0) x0 = 1;
            run_one;
        end

        // Test 2: edge values
        bin = {256{1'b1}};  x0 = 32'hFFFF_FFFF;  run_one;   // c6 + 1 = 2^32
        bin = {256{1'b1}};  x0 = 32'd1;          run_one;   // result is 0
        bin = {256{1'b1}};  x0 = 32'd3;          run_one;
        bin = 256'd0;       x0 = 32'd40009;      run_one;   // product is 0
        bin = {256{1'b1}};  x0 = 32'h8000_0001;  run_one;

        $display("cycles for one operation: %0d", cycles);

        if (errors == 0) $display("PASS: fhe_capitalize_seq_tb");
        else             $display("FAIL: fhe_capitalize_seq_tb, %0d errors", errors);
        $finish;
    end

endmodule
