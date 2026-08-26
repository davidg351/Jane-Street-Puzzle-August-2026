`timescale 1ns/1ps

module puzzle_tb;

    parameter integer VECTOR_BITS = 121;
    parameter integer CLOCK_HALF_PERIOD_NS = 5;

    // After each input vector:
    //
    //   enable low
    //      |
    //      |<----------- GAP_CYCLES ----------->|
    //                                            |
    //                                      rst_n goes low
    //                                            |
    //                                  RESET_LOW_CYCLES clocks
    //                                            |
    //                                      rst_n goes high
    //                                            |
    //                              POST_RESET_GAP_CYCLES clocks
    //                                            |
    //                                      enable goes high
    //
    // With the defaults below:
    //
    //   GAP_CYCLES            = 32
    //   RESET_LOW_CYCLES      = 2
    //   POST_RESET_GAP_CYCLES = 1
    //
    // giving 35 clock periods between enable going low and the
    // next enable going high.
    //
    parameter integer GAP_CYCLES            = 32;
    parameter integer RESET_LOW_CYCLES      = 2;
    parameter integer POST_RESET_GAP_CYCLES = 1;

    // For the final input vector there is no following vector to
    // define the end of the output interval. Capture this many
    // falling-edge output characters and then finish simulation.
    parameter integer FINAL_OUTPUT_CYCLES = 35;

    parameter INPUT_FILE  = "input_vectors.txt";
    parameter OUTPUT_FILE = "output_strings.txt";

    reg clk;
    reg rst_n;
    reg enable;
    reg I;
    reg VPWR;
    reg VGND;

    wire O_0_, O_1_, O_2_, O_3_;
    wire O_4_, O_5_, O_6_, O_7_;
    wire success;
    wire [7:0] O;

    assign O = {O_7_, O_6_, O_5_, O_4_,
                O_3_, O_2_, O_1_, O_0_};

    integer input_file;
    integer output_file;
    integer scan_result;
    integer bit_index;
    integer vector_number;
    integer char_count;
    integer k;

    reg [VECTOR_BITS-1:0] current_vector;
    reg [VECTOR_BITS-1:0] next_vector;
    reg next_valid;

    puzzle dut (
        .I       (I),
        .O_0_    (O_0_),
        .O_1_    (O_1_),
        .O_2_    (O_2_),
        .O_3_    (O_3_),
        .O_4_    (O_4_),
        .O_5_    (O_5_),
        .O_6_    (O_6_),
        .O_7_    (O_7_),
        .VGND    (VGND),
        .VPWR    (VPWR),
        .clk     (clk),
        .enable  (enable),
        .rst_n   (rst_n),
        .success (success)
    );

    // ------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #CLOCK_HALF_PERIOD_NS clk = ~clk;
    end

    // ------------------------------------------------------------
    // Write O[7:0] as one ASCII character.
    //
    // This task is called only on falling edges while enable is low.
    // ------------------------------------------------------------
    task sample_O;
        begin
            // Allow DUT logic driven by this falling edge to settle
            // before reading O. With `timescale 1ns/1ps, #0.001 is 1 ps.
            #0.001;

            if (enable !== 1'b0) begin
                $display("ERROR: output sampled while enable=%b at %0t",
                         enable, $time);
            end
            else begin
	       if (O != 8'h00) begin
                $fwrite(output_file, "%c", O);
                char_count = char_count + 1;
	       end
                // Useful diagnostic: shows exactly what is written.
//                $display("[%0t] output char %0d: O=%02h '%c'",
//                         $time, char_count, O, O);
            end
        end
    endtask

    // ------------------------------------------------------------
    // Prepare before the very first input vector.
    //
    // There is no preceding vector, so no output characters are
    // written during this initial reset sequence.
    // ------------------------------------------------------------
    task initial_prepare;
        begin
            @(negedge clk);
            rst_n  = 1'b0;
            enable = 1'b0;
            I      = 1'b0;

            repeat (RESET_LOW_CYCLES)
                @(negedge clk);

            rst_n = 1'b1;

            repeat (POST_RESET_GAP_CYCLES)
                @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------
    // Shift one 121-bit vector.
    //
    // The left-most ASCII input bit is shifted first.
    // I changes only on falling clock edges; the DUT captures it
    // on the following rising edge.
    //
    // This task returns on a falling edge immediately after making
    // enable low.
    // ------------------------------------------------------------
    task send_vector;
        input [VECTOR_BITS-1:0] vector;
        begin
            enable = 1'b1;
            I = vector[VECTOR_BITS-1];

            for (bit_index = VECTOR_BITS-2;
                 bit_index >= 0;
                 bit_index = bit_index - 1) begin
                @(negedge clk);
                I = vector[bit_index];
            end

            // Capture the final bit.
            @(posedge clk);

            // Start the output phase on the following falling edge.
            @(negedge clk);
            enable = 1'b0;
            I      = 1'b0;
        end
    endtask

    // ------------------------------------------------------------
    // Capture the ASCII output string belonging to the preceding
    // input vector and prepare for the next vector.
    //
    // Sequence:
    //
    //   1. Sample O immediately on the falling edge on which
    //      send_vector made enable low.
    //
    //   2. Leave reset inactive for GAP_CYCLES.
    //
    //   3. Pulse rst_n low for RESET_LOW_CYCLES.
    //
    //   4. Release reset and wait POST_RESET_GAP_CYCLES.
    //
    //   5. Return on the falling edge on which the caller can make
    //      enable high for the next vector.
    //
    // Every falling edge encountered while enable is low is sampled.
    // ------------------------------------------------------------
    task capture_between_vectors;
        begin
            char_count = 0;

            // Current falling edge: enable has just gone low.
            sample_O();

            // Normal output gap first.
            repeat (GAP_CYCLES) begin
                @(negedge clk);
                sample_O();
            end

            // Reset pulse occurs at the END of GAP_CYCLES.
            rst_n = 1'b0;

            repeat (RESET_LOW_CYCLES) begin
                @(negedge clk);
                sample_O();
            end

            // End of reset pulse.
            rst_n = 1'b1;

            // One complete clock period between reset release and
            // the next enable assertion by default.
            repeat (POST_RESET_GAP_CYCLES) begin
                @(negedge clk);
                sample_O();
            end

            // One line per preceding input vector.
            $fwrite(output_file, "\n");
        end
    endtask

    // ------------------------------------------------------------
    // Capture output after the final vector, then simulation ends.
    //
    // The first character is sampled immediately on the falling edge
    // where send_vector made enable low. FINAL_OUTPUT_CYCLES is the
    // TOTAL number of characters sampled for the final vector.
    // ------------------------------------------------------------
    task capture_final_output;
        begin
            char_count = 0;

            if (FINAL_OUTPUT_CYCLES > 0) begin
                sample_O();

                for (k = 1; k < FINAL_OUTPUT_CYCLES; k = k + 1) begin
                    @(negedge clk);
                    sample_O();
                end
            end

            $fwrite(output_file, "\n");
        end
    endtask

    // ------------------------------------------------------------
    // Main stimulus
    // ------------------------------------------------------------
    initial begin : stimulus

        VPWR          = 1'b1;
        VGND          = 1'b0;
        rst_n         = 1'b1;
        enable        = 1'b0;
        I             = 1'b0;
        vector_number = 0;
        char_count    = 0;
        next_valid    = 1'b0;

        input_file = $fopen(INPUT_FILE, "r");

        if (input_file == 0) begin
            $display("ERROR: cannot open input file '%s'", INPUT_FILE);
            $finish;
        end

        output_file = $fopen(OUTPUT_FILE, "w");

        if (output_file == 0) begin
            $display("ERROR: cannot create output file '%s'", OUTPUT_FILE);
            $fclose(input_file);
            $finish;
        end

        $display("Reading input vectors from %s", INPUT_FILE);
        $display("Writing output strings to %s", OUTPUT_FILE);

        // Read the first vector.
        scan_result = $fscanf(input_file, "%b", current_vector);

        if (scan_result != 1) begin
            $display("No input vectors found.");
            $fclose(input_file);
            $fclose(output_file);
            $finish;
        end

        initial_prepare();

        // Process vectors until EOF.
        while (1) begin

            vector_number = vector_number + 1;

            $display("[%0t] Sending vector %0d",
                     $time, vector_number);

            send_vector(current_vector);

            // Look ahead now. If there is another line, capture the
            // current response and then start that line. Otherwise
            // capture the final response and terminate simulation.
            scan_result = $fscanf(input_file, "%b", next_vector);
            next_valid = (scan_result == 1);

            if (next_valid) begin

                capture_between_vectors();

                $display("[%0t] Vector %0d output complete: %0d chars",
                         $time, vector_number, char_count);

                current_vector = next_vector;

                // capture_between_vectors returns at a falling edge.
                // send_vector will assert enable immediately and place
                // the first input bit at that same safe edge.

            end
            else begin

                capture_final_output();

                $display("[%0t] Final vector %0d output complete: %0d chars",
                         $time, vector_number, char_count);

                $fclose(input_file);
                $fclose(output_file);

                $display("End of input file reached. Processed %0d vectors.",
                         vector_number);

                // Explicitly terminate the forever clock and simulation.
                $finish;
            end
        end
    end

    // ------------------------------------------------------------
    // VCD waveform output
    // ------------------------------------------------------------
    initial begin
        $dumpfile("puzzle_tb.vcd");
        $dumpvars(0, puzzle_tb);
    end

endmodule
