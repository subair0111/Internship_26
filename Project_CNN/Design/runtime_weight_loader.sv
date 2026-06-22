// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------

module runtime_weight_loader import cnn_config_pkg::*; #(
    parameter WEIGHT_WIDTH     = cnn_config_pkg::WEIGHT_WIDTH,
    parameter KERNEL_DIMENSION = cnn_config_pkg::KERNEL_DIMENSION,
    parameter IN_DIMENSION     = cnn_config_pkg::IN_DIMENSION,
    parameter OUT_DIMENSION    = cnn_config_pkg::OUT_DIMENSION,
    
    // Total footprint calculation (Kernels + Biases)
    localparam TOTAL_WORDS = (OUT_DIMENSION * IN_DIMENSION * KERNEL_DIMENSION * KERNEL_DIMENSION) + OUT_DIMENSION
) (
    input  logic                         clk,
    input  logic                         rst_n,
    
    // External Configuration Handshake Interface
    input  logic                         i_cfg_valid,   
    input  logic [WEIGHT_WIDTH-1:0]      i_cfg_data,    
    output logic                         o_cfg_ready,   
    
    // Internal Control Signals to kernel_memory
    output logic                         weight_load_en,
    output logic [$clog2(TOTAL_WORDS)-1:0] weight_addr,
    output logic [WEIGHT_WIDTH-1:0]      weight_data
);

    logic [$clog2(TOTAL_WORDS)-1:0] addr_counter;
    logic                           is_loading;

    // Signal routing
    assign o_cfg_ready    = is_loading && (addr_counter < TOTAL_WORDS);
    assign weight_load_en = i_cfg_valid && o_cfg_ready;
    assign weight_addr    = addr_counter;
    assign weight_data    = i_cfg_data;

    // Address tracking logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            addr_counter <= '0;
            is_loading   <= 1'b1;
        end else begin
            if (!is_loading) begin
                // Loader had finished a previous full load (is_loading was
                // cleared below). Re-arm it as soon as the host raises
                // i_cfg_valid again so a SECOND/THIRD/... runtime reload of
                // this same layer is actually possible. Without this, the
                // loader was a one-shot: o_cfg_ready would stay low forever
                // after the very first load completed, hanging any later
                // reload_weights_runtime() call in the testbench.
                if (i_cfg_valid) begin
                    is_loading   <= 1'b1;
                    addr_counter <= '0;
                end
            end else if (weight_load_en) begin
                if (addr_counter == TOTAL_WORDS - 1) begin
                    is_loading   <= 1'b0; // Memory full, disable loader
                    addr_counter <= '0;
                end else begin
                    addr_counter <= addr_counter + 1'b1;
                end
            end
        end
    end

endmodule
