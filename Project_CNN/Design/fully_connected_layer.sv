// =============================================================================
// -----------------------------------------------------------------------------
module fully_connected_layer import cnn_config_pkg::*; #(
    parameter int unsigned PIX_WIDTH          = cnn_config_pkg::PIX_WIDTH         ,
    parameter int unsigned WEIGHT_WIDTH       = cnn_config_pkg::WEIGHT_WIDTH      ,
    parameter int unsigned WEIGHT_FRACT_WIDTH = cnn_config_pkg::WEIGHT_FRACT_WIDTH,
    parameter int unsigned IN_DIMENSION       = cnn_config_pkg::FLAT_IN_DIM[0]    ,
    parameter int unsigned OUT_DIMENSION      = cnn_config_pkg::FLAT_OUT_DIM[0]
) (
    input  logic                                              clk                  ,
    input  logic                                              clk_en               ,
    input  logic                                              rst_n                ,
    // ── input stream ──────────────────────────────────────────────────────────
    input  logic [PIX_WIDTH-1:0]                              i_data               ,
    input  logic                                              i_valid              ,
    input  logic                                              i_sop                ,
    input  logic                                              i_eop                ,
    // ── output stream ─────────────────────────────────────────────────────────
    output logic [PIX_WIDTH+$clog2(IN_DIMENSION)-1:0]         o_data               ,
    output logic                                              o_valid              ,
    output logic                                              o_sop                ,
    output logic                                              o_eop                ,
    output logic                                              o_ready              ,
    // ── Improvement #4 : Runtime weight-loader interface ─────────────────────
    //   sel == OUT_DIMENSION  →  write bias[addr]
    //   sel <  OUT_DIMENSION  →  write weight_rom[sel][addr]
    input  logic                                              weight_load_en       ,
    input  logic [$clog2(IN_DIMENSION)-1:0]                   weight_addr          ,
    input  logic [$clog2(OUT_DIMENSION):0]                    weight_sel           ,
    input  logic [WEIGHT_WIDTH-1:0]                           weight_data          ,
    // ── Legacy weight interface (aliases → new ports for TB compatibility) ────
    input  logic [WEIGHT_WIDTH-1:0]                           weights_mem_in_data  ,
    input  logic [$clog2(IN_DIMENSION)-1:0]                   weights_mem_in_addr  ,
    input  logic [$clog2(OUT_DIMENSION):0]                    weights_mem_sel_addr ,
    input  logic                                              weights_mem_in_fc_wr ,
    // ── Improvement #3 : performance-monitor hooks ────────────────────────────
    output logic                                              o_frame_start        ,
    output logic                                              o_frame_done         ,
    output logic                                              o_busy               ,
    // ── Improvement #5 : status-register outputs ──────────────────────────────
    output logic [2:0]                                        o_state              ,
    output logic [$clog2(IN_DIMENSION)-1:0]                   o_col_cntr           ,
    output logic [$clog2(OUT_DIMENSION)-1:0]                  o_out_cntr
);

    // =========================================================================
    // Internal types / constants
    // =========================================================================
    localparam int unsigned ACC_W = PIX_WIDTH + WEIGHT_WIDTH + $clog2(IN_DIMENSION);

    typedef enum logic [2:0] {
        IDLE    = 3'b001,
        FILL    = 3'b010,
        RELEASE = 3'b100
    } e_state_t;

    e_state_t state;

    // =========================================================================
    // Improvement #4 — unified write bus
    // Legacy ports are OR'd so either interface can write.
    // =========================================================================
    logic                          wr_en;
    logic [$clog2(IN_DIMENSION)-1:0]  wr_addr;
    logic [$clog2(OUT_DIMENSION):0]   wr_sel;
    logic [WEIGHT_WIDTH-1:0]          wr_data;

    assign wr_en   = weight_load_en | weights_mem_in_fc_wr;
    assign wr_addr = weight_load_en ? weight_addr         : weights_mem_in_addr;
    assign wr_sel  = weight_load_en ? weight_sel          : weights_mem_sel_addr;
    assign wr_data = weight_load_en ? weight_data         : weights_mem_in_data[WEIGHT_WIDTH-1:0];

    // =========================================================================
    // Weight ROMs — Improvement #1: use dual_port_ram so writes don't corrupt
    // ongoing reads; original single_port_rom is preserved below for reference.
    // =========================================================================
    logic [OUT_DIMENSION-1:0]        weight_wr;
    logic [WEIGHT_WIDTH-1:0]         weights [OUT_DIMENSION];

    always_comb begin
        weight_wr = '0;
        if (wr_sel < ($clog2(OUT_DIMENSION)+1)'(OUT_DIMENSION))
            weight_wr[wr_sel[$clog2(OUT_DIMENSION)-1:0]] = wr_en;
    end

    logic [$clog2(IN_DIMENSION)-1:0] col_cntr;

    genvar y;
    generate
        for (y = 0; y < OUT_DIMENSION; y++) begin : gen_weight_ram
            dual_port_ram #(
                .ADDR_WIDTH ($clog2(IN_DIMENSION)),
                .DATA_WIDTH (WEIGHT_WIDTH)
            ) weight_ram (
                .clk    (clk),
                .we     (weight_wr[y]),
                .w_addr (wr_addr),
                .w_data (wr_data),
                .r_addr (col_cntr),
                .r_data (weights[y])
            );
        end
    endgenerate

    // =========================================================================
    // Bias bank
    // =========================================================================
    logic [WEIGHT_WIDTH-1:0] bias [OUT_DIMENSION];

    always_ff @(posedge clk) begin
        if (wr_en && (wr_sel == ($clog2(OUT_DIMENSION)+1)'(OUT_DIMENSION)))
            bias[wr_addr] <= wr_data;
    end

    // =========================================================================
    // Input pipeline registers (1-cycle ROM read latency compensation)
    // =========================================================================
    logic [PIX_WIDTH-1:0] i_data_ff;
    logic                 i_sop_ff, i_valid_ff;
    logic                 o_ready_ff;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_data_ff  <= '0;
            i_sop_ff   <= '0;
            i_valid_ff <= '0;
            o_ready_ff <= '0;
        end
        else begin
            i_data_ff  <= i_data;
            i_sop_ff   <= i_sop;
            i_valid_ff <= i_valid;
            o_ready_ff <= o_ready;
        end
    end

    // =========================================================================
    // MAC integrators
    // =========================================================================
    logic signed [ACC_W-1:0] integrators [OUT_DIMENSION];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            foreach (integrators[x]) integrators[x] <= '0;
        end
        else if (clk_en) begin
            if (i_valid_ff && o_ready_ff) begin
                foreach (integrators[x]) begin
                    if (i_sop_ff)
                        integrators[x] <= $signed(weights[x]) * $signed(i_data_ff);
                    else
                        integrators[x] <= $signed(weights[x]) * $signed(i_data_ff)
                                        + $signed(integrators[x]);
                end
            end
        end
    end

    // =========================================================================
    // FSM — control path
    // =========================================================================
    logic fill_delay;
    logic [$clog2(OUT_DIMENSION):0] out_cntr;

    assign o_busy     = (state != IDLE);
    assign o_state    = state;
    assign o_col_cntr = col_cntr[$clog2(IN_DIMENSION)-1:0];
    assign o_out_cntr = out_cntr[$clog2(OUT_DIMENSION)-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            col_cntr     <= '0;
            out_cntr     <= '0;
            o_valid      <= 1'b0;
            o_ready      <= 1'b1;
            o_sop        <= 1'b0;
            o_eop        <= 1'b0;
            fill_delay   <= 1'b0;
            o_frame_start<= 1'b0;
            o_frame_done <= 1'b0;
        end
        else if (clk_en) begin
            o_valid      <= 1'b0;
            o_ready      <= 1'b1;
            o_sop <= 1'b0;
            o_eop <= 1'b0;
            fill_delay   <= 1'b0;
            o_frame_start<= 1'b0;
            o_frame_done <= 1'b0;

            case (state)

                // ── IDLE ─────────────────────────────────────────────────────
                IDLE: begin
                    col_cntr <= '0;
                    out_cntr <= '0;
                    if (i_valid && i_sop && o_ready) begin
                        state        <= FILL;
                        col_cntr     <= col_cntr + 1'b1;
                        o_frame_start<= 1'b1;
                    end
                end

                // ── FILL ─────────────────────────────────────────────────────
                FILL: begin
                    if (i_valid) begin
                        col_cntr <= col_cntr + 1'b1;
                        if (i_eop) begin
                            state      <= RELEASE;
                            out_cntr   <= '0;
                            o_ready    <= 1'b0;
                            fill_delay <= 1'b1;
                        end
                    end
                end

                // ── RELEASE ───────────────────────────────────────────────────
                RELEASE: begin
                    o_ready <= 1'b0;

                    if (out_cntr == ($clog2(OUT_DIMENSION)+1)'(OUT_DIMENSION)) begin
                        state        <= IDLE;
                        o_frame_done <= 1'b1;
                    end
                    else begin
                        // REAL FIX (scale mismatch): integrators[x] = weight(Q.WEIGHT_FRACT_WIDTH)
                        // * pixel(Q.WEIGHT_FRACT_WIDTH), i.e. scaled by 2^(2*WEIGHT_FRACT_WIDTH) —
                        // a product of two already-scaled values, NOT 2^WEIGHT_FRACT_WIDTH.
                        // bias[] comes straight out of the weight ROM as a single
                        // Q.WEIGHT_FRACT_WIDTH value, scaled by only 2^WEIGHT_FRACT_WIDTH.
                        // Adding them together BEFORE descaling (the previous version) and then
                        // applying one >>> WEIGHT_FRACT_WIDTH divides the bias by an extra,
                        // unwanted 2^WEIGHT_FRACT_WIDTH, making it ~32x too SMALL relative to
                        // the MAC result, not too large. Descale the integrator down to the
                        // bias's scale FIRST, then add the bias at matching scale.
                        o_data <= ($signed(integrators[out_cntr]) >>> WEIGHT_FRACT_WIDTH) + $signed(bias[out_cntr]);
                        o_valid <= !fill_delay;
                        o_sop   <= (out_cntr == '0);
                        o_eop   <= (out_cntr == ($clog2(OUT_DIMENSION)+1)'(OUT_DIMENSION - 1));
                        out_cntr<= out_cntr + ($clog2(OUT_DIMENSION)+1)'(!fill_delay);
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule : fully_connected_layer


// =============================================================================
// dual_port_ram — Improvement #1
// True dual-port RAM: independent read and write ports.
// Synthesises to BRAM on Xilinx/Intel FPGAs.
// =============================================================================
module dual_port_ram #(
    parameter int unsigned ADDR_WIDTH = 4,
    parameter int unsigned DATA_WIDTH = 32
) (
    input  logic                   clk    ,
    // write port
    input  logic                   we     ,
    input  logic [ADDR_WIDTH-1:0]  w_addr ,
    input  logic [DATA_WIDTH-1:0]  w_data ,
    // read port (registered — 1 cycle latency)
    input  logic [ADDR_WIDTH-1:0]  r_addr ,
    output logic [DATA_WIDTH-1:0]  r_data
);
    logic [DATA_WIDTH-1:0] mem [2**ADDR_WIDTH];

    always_ff @(posedge clk) begin
        if (we)
            mem[w_addr] <= w_data;
        r_data <= mem[r_addr];
    end

endmodule : dual_port_ram


// =============================================================================
// single_port_rom — Original, preserved for backward compatibility
// =============================================================================
module single_port_rom #(
    parameter int unsigned ADDR_WIDTH = 4,
    parameter int unsigned DATA_WIDTH = 32
) (
    input  logic                   clk   ,
    input  logic [ADDR_WIDTH-1:0]  r_addr,
    input  logic [ADDR_WIDTH-1:0]  w_addr,
    input  logic [DATA_WIDTH-1:0]  data  ,
    output logic [DATA_WIDTH-1:0]  o     ,
    input  logic                   we
);
    logic [DATA_WIDTH-1:0] mem [2**ADDR_WIDTH];

    always_ff @(posedge clk) begin
        if (we)
            mem[w_addr] <= data;
        o <= mem[r_addr];
    end

endmodule : single_port_rom
