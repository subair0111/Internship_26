// =============================================================================
// -----------------------------------------------------------------------------
module flat import cnn_config_pkg::*; #(
    parameter int unsigned PIX_WIDTH   = cnn_config_pkg::PIX_WIDTH        ,
    parameter int unsigned DIMENSION   = cnn_config_pkg::DIMENSION        ,
    parameter int unsigned IMG_W       = cnn_config_pkg::IMG_WIDTH        ,
    parameter int unsigned IMG_H       = cnn_config_pkg::IMG_HEIGHT
) (
    input  logic                                        clk         , // Clock
    input  logic                                        clk_en      , // Clock Enable
    input  logic                                        rst_n       , // Async reset active-low
    // ── input stream ─────────────────────────────────────────────────────────
    input  logic [DIMENSION-1:0][PIX_WIDTH-1:0]         i_data      ,
    input  logic                                        i_valid     ,
    input  logic                                        i_sop       ,
    input  logic                                        i_eop       ,
    // ── output stream ────────────────────────────────────────────────────────
    output logic [PIX_WIDTH-1:0]                        o_data      ,
    output logic                                        o_valid     ,
    output logic                                        o_sop       ,
    output logic                                        o_eop       ,
    output logic                                        o_ready     ,
    // ── Improvement #4 : runtime flush ───────────────────────────────────────
    input  logic                                        i_flush     ,
    // ── Improvement #3 : performance-monitor hooks ───────────────────────────
    output logic                                        o_frame_start,  // 1-cycle pulse on first accepted pixel
    output logic                                        o_frame_done ,  // 1-cycle pulse when last pixel output
    output logic                                        o_busy       ,  // high while not IDLE
    // ── Improvement #5 : status-register outputs ─────────────────────────────
    output logic [2:0]                                  o_state     ,   // raw FSM state encoding
    output logic [$clog2(IMG_H)-1:0]                    o_row       ,   // current row being filled
    output logic [$clog2(IMG_W)-1:0]                    o_col           // current col being filled
);

    // =========================================================================
    // Local derived constants
    // =========================================================================
    localparam int unsigned TOTAL     = DIMENSION * IMG_W * IMG_H;
    localparam int unsigned CNT_W     = $clog2(TOTAL) + 1;   // +1 avoids wrap at power-of-2
    localparam int unsigned PIX_CNT_W = $clog2(IMG_W * IMG_H) + 1;

    // =========================================================================
    // Improvement #1 — Synthesizable 1-D shift-register buffer
    //
    // Original code cast a 3-D packed array to a plain wire alias, which is
    // not supported by many synthesis tools.  Here we use a flat register array
    // of depth TOTAL indexed by o_cntr — straightforward BRAMable structure.
    // Pixels are written in order as they arrive (shift-in from index 0).
    // =========================================================================
    logic [PIX_WIDTH-1:0] img_buf [DIMENSION][IMG_H * IMG_W];

    // Write pointers per channel
    logic [$clog2(IMG_W * IMG_H)-1:0] wr_ptr;

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE    = 3'b001,
        FILL    = 3'b010,
        RELEASE = 3'b100
    } e_state_t;

    e_state_t state;

    logic [CNT_W-1:0]          o_cntr;
    logic [$clog2(IMG_H)-1:0]  row_cntr;
    logic [$clog2(IMG_W)-1:0]  col_cntr;

    // Improvement #1 (cont.) — flat-counter decode pulled out of the always_ff
    // block. Some synthesis tools reject `automatic` locals with non-constant
    // initializers declared inside a case branch of a clocked process; a plain
    // combinational decode avoids the issue and is functionally identical.
    //
    // NOTE: this MUST be true division/modulo, not a bit-slice. A bit-slice
    // (o_cntr[hi:lo]) only computes "divide/mod by IMG_W*IMG_H" correctly when
    // IMG_W*IMG_H is an exact power of two. For non-power-of-two spatial sizes
    // (e.g. a 5x5 = 25 pooled feature map) a bit-slice silently divides/mods by
    // the next power of two instead (32 for 25), which both misaligns the
    // channel boundary and lets rel_px run past the buffer's real depth,
    // producing out-of-range (X) reads that then poison the downstream FC
    // accumulator for the rest of the frame.
    logic [$clog2(DIMENSION)-1:0]   rel_ch;
    logic [$clog2(IMG_W*IMG_H)-1:0] rel_px;

    assign rel_ch = o_cntr / (IMG_W * IMG_H);
    assign rel_px = o_cntr % (IMG_W * IMG_H);

    // ── status outputs (Improvement #5) ──────────────────────────────────────
    assign o_state = state;
    assign o_row   = row_cntr;
    assign o_col   = col_cntr;
    assign o_busy  = (state != IDLE);

    // =========================================================================
    // Main FSM — control path
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            o_cntr       <= '0;
            o_valid      <= 1'b0;
            o_ready      <= 1'b1;
            o_sop        <= 1'b0;
            o_eop        <= 1'b0;
            o_frame_start<= 1'b0;
            o_frame_done <= 1'b0;
            row_cntr     <= '0;
            col_cntr     <= '0;
            wr_ptr       <= '0;
        end
        else if (clk_en) begin
            // default de-assertions
            o_valid      <= 1'b0;
            o_frame_start<= 1'b0;
            o_frame_done <= 1'b0;
            o_ready      <= (state == IDLE);   // back-pressure: not ready while releasing

            // ── Improvement #4 : flush overrides everything ──────────────────
            if (i_flush) begin
                state    <= IDLE;
                wr_ptr   <= '0;
                row_cntr <= '0;
                col_cntr <= '0;
                o_ready  <= 1'b1;
            end
            else begin
                case (state)

                    // ── IDLE ─────────────────────────────────────────────────
                    IDLE: begin
                        o_ready  <= 1'b1;
                        wr_ptr   <= '0;
                        row_cntr <= '0;
                        col_cntr <= '0;

                        if (i_valid && i_sop) begin
                            state        <= FILL;
                            o_frame_start<= 1'b1;   // perf-monitor pulse
                            // The write-path block (below) stores this pixel into
                            // img_buf[ch][wr_ptr] (slot 0) on this same cycle, so
                            // wr_ptr must advance here too -- otherwise the next
                            // pixel (first one seen in FILL) also targets slot 0,
                            // clobbering this pixel and shifting every later pixel
                            // down by one slot.
                            wr_ptr       <= wr_ptr + 1'b1;
                        end
                    end

                    // ── FILL ─────────────────────────────────────────────────
                    FILL: begin
                        o_ready <= 1'b1;

                        if (i_valid) begin
                            // advance column / row tracking (status regs)
                            if (col_cntr == IMG_W[$clog2(IMG_W)-1:0] - 1) begin
                                col_cntr <= '0;
                                row_cntr <= row_cntr + 1'b1;
                            end
                            else
                                col_cntr <= col_cntr + 1'b1;

                            wr_ptr <= wr_ptr + 1'b1;

                            if (i_eop) begin
                                state   <= RELEASE;
                                o_cntr  <= '0;
                                o_ready <= 1'b0;
                            end
                        end
                    end

                    // ── RELEASE ───────────────────────────────────────────────
                    RELEASE: begin
                        o_ready <= 1'b0;

                        if (o_cntr == CNT_W'(TOTAL)) begin
                            state        <= IDLE;
                            o_frame_done <= 1'b1;   // perf-monitor pulse
                        end
                        else begin
                            // channel = o_cntr / (IMG_W*IMG_H), pix_idx = o_cntr % (IMG_W*IMG_H)
                            // (decoded combinationally above into rel_ch / rel_px)
                            o_data  <= img_buf[rel_ch][rel_px];
                            o_valid <= 1'b1;
                            o_sop   <= (o_cntr == '0);
                            o_eop   <= (o_cntr == CNT_W'(TOTAL - 1));
                            o_cntr  <= o_cntr + 1'b1;
                        end
                    end

                    default: state <= IDLE;
                endcase
            end
        end
    end

    // =========================================================================
    // Improvement #1 — Write path: store incoming pixels into flat buffer
    // Each channel pixel arrives in parallel on i_data[ch]; we push it into
    // img_buf[ch][wr_ptr] every valid cycle while FILL and IDLE→FILL.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            foreach (img_buf[ch, px]) img_buf[ch][px] <= '0;
        end
        else if (clk_en) begin
            if (i_valid && o_ready && (state == FILL || (state == IDLE && i_sop))) begin
                for (int ch = 0; ch < DIMENSION; ch++) begin
                    img_buf[ch][wr_ptr] <= i_data[ch];
                end
            end
        end
    end

endmodule : flat
