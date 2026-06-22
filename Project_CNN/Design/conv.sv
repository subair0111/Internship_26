`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: conv
// Description: Fully Corrected Parallel Fixed-point 2D Convolution Engine
// Fixes Applied: 
//   - Replaced backward loop with an upward incrementing loop to capture 
//     all columns of the sliding window register matrix.
//////////////////////////////////////////////////////////////////////////////////
module conv #(
    parameter int PIX_WIDTH          = 8,
    parameter int WEIGHT_WIDTH       = 10,
    parameter int WEIGHT_FRACT_WIDTH = 5,
    parameter int KERNEL_DIMENSION   = 3,
    parameter string TRUNK           = "TRUE",
    parameter bit [11:0] img_width   = 28,
    parameter bit [11:0] img_height  = 28
) (
    input  logic                        clk,        // Clock
    input  logic                        clk_en,     // Clock Enable
    input  logic                        rst_n,      // Asynchronous reset active low
    
    // Input Pixel Stream
    input  logic [PIX_WIDTH-1:0]        i_data,
    input  logic                        i_valid,
    input  logic                        i_sop,
    input  logic                        i_eop,
    

    // Output Pixel Stream
    // NOTE: Full-precision (unshifted, untruncated) per-channel partial sum.
    // Rescaling (>>> WEIGHT_FRACT_WIDTH) and truncation/saturation to PIX_WIDTH
    // now happen ONCE in conv_block.sv, after summing across all input channels
    // and adding the bias. Doing it here (per-channel, before the cross-channel
    // sum) was the root cause of the wrong-prediction bug: it silently wrapped
    // (no saturation) on any channel whose partial sum left the 8-bit range,
    // and repeatedly lost precision once per channel instead of once overall.
    output logic signed [3+WEIGHT_WIDTH+PIX_WIDTH:0] o_data,
    output logic                        o_valid,
    output logic                        o_sop,
    output logic                        o_eop,
    
    // Clean 2D Native SystemVerilog Packed Array for Kernel Values
    input  logic signed [WEIGHT_WIDTH-1:0] kernel [0:KERNEL_DIMENSION-1][0:KERNEL_DIMENSION-1],
    
    output logic                        ready,
    output logic [11:0]                 cols_cntr,
    output logic [11:0]                 rows_cntr
);

    localparam int MAX_DEPTH = 1920;

    // -------------------------------------------------------------------------
    // Line Buffers (Correctly Inferred Block RAMs via Standard Vivado Templates)
    // -------------------------------------------------------------------------
    logic [11:0] line_buf_waddr;
    logic [11:0] line_buf_raddr;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            line_buf_waddr <= '0;
        end else if (clk_en && (i_valid || !ready)) begin
            if (line_buf_waddr == img_width - 1)
                line_buf_waddr <= '0;
            else
                line_buf_waddr <= line_buf_waddr + 1'b1;
        end
    end
    
    assign line_buf_raddr = line_buf_waddr;

    // Line buffer unpack matrices
    logic [PIX_WIDTH-1:0] line_buf_out [0:KERNEL_DIMENSION-2];
    logic [PIX_WIDTH-1:0] delayed_line [0:KERNEL_DIMENSION-1];

    generate
        for (genvar k = 0; k < KERNEL_DIMENSION-1; k++) begin : gen_line_buffers
            (* ram_style = "block" *) logic [PIX_WIDTH-1:0] ram [0:MAX_DEPTH-1];
            logic [PIX_WIDTH-1:0] din;

            assign din = (k == 0) ? i_data : line_buf_out[k-1];

            always_ff @(posedge clk) begin
                if (clk_en) begin
                    if (i_valid || !ready) begin
                        ram[line_buf_waddr] <= din;
                    end
                end
            end

            // REAL FIX: line_buf_out must be delayed by EXACTLY img_width cycles
            // relative to din (one full row period), so that the K-1 row taps of
            // the window each see a different row of the image. The previous
            // version read through an extra registered stage (ram_read_reg) and
            // then "compensated" for that extra cycle with a bypass mux that, on
            // every cycle where (i_valid || !ready) is true -- i.e. on EVERY
            // cycle of continuous streaming, which is the normal case here --
            // selected the immediate, zero-delay "din" instead of the delayed
            // RAM content. That collapsed every row tap of the kernel onto the
            // CURRENT row (delayed_line[0] == delayed_line[1] == ... always),
            // turning the 2D convolution into a degenerate 1D, column-only
            // correlation and discarding all vertical/row structure of the
            // image. A plain combinational read of this write-address-reused RAM
            // gives exactly the needed img_width-cycle delay with no bypass: the
            // read of ram[line_buf_raddr] naturally returns whatever was written
            // there one full row-period ago, since this cycle's write (driven by
            // a non-blocking assignment) hasn't taken effect yet.
            assign line_buf_out[k] = ram[line_buf_raddr];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Sliding Window Register Matrix
    // -------------------------------------------------------------------------
    logic [PIX_WIDTH-1:0] after_fifos_ffs [0:KERNEL_DIMENSION-1][0:KERNEL_DIMENSION-2];
    logic [PIX_WIDTH-1:0] delayed_pix     [0:KERNEL_DIMENSION-1][0:KERNEL_DIMENSION-1];

    always_comb begin
        for (int i = 0; i < KERNEL_DIMENSION; i++) begin
            delayed_line[i] = (i == 0) ? i_data : line_buf_out[i-1];
        end

        for (int i = 0; i < KERNEL_DIMENSION; i++) begin
            for (int y = 0; y < KERNEL_DIMENSION; y++) begin
                delayed_pix[i][y] = (y == 0) ? delayed_line[i] : after_fifos_ffs[i][y-1];
            end
        end
    end

    // CRITICAL FIX: Upward-counting loop ensures every register index shifts correctly
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            after_fifos_ffs <= '{default: '0};
        end else if (clk_en && (i_valid || !ready)) begin
            for (int i = 0; i < KERNEL_DIMENSION; i++) begin
                for (int y = 1; y < KERNEL_DIMENSION-1; y++) begin
                    after_fifos_ffs[i][y] <= after_fifos_ffs[i][y-1];
                end
                after_fifos_ffs[i][0] <= delayed_line[i];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Convolution Mathematics (Fixed Array Fabric)
    // -------------------------------------------------------------------------
    (* use_dsp = "yes" *)
    logic signed [WEIGHT_WIDTH+PIX_WIDTH-1:0] mult_result [0:KERNEL_DIMENSION-1][0:KERNEL_DIMENSION-1];

    always_ff @(posedge clk or negedge rst_n) begin : proc_multiplying
        if (~rst_n) begin
            mult_result <= '{default: '0};
        end else if (clk_en) begin
            if (i_valid || !ready) begin
                for (int i = 0; i < KERNEL_DIMENSION; i++) begin
                    for (int y = 0; y < KERNEL_DIMENSION; y++) begin
                        // REAL FIX: delayed_pix[i][y] holds the pixel at row-delay i,
                        // column-delay y (i=0/y=0 = the most-recently-streamed pixel,
                        // i.e. the BOTTOM-RIGHT corner of the sliding window). For
                        // kernel[i][y] to multiply the pixel at WINDOW position
                        // (row=i, col=y) -- matching the trained weights' row-major
                        // convention, with no kernel flip -- the pixel index must be
                        // mirrored: window(i,y) = delayed_pix[(K-1)-i][(K-1)-y].
                        // Indexing delayed_pix[i][y] directly (no mirror) computes a
                        // 180-degree-rotated kernel instead of the intended
                        // cross-correlation.
                        mult_result[i][y] <= $signed({1'b0, delayed_pix[(KERNEL_DIMENSION-1)-i][(KERNEL_DIMENSION-1)-y]}) * kernel[i][y];
                    end
                end
            end
        end
    end

    localparam int SUM1_WIDTH = 4 + (WEIGHT_WIDTH + PIX_WIDTH); 
    
    logic signed [SUM1_WIDTH-1:0] total_combinational_sum;
    logic signed [SUM1_WIDTH-1:0] mult_sum_out;

    always_comb begin
        total_combinational_sum = '0;
        for (int i = 0; i < KERNEL_DIMENSION; i++) begin
            for (int y = 0; y < KERNEL_DIMENSION; y++) begin
                total_combinational_sum = total_combinational_sum + mult_result[i][y];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin : proc_mult_sum
        if (~rst_n) begin
            mult_sum_out <= '0;
        end else if (clk_en) begin
            // Full precision, unshifted. The >>> WEIGHT_FRACT_WIDTH rescale is
            // deferred to conv_block.sv, after the cross-channel sum + bias add.
            mult_sum_out <= total_combinational_sum;
        end
    end

    // Normalization / Activation Logic
    // RELU and truncation/saturation are applied once, downstream in
    // conv_block.sv, after summing across all input channels and adding bias —
    // not here per-channel (see note on o_data above).
    assign o_data = mult_sum_out;

    // -------------------------------------------------------------------------
    // Latency Pipeline & Control Counters
    // -------------------------------------------------------------------------
    logic [2:0] valid_delay;
logic       valid_delayed;

logic [2:0] sop_delay;
logic [2:0] eop_delay;

assign valid_delayed = valid_delay[2];

always_ff @(posedge clk or negedge rst_n) begin
    if(~rst_n) begin
        sop_delay <= '0;
        eop_delay <= '0;
    end
    else if(clk_en) begin
        sop_delay <= {sop_delay[1:0], i_sop};
        eop_delay <= {eop_delay[1:0], i_eop};
    end
end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            valid_delay <= '0;
        end else if (clk_en) begin
            valid_delay <= {valid_delay[1:0], i_valid && ready};
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            cols_cntr <= '0;
            rows_cntr <= '0;
        end else if (clk_en) begin
            if (valid_delayed || (!ready && (rows_cntr == img_height))) begin
                cols_cntr <= (cols_cntr == img_width-1) ? '0 : (cols_cntr + 1'b1);
                if (cols_cntr == img_width-1)
                    rows_cntr <= (rows_cntr == img_height) ? '0 : (rows_cntr + 1'b1);
            end
            else if (i_sop) begin
                cols_cntr <= '0;
                rows_cntr <= '0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            ready <= 1'b1;
        end else if (clk_en) begin
            if (i_eop) begin
                ready <= 1'b0;
            end
            else if (rows_cntr == 0)
                ready <= 1'b1;
        end
    end

    assign o_valid = valid_delayed && (rows_cntr > 1) && (rows_cntr < img_height) && (cols_cntr > 1) && (cols_cntr < img_width);
    assign o_sop = sop_delay[2];
assign o_eop = eop_delay[2];

endmodule
