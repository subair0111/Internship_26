module maxpooling import cnn_config_pkg::*; #(
    parameter PIX_WIDTH      = cnn_config_pkg::PIX_WIDTH,
    parameter POOL_DIMENSION = cnn_config_pkg::POOL_DIMENSION,
    parameter WIDTH          = cnn_config_pkg::IMG_WIDTH,
    parameter HEIGHT         = cnn_config_pkg::IMG_HEIGHT
) (
    input                        clk,
    input                        clk_en,
    input                        rst_n,
    
    // Input pixels
    input        [PIX_WIDTH-1:0] i_data,
    input                        i_valid,
    input                        i_sop,
    input                        i_eop,

    // Output pixels
    output       [PIX_WIDTH-1:0] o_data,
    output                       o_valid,
    output                       o_sop,
    output                       o_eop,

    output logic                 ready,
    output logic [11:0]          cols_cntr,
    output logic [11:0]          rows_cntr
);

    // FIFO row buffers
    logic [WIDTH-1:0][PIX_WIDTH-1:0] fifo[POOL_DIMENSION-1];

    logic [PIX_WIDTH-1:0] delayed_line[POOL_DIMENSION];

    bit [POOL_DIMENSION-2:0][PIX_WIDTH-1:0]
        after_fifos_ffs[POOL_DIMENSION];

    logic [PIX_WIDTH-1:0]
        delayed_pix[POOL_DIMENSION][POOL_DIMENSION];

    // Window generation
    always_comb begin
        foreach (delayed_line[i])
            delayed_line[i] =
                (i == 0) ? i_data : fifo[i-1][WIDTH-1];

        foreach (delayed_pix[i,y])
            delayed_pix[i][y] =
                (y == 0) ? delayed_line[i]
                         : after_fifos_ffs[i][y-1];
    end

    always_ff @(posedge clk) begin
        if (clk_en && (i_valid || !ready)) begin

            foreach (fifo[i])
                fifo[i] <= {
                    fifo[i][WIDTH-2:0],
                    ((i == 0) ? i_data
                              : fifo[i-1][WIDTH-1])
                };

            foreach (after_fifos_ffs[i])
                after_fifos_ffs[i] <= {
                    after_fifos_ffs[i],
                    delayed_line[i]
                };
        end
    end

    // Max detection
    logic [PIX_WIDTH-1:0] max_detected;
    logic [PIX_WIDTH-1:0] max_detected_ff;

    logic [POOL_DIMENSION-1:0][PIX_WIDTH-1:0]
        max_row_detected,
        max_row_detected_ff;

    always_comb begin

        foreach (max_row_detected[i])
            max_row_detected[i] = delayed_pix[i][0];

        for (int y = 0; y < POOL_DIMENSION; y++) begin
            for (int i = 1; i < POOL_DIMENSION; i++) begin
                if (max_row_detected[y] < delayed_pix[y][i])
                    max_row_detected[y] = delayed_pix[y][i];
            end
        end

        max_detected = max_row_detected_ff[0];

        for (int i = 1; i < POOL_DIMENSION; i++) begin
            if (max_detected < max_row_detected_ff[i])
                max_detected = max_row_detected_ff[i];
        end
    end

    always_ff @(posedge clk) begin
        if (clk_en) begin
            max_row_detected_ff <= max_row_detected;
            max_detected_ff     <= max_detected;
        end
    end

    assign o_data = max_detected_ff;

    // Valid pipeline
    logic [2:0] valid_delay = '0;

    wire valid_delayed = valid_delay[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_delay <= '0;
        else if (clk_en)
            valid_delay <=
                $size(valid_delay)'(
                {valid_delay, i_valid && ready});
    end

    // Counters
    logic [$clog2(POOL_DIMENSION)-1:0]
        valid_col,
        valid_row;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cols_cntr <= 0;
            rows_cntr <= 0;
            valid_col <= 0;
            valid_row <= 0;
        end
        else if (clk_en) begin

            if (valid_delayed) begin

                cols_cntr <=
                    (cols_cntr == WIDTH-1)
                    ? '0
                    : cols_cntr + 1'b1;

                valid_col <=
                    (valid_col == POOL_DIMENSION-1)
                    ? '0
                    : valid_col + 1'b1;

                if (cols_cntr == WIDTH-1) begin

                    rows_cntr <= rows_cntr + 1'b1;

                    valid_col <= '0;

                    valid_row <=
                        (valid_row == POOL_DIMENSION-1)
                        ? '0
                        : valid_row + 1'b1;
                end
            end
            else if (i_sop) begin
                cols_cntr <= 0;
                rows_cntr <= 0;
                valid_col <= 0;
                valid_row <= 0;
            end
        end
    end

    // Control signals
    assign ready = clk_en;

    assign o_valid =
        valid_delayed &&
        (valid_col == POOL_DIMENSION-1) &&
        (valid_row == POOL_DIMENSION-1);

    assign o_eop =
        valid_delayed &&
        (valid_col == POOL_DIMENSION-1) &&
        (cols_cntr ==
            WIDTH-(WIDTH[0]+POOL_DIMENSION[0]+1)) &&
        (rows_cntr ==
            HEIGHT-(HEIGHT[0]+POOL_DIMENSION[0]+1));

    assign o_sop =
        valid_delayed &&
        (valid_col == POOL_DIMENSION-1) &&
        (rows_cntr == POOL_DIMENSION-1) &&
        (cols_cntr == POOL_DIMENSION-1);

endmodule
