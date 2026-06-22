// -----------------------------------------------------------------------------
// Module      : conv_block
// Owner       : Member 3 (Multi-Channel Convolution Owner)
// Description : Top structural processing matrix with pipelined channel summing.
// -----------------------------------------------------------------------------
module conv_block import cnn_config_pkg::*; #(
    parameter PIX_WIDTH          = cnn_config_pkg::PIX_WIDTH         ,
    parameter WEIGHT_WIDTH       = cnn_config_pkg::WEIGHT_WIDTH      ,
    parameter WEIGHT_FRACT_WIDTH = cnn_config_pkg::WEIGHT_FRACT_WIDTH,
    parameter string TRUNK       = cnn_config_pkg::TRUNK             ,
    parameter IMG_WIDTH          = cnn_config_pkg::IMG_WIDTH         ,
    parameter IMG_HEIGHT         = cnn_config_pkg::IMG_HEIGHT        ,
    parameter KERNEL_DIMENSION   = cnn_config_pkg::KERNEL_DIMENSION  ,
    parameter IN_DIMENSION       = cnn_config_pkg::IN_DIMENSION      , // Dynamic dimensions to support Conv1 & Conv2
    parameter OUT_DIMENSION      = cnn_config_pkg::OUT_DIMENSION
) (
    input                                              clk,
    input                                              clk_en,
    input                                              rst_n,
    
    // Pixel stream ports
    input        [IN_DIMENSION-1:0][PIX_WIDTH-1:0]     i_data,
    input                                              i_valid,
    input                                              i_sop,
    input                                              i_eop,
    
    // Structured outputs
    output logic [OUT_DIMENSION-1:0][((TRUNK == "TRUE") ? PIX_WIDTH : (PIX_WIDTH+WEIGHT_FRACT_WIDTH))-1:0] o_data,
    output logic                                       o_valid,
    output logic                                       o_sop,
    output logic                                       o_eop,
    
    // Configuration loader interface
    input  logic                                       weight_load_en,
    input  logic [15:0]                                weight_addr,
    input  logic [WEIGHT_WIDTH-1:0]                    weight_data,
    
    output logic                                       o_ready
);

    // Configuration wire routes
    wire [OUT_DIMENSION-1:0][IN_DIMENSION-1:0][KERNEL_DIMENSION-1:0][KERNEL_DIMENSION-1:0][WEIGHT_WIDTH-1:0] kernel;
    wire [OUT_DIMENSION-1:0][WEIGHT_WIDTH-1:0] bias;

    // Sub-module instantiation
    kernel_memory #(
        .WEIGHT_WIDTH     (WEIGHT_WIDTH),
        .KERNEL_DIMENSION (KERNEL_DIMENSION),
        .IN_DIMENSION     (IN_DIMENSION),
        .OUT_DIMENSION    (OUT_DIMENSION)
    ) inst_kernel_mem (
        .clk              (clk),
        .rst_n            (rst_n),
        .weight_load_en   (weight_load_en),
        .weight_addr      (weight_addr[$clog2(OUT_DIMENSION*(IN_DIMENSION*KERNEL_DIMENSION*KERNEL_DIMENSION)+OUT_DIMENSION)-1:0]),
        .weight_data      (weight_data),
        .o_kernel         (kernel),
        .o_bias           (bias)
    );

    // Compute width parameters
    // Final, externally-visible output width (unchanged interface).
    localparam OUT_DATA_WIDTH = (TRUNK == "TRUE") ? PIX_WIDTH : (PIX_WIDTH+WEIGHT_FRACT_WIDTH);

    // Full-precision per-channel conv output width (must match conv.sv's
    // internal SUM1_WIDTH = 4 + WEIGHT_WIDTH + PIX_WIDTH exactly).
    localparam FULL_WIDTH = 4 + WEIGHT_WIDTH + PIX_WIDTH;
    // Extra guard bits so summing IN_DIMENSION full-precision channel values
    // can't overflow.
    localparam ACC_GUARD  = $clog2(IN_DIMENSION+1);
    localparam ACC_WIDTH  = FULL_WIDTH + ACC_GUARD;
    // One more guard bit of headroom for the bias addition.
    localparam BIASED_WIDTH = ACC_WIDTH + 1;

    logic signed [FULL_WIDTH-1:0] conv_outputs[OUT_DIMENSION][IN_DIMENSION];

    logic valid[OUT_DIMENSION][IN_DIMENSION];
    logic sop  [OUT_DIMENSION][IN_DIMENSION];
    logic eop  [OUT_DIMENSION][IN_DIMENSION];
    logic ready[OUT_DIMENSION][IN_DIMENSION];
    
    // Matrix hardware layout generator
    genvar row, col;
    generate
        for (row = 0; row < OUT_DIMENSION; row++) begin : gen_row
            for (col = 0; col < IN_DIMENSION; col++) begin : gen_col
                
                // Fix: Temporary unpacked array to bridge type compatibility
                logic signed [WEIGHT_WIDTH-1:0] local_kernel [0:KERNEL_DIMENSION-1][0:KERNEL_DIMENSION-1];
                
                // Continuous unpack assignment conversion block
                always_comb begin
                    for (int r = 0; r < KERNEL_DIMENSION; r++) begin
                        for (int c = 0; c < KERNEL_DIMENSION; c++) begin
                            local_kernel[r][c] = kernel[row][col][r][c];
                        end
                    end
                end

                conv #(
                    .PIX_WIDTH         (PIX_WIDTH),
                    .WEIGHT_WIDTH      (WEIGHT_WIDTH),
                    .WEIGHT_FRACT_WIDTH(WEIGHT_FRACT_WIDTH),
                    .TRUNK             (TRUNK),
                    .KERNEL_DIMENSION  (KERNEL_DIMENSION),
                    .img_width         (IMG_WIDTH),
                    .img_height        (IMG_HEIGHT)
                ) inst_conv (
                    .clk      (clk),
                    .clk_en   (clk_en),
                    .rst_n    (rst_n),
                    .i_data   (i_data[col]),
                    .i_valid  (i_valid),
                    .i_sop    (i_sop),
                    .i_eop    (i_eop),
                    .o_data   (conv_outputs[row][col]),
                    .o_valid  (valid[row][col]),
                    .o_sop    (sop[row][col]),
                    .o_eop    (eop[row][col]),
                    .kernel   (local_kernel), // Pass the compatible unpacked matrix
                    .ready    (ready[row][col]),
                    .cols_cntr(),
                    .rows_cntr()
                );
            end
        end
    endgenerate

    // Pipelined Channel Summation Adder Tree (full precision — no truncation
    // or rescale yet; that happens once, below, after the bias add)
    logic signed [ACC_WIDTH-1:0] sum_pipeline[OUT_DIMENSION];

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            for (int i = 0; i < OUT_DIMENSION; i++) begin
                sum_pipeline[i] <= '0;
            end
        end else if (clk_en) begin
            for (int x = 0; x < OUT_DIMENSION; x++) begin
                automatic logic signed [ACC_WIDTH-1:0] dynamic_sum = '0;
                for (int z = 0; z < IN_DIMENSION; z++) begin
                    dynamic_sum = dynamic_sum + $signed(conv_outputs[x][z]);
                end
                sum_pipeline[x] <= dynamic_sum; // Broken into register stages to maximize Fmax timing
            end
        end
    end

    // Pipeline delay matching stage for downstream data compliance
    logic r_valid, r_sop, r_eop;
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            r_valid <= 1'b0;
            r_sop   <= 1'b0;
            r_eop   <= 1'b0;
        end else if (clk_en) begin
            r_valid <= valid[0][0];
            r_sop   <= sop[0][0];
            r_eop   <= eop[0][0];
        end
    end

    // Bias addition stage with pipeline matching alignment.
    //
    // REAL FIX (Bug B - scale mismatch): sum_pipeline[x] is a sum of
    // (pixel * weight) products. Pixel is Q.WEIGHT_FRACT_WIDTH and weight is
    // Q.WEIGHT_FRACT_WIDTH, so each product — and therefore sum_pipeline[x] —
    // is still scaled by 2^(2*WEIGHT_FRACT_WIDTH), NOT 2^WEIGHT_FRACT_WIDTH.
    // bias[x] comes straight out of kernel_memory as a single Q.WEIGHT_FRACT_WIDTH
    // value, scaled by only 2^WEIGHT_FRACT_WIDTH. Adding them directly (the old
    // code) and then applying a single >>> WEIGHT_FRACT_WIDTH divides the bias
    // by an extra, unwanted 2^WEIGHT_FRACT_WIDTH, making every learned bias
    // ~32x too small in the final result.
    //
    // The two scales must be matched BEFORE the values are combined:
    //   TRUNK == "TRUE"  -> bring sum_pipeline down to bias's scale first
    //                       (>>> WEIGHT_FRACT_WIDTH), then add bias as-is.
    //   TRUNK == "FALSE" -> bring bias UP to sum_pipeline's scale first
    //                       (<<< WEIGHT_FRACT_WIDTH), then add, keeping full
    //                       precision (no rescale of the sum at all).
    //
    // FIX (Bug A - unsaturated per-channel truncation): truncation down to
    // OUT_DATA_WIDTH uses a saturating clamp instead of a raw bit-slice, so an
    // out-of-range value clamps to the min/max representable value instead of
    // silently wrapping sign.
    localparam signed [BIASED_WIDTH-1:0] OUT_MAX =  (1 <<< (OUT_DATA_WIDTH-1)) - 1;
    localparam signed [BIASED_WIDTH-1:0] OUT_MIN = -(1 <<< (OUT_DATA_WIDTH-1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            o_valid <= 1'b0;
            o_sop   <= 1'b0;
            o_eop   <= 1'b0;
            o_data  <= '0;
        end else if (clk_en) begin
            o_valid <= r_valid;
            o_sop   <= r_sop;
            o_eop   <= r_eop;

            for (int x = 0; x < OUT_DIMENSION; x++) begin
                automatic logic signed [BIASED_WIDTH-1:0] shifted;

                if (TRUNK == "TRUE")
                    shifted = ($signed(sum_pipeline[x]) >>> WEIGHT_FRACT_WIDTH) + $signed(bias[x]);
                else
                    shifted = $signed(sum_pipeline[x]) + ($signed(bias[x]) <<< WEIGHT_FRACT_WIDTH);

`ifdef RELU
                if (shifted < 0)
                    o_data[x] <= '0;
                else if (shifted > OUT_MAX)
                    o_data[x] <= OUT_MAX[OUT_DATA_WIDTH-1:0];
                else
                    o_data[x] <= shifted[OUT_DATA_WIDTH-1:0];
`else
                if (shifted > OUT_MAX)
                    o_data[x] <= OUT_MAX[OUT_DATA_WIDTH-1:0];
                else if (shifted < OUT_MIN)
                    o_data[x] <= OUT_MIN[OUT_DATA_WIDTH-1:0];
                else
                    o_data[x] <= shifted[OUT_DATA_WIDTH-1:0];
`endif
            end
        end
    end

    assign o_ready = ready[0][0];

endmodule : conv_block
