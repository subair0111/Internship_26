// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------

module kernel_memory import cnn_config_pkg::*; #(
    parameter WEIGHT_WIDTH     = cnn_config_pkg::WEIGHT_WIDTH,
    parameter KERNEL_DIMENSION = cnn_config_pkg::KERNEL_DIMENSION,
    parameter IN_DIMENSION     = cnn_config_pkg::IN_DIMENSION,
    parameter OUT_DIMENSION    = cnn_config_pkg::OUT_DIMENSION,
    
    localparam KERNEL_WORDS    = OUT_DIMENSION * IN_DIMENSION * KERNEL_DIMENSION * KERNEL_DIMENSION,
    localparam BIAS_WORDS      = OUT_DIMENSION,
    localparam TOTAL_WORDS     = KERNEL_WORDS + BIAS_WORDS
) (
    input  logic                                                                              clk,
    input  logic                                                                              rst_n,
    
    // Interface links from runtime_weight_loader
    input  logic                                                                              weight_load_en,
    input  logic [$clog2(TOTAL_WORDS)-1:0]                                                    weight_addr,
    input  logic [WEIGHT_WIDTH-1:0]                                                           weight_data,
    
    // Output parameters mapped to computational structures
    output logic [OUT_DIMENSION-1:0][IN_DIMENSION-1:0][KERNEL_DIMENSION-1:0][KERNEL_DIMENSION-1:0][WEIGHT_WIDTH-1:0] o_kernel,
    output logic [OUT_DIMENSION-1:0][WEIGHT_WIDTH-1:0]                                        o_bias
);

    // Continuous flat memory grid
    logic [TOTAL_WORDS-1:0][WEIGHT_WIDTH-1:0] memory_array;

    // Extract structured parallel interfaces out of flat memory array
    assign {o_bias, o_kernel} = memory_array;

    // Memory write array loop
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            memory_array <= '0;
        end else if (weight_load_en) begin
            memory_array[weight_addr] <= weight_data;
        end
    end

endmodule
