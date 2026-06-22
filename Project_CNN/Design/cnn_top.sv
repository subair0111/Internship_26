`timescale 1ns / 1ps
// =============================================================================
// -----------------------------------------------------------------------------

module cnn_top import cnn_config_pkg::*; #(
    parameter int PIX_WIDTH          = cnn_config_pkg::PIX_WIDTH         ,
    parameter int WEIGHT_WIDTH       = cnn_config_pkg::WEIGHT_WIDTH      ,
    parameter int WEIGHT_FRACT_WIDTH = cnn_config_pkg::WEIGHT_FRACT_WIDTH,

    parameter int CONV_NUMB        = cnn_config_pkg::CONV_NUMB,
    parameter int CONV_IN_DIM  [0:CONV_NUMB-1] = cnn_config_pkg::CONV_IN_DIM ,
    parameter int CONV_OUT_DIM [0:CONV_NUMB-1] = cnn_config_pkg::CONV_OUT_DIM,
    parameter int KERNEL_DIM   [0:CONV_NUMB-1] = cnn_config_pkg::KERNEL_DIM  ,

    parameter int FLAT_NUMB        = cnn_config_pkg::FLAT_NUMB,
    parameter int FLAT_IN_DIM  [0:FLAT_NUMB-1] = cnn_config_pkg::FLAT_IN_DIM ,
    parameter int FLAT_OUT_DIM [0:FLAT_NUMB-1] = cnn_config_pkg::FLAT_OUT_DIM,

    parameter int IMG_WIDTH  = cnn_config_pkg::IMG_WIDTH ,
    parameter int IMG_HEIGHT = cnn_config_pkg::IMG_HEIGHT,
    parameter int CLASSES_QNT = cnn_config_pkg::CLASSES_QNT
) (
    input  logic                          clk    ,
    input  logic                          clk_en ,
    input  logic                          rst_n  ,

    // ── image load interface (replaces direct pixel streaming) ───────────
    // Host writes one full frame into the internal image_bram via
    // wr_en/wr_addr/wr_data (at its own pace, any order within the frame),
    // then pulses `start` once the frame is fully written. The internal
    // pixel_stream_generator then streams it into conv1 at one pixel/cycle
    // — the same way a real frame-grabber / DMA-to-BRAM front end would
    // feed an FPGA CNN core, instead of a testbench driving conv1 directly.
    input  logic                          wr_en  ,
    input  logic [9:0]                    wr_addr,
    input  logic [PIX_WIDTH-1:0]          wr_data,
    input  logic                          start  ,
    output logic                          o_img_done ,

    // ── classification output ────────────────────────────────────────────
    output logic                          o_valid,
    output logic [CLASSES_QNT-1:0][31:0]  classes,

    // ── runtime weight-loader external interface (NEW) ──────────────────
    // layer_sel : 0..CONV_NUMB-1            -> conv stage  [layer_sel]
    //             CONV_NUMB..CONV_NUMB+FLAT_NUMB-1 -> fc layer [layer_sel-CONV_NUMB]
    input  logic                          i_cfg_valid    ,
    input  logic [WEIGHT_WIDTH-1:0]       i_cfg_data     ,
    input  logic [3:0]                    i_cfg_layer_sel,
    output logic                          o_cfg_ready    ,

    // ── status / progress monitor outputs (NEW) ──────────────────────────
    output logic                          relu_en        ,
    output logic                          pool_en        ,
    output logic                          fc_en          ,
    output logic                          frame_done
);

    localparam int NUM_LOADERS = CONV_NUMB + FLAT_NUMB;

    // =========================================================================
    // Image load front-end: BRAM frame buffer + raster pixel streamer
    // (replaces the old testbench-direct-drives-conv1 model)
    // =========================================================================
    logic [9:0]           stream_rd_addr;
    logic [PIX_WIDTH-1:0] stream_rd_data;

    logic [PIX_WIDTH-1:0] stream_data;
    logic                 stream_valid, stream_sop, stream_eop;

    image_bram #(
        .PIX_WIDTH (PIX_WIDTH ),
        .IMG_WIDTH (IMG_WIDTH ),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) inst_image_bram (
        .clk    (clk           ),
        .wr_en  (wr_en         ),
        .wr_addr(wr_addr       ),
        .wr_data(wr_data       ),
        .rd_addr(stream_rd_addr),
        .rd_data(stream_rd_data)
    );

    pixel_stream_generator #(
        .PIX_WIDTH (PIX_WIDTH ),
        .IMG_WIDTH (IMG_WIDTH ),
        .IMG_HEIGHT(IMG_HEIGHT)
    ) inst_pixel_stream_generator (
        .clk     (clk           ),
        .rst_n   (rst_n         ),
        .start   (start         ),
        .rd_addr (stream_rd_addr),
        .pixel_in(stream_rd_data),
        .o_data  (stream_data   ),
        .o_valid (stream_valid  ),
        .o_sop   (stream_sop    ),
        .o_eop   (stream_eop    ),
        .done    (o_img_done    )
    );

    // =========================================================================
    // Inter-stage pixel buses
    // =========================================================================
    logic [7:0][PIX_WIDTH-1:0] conv_data [CONV_NUMB];   // 8 == max OUT_DIMENSION slot
    logic [7:0][PIX_WIDTH-1:0] relu_data [CONV_NUMB];
    logic [7:0][PIX_WIDTH-1:0] pool_data [CONV_NUMB];

    logic conv_valid [CONV_NUMB], conv_sop [CONV_NUMB], conv_eop [CONV_NUMB], conv_ready [CONV_NUMB];
    logic pool_valid [CONV_NUMB], pool_sop [CONV_NUMB], pool_eop [CONV_NUMB], pool_ready[CONV_NUMB];

    // =========================================================================
    // Runtime weight-loader demux : one external cfg bus -> NUM_LOADERS loaders
    // =========================================================================
    logic                    loader_cfg_valid [NUM_LOADERS];
    logic                    loader_cfg_ready [NUM_LOADERS];

    always_comb begin
        for (int n = 0; n < NUM_LOADERS; n++)
            loader_cfg_valid[n] = i_cfg_valid && (i_cfg_layer_sel == n);
        o_cfg_ready = loader_cfg_ready[i_cfg_layer_sel];
    end

    // weight_load_en / weight_addr / weight_data per conv stage, driven by its loader
    logic                        conv_wld_en  [CONV_NUMB];
    logic [15:0]                 conv_wld_addr[CONV_NUMB];
    logic [WEIGHT_WIDTH-1:0]     conv_wld_data[CONV_NUMB];

    // =========================================================================
    // Convolution + ReLU + Max-Pool pipeline (per stage)
    // =========================================================================
    genvar numb;
    generate
        for (numb = 0; numb < CONV_NUMB; numb++) begin : conv_genloop

            // image size feeding this conv stage (post previous pooling)
            localparam int STAGE_W = (numb == 0) ? IMG_WIDTH  : (IMG_WIDTH  - (2**(numb+1)-2)) / (2**numb);
            localparam int STAGE_H = (numb == 0) ? IMG_HEIGHT : (IMG_HEIGHT - (2**(numb+1)-2)) / (2**numb);
            localparam int CONV_OUT_W = STAGE_W - (KERNEL_DIM[numb]-1);
            localparam int CONV_OUT_H = STAGE_H - (KERNEL_DIM[numb]-1);

            logic [CONV_OUT_DIM[numb]-1:0][PIX_WIDTH-1:0]  cb_in_data;
            logic [CONV_OUT_DIM[numb]-1:0][PIX_WIDTH-1:0]  cb_out_data;
            logic [CONV_OUT_DIM[numb]-1:0][PIX_WIDTH-1:0]  cb_relu_data;
            logic [CONV_OUT_DIM[numb]-1:0][PIX_WIDTH-1:0]  cb_pool_data;

            // ---- runtime weight loader for this conv stage --------------------
            runtime_weight_loader #(
                .WEIGHT_WIDTH    (WEIGHT_WIDTH      ),
                .KERNEL_DIMENSION(KERNEL_DIM[numb]  ),
                .IN_DIMENSION    (CONV_IN_DIM[numb] ),
                .OUT_DIMENSION   (CONV_OUT_DIM[numb])
            ) inst_conv_loader (
                .clk           (clk                          ),
                .rst_n         (rst_n                        ),
                .i_cfg_valid   (loader_cfg_valid[numb]        ),
                .i_cfg_data    (i_cfg_data                    ),
                .o_cfg_ready   (loader_cfg_ready[numb]        ),
                .weight_load_en(conv_wld_en  [numb]           ),
                .weight_addr   (conv_wld_addr[numb][$clog2(CONV_OUT_DIM[numb]*(CONV_IN_DIM[numb]*KERNEL_DIM[numb]*KERNEL_DIM[numb])+CONV_OUT_DIM[numb])-1:0]),
                .weight_data   (conv_wld_data[numb]            )
            );

            // ---- convolution block (includes internal kernel_memory) ----------
            conv_block #(
                .PIX_WIDTH         (PIX_WIDTH         ),
                .WEIGHT_WIDTH      (WEIGHT_WIDTH      ),
                .WEIGHT_FRACT_WIDTH(WEIGHT_FRACT_WIDTH),
                .TRUNK             ("TRUE"            ),
                .IMG_WIDTH         (STAGE_W           ),
                .IMG_HEIGHT        (STAGE_H           ),
                .KERNEL_DIMENSION  (KERNEL_DIM[numb]  ),
                .IN_DIMENSION      (CONV_IN_DIM[numb] ),
                .OUT_DIMENSION     (CONV_OUT_DIM[numb])
            ) inst_conv_block (
                .clk           (clk    ),
                .clk_en        (clk_en ),
                .rst_n         (rst_n  ),
                .i_data        ((numb == 0) ? cb_in_data : pool_data[numb-1][CONV_IN_DIM[numb]-1:0]),
                .i_valid       ((numb == 0) ? stream_valid : pool_valid[numb-1]),
                .i_sop         ((numb == 0) ? stream_sop   : pool_sop  [numb-1]),
                .i_eop         ((numb == 0) ? stream_eop   : pool_eop  [numb-1]),
                .o_data        (cb_out_data            ),
                .o_valid       (conv_valid[numb]       ),
                .o_sop         (conv_sop  [numb]       ),
                .o_eop         (conv_eop  [numb]       ),
                .weight_load_en(conv_wld_en  [numb]    ),
                .weight_addr   (conv_wld_addr[numb]    ),
                .weight_data   (conv_wld_data[numb]    ),
                .o_ready       (conv_ready[numb]       )
            );

            // first stage takes the top-level single-channel pixel stream
            if (numb == 0)
                assign cb_in_data[0] = stream_data;

            assign conv_data[numb][CONV_OUT_DIM[numb]-1:0] = cb_out_data;

            // ---- ReLU activation (combinational) -------------------------------
            relu #(
                .PIX_WIDTH(PIX_WIDTH         ),
                .DIMENSION(CONV_OUT_DIM[numb])
            ) inst_relu (
                .i_data(cb_out_data ),
                .o_data(cb_relu_data)
            );

            assign relu_data[numb][CONV_OUT_DIM[numb]-1:0] = cb_relu_data;

            // ---- Max pooling -----------------------------------------------------
            max_pooling_block #(
                .PIX_WIDTH     (PIX_WIDTH         ),
                .IMG_WIDTH     (CONV_OUT_W        ),
                .IMG_HEIGHT    (CONV_OUT_H        ),
                .POOL_DIMENSION(2                 ),
                .DIMENSION     (CONV_OUT_DIM[numb])
            ) inst_max_pooling_block (
                .clk    (clk             ),
                .clk_en (clk_en          ),
                .rst_n  (rst_n           ),
                .i_data (cb_relu_data    ),
                .i_valid(conv_valid[numb]),
                .i_sop  (conv_sop  [numb]),
                .i_eop  (conv_eop  [numb]),
                .o_data (cb_pool_data    ),
                .o_valid(pool_valid[numb]),
                .o_sop  (pool_sop  [numb]),
                .o_eop  (pool_eop  [numb]),
                .o_ready(pool_ready[numb])
            );

            assign pool_data[numb][CONV_OUT_DIM[numb]-1:0] = cb_pool_data;

        end
    endgenerate

    // =========================================================================
    // Flatten layer
    // =========================================================================
    localparam int LAST = CONV_NUMB - 1;
    localparam int POOL_W = ((IMG_WIDTH  - (2**(LAST+1)-2)) / (2**LAST) - (KERNEL_DIM[LAST]-1)) / 2;
    localparam int POOL_H = ((IMG_HEIGHT - (2**(LAST+1)-2)) / (2**LAST) - (KERNEL_DIM[LAST]-1)) / 2;

    logic [PIX_WIDTH-1:0] flat_data;
    logic flat_valid, flat_sop, flat_eop, flat_ready;
    logic flat_frame_start, flat_frame_done, flat_busy;
    logic [2:0] flat_state;
    logic [$clog2(POOL_H)-1:0] flat_row;
    logic [$clog2(POOL_W)-1:0] flat_col;

    flat #(
        .PIX_WIDTH(PIX_WIDTH               ),
        .DIMENSION(CONV_OUT_DIM[CONV_NUMB-1]),
        .IMG_W    (POOL_W                  ),
        .IMG_H    (POOL_H                  )
    ) inst_flat (
        .clk          (clk                        ),
        .clk_en       (clk_en                     ),
        .rst_n        (rst_n                      ),
        .i_data       (pool_data [CONV_NUMB-1][CONV_OUT_DIM[CONV_NUMB-1]-1:0]),
        .i_valid      (pool_valid[CONV_NUMB-1]    ),
        .i_sop        (pool_sop  [CONV_NUMB-1]    ),
        .i_eop        (pool_eop  [CONV_NUMB-1]    ),
        .o_data       (flat_data                  ),
        .o_valid      (flat_valid                 ),
        .o_sop        (flat_sop                   ),
        .o_eop        (flat_eop                   ),
        .o_ready      (flat_ready                 ),
        .i_flush      (1'b0                       ),
        .o_frame_start(flat_frame_start           ),
        .o_frame_done (flat_frame_done            ),
        .o_busy       (flat_busy                  ),
        .o_state      (flat_state                 ),
        .o_row        (flat_row                   ),
        .o_col        (flat_col                   )
    );

    // =========================================================================
    // Fully-connected layers (+ ReLU between, per original CNN.sv topology)
    // =========================================================================
    logic [PIX_WIDTH+$clog2(FLAT_IN_DIM[0])-1:0] fc_data     [FLAT_NUMB];
    logic [PIX_WIDTH+$clog2(FLAT_IN_DIM[0])-1:0] fc_relu_data[FLAT_NUMB];
    logic fc_valid[FLAT_NUMB], fc_sop[FLAT_NUMB], fc_eop[FLAT_NUMB], fc_ready[FLAT_NUMB];

    logic                     fc_wld_en  [FLAT_NUMB];
    logic [WEIGHT_WIDTH-1:0]  fc_wld_data[FLAT_NUMB];

    generate
        for (numb = 0; numb < FLAT_NUMB; numb++) begin : fc_genloop

            localparam int FC_PIX_W = PIX_WIDTH + ((numb == 0) ? 0 : $clog2(FLAT_IN_DIM[0]));
            localparam int FC_TOTAL = FLAT_OUT_DIM[numb] * (FLAT_IN_DIM[numb] + 1);

            logic [$clog2(FC_TOTAL)-1:0]              fc_raw_addr;
            logic [$clog2(FLAT_IN_DIM[numb])-1:0]     fc_in_addr;
            logic [$clog2(FLAT_OUT_DIM[numb]):0]      fc_sel;

            // ---- runtime weight loader for this FC layer -----------------------
            // KERNEL_DIMENSION=1 collapses runtime_weight_loader's address space
            // to OUT*(IN+1) words: OUT blocks of IN weights + 1 trailing bias block.
            runtime_weight_loader #(
                .WEIGHT_WIDTH    (WEIGHT_WIDTH        ),
                .KERNEL_DIMENSION(1                   ),
                .IN_DIMENSION    (FLAT_IN_DIM[numb]   ),
                .OUT_DIMENSION   (FLAT_OUT_DIM[numb]  )
            ) inst_fc_loader (
                .clk           (clk                                ),
                .rst_n         (rst_n                              ),
                .i_cfg_valid   (loader_cfg_valid[CONV_NUMB+numb]    ),
                .i_cfg_data    (i_cfg_data                          ),
                .o_cfg_ready   (loader_cfg_ready[CONV_NUMB+numb]    ),
                .weight_load_en(fc_wld_en[numb]                     ),
                .weight_addr   (fc_raw_addr                         ),
                .weight_data   (fc_wld_data[numb]                   )
            );

            // decode flat loader address -> {sel, in_addr} expected by fully_connected_layer
            // sel == FLAT_OUT_DIM[numb]  -> bias write ; sel < FLAT_OUT_DIM[numb] -> weight write
            always_comb begin
                if (fc_raw_addr < (FLAT_OUT_DIM[numb] * FLAT_IN_DIM[numb])) begin
                    fc_sel     = fc_raw_addr / FLAT_IN_DIM[numb];
                    fc_in_addr = fc_raw_addr % FLAT_IN_DIM[numb];
                end else begin
                    fc_sel     = FLAT_OUT_DIM[numb];
                    fc_in_addr = fc_raw_addr - (FLAT_OUT_DIM[numb] * FLAT_IN_DIM[numb]);
                end
            end

            fully_connected_layer #(
                .PIX_WIDTH         (FC_PIX_W            ),
                .WEIGHT_WIDTH      (WEIGHT_WIDTH        ),
                .WEIGHT_FRACT_WIDTH(WEIGHT_FRACT_WIDTH  ),
                .IN_DIMENSION      (FLAT_IN_DIM[numb]   ),
                .OUT_DIMENSION     (FLAT_OUT_DIM[numb]  )
            ) inst_fully_connected_layer (
                .clk                 (clk                                            ),
                .clk_en              (clk_en                                         ),
                .rst_n               (rst_n                                          ),
                .i_data              ((numb == 0) ? flat_data : fc_relu_data[numb-1] ),
                .i_valid             ((numb == 0) ? flat_valid : fc_valid[numb-1]    ),
                .i_sop               ((numb == 0) ? flat_sop : fc_sop[numb-1]        ),
                .i_eop               ((numb == 0) ? flat_eop : fc_eop[numb-1]        ),
                .o_data              (fc_data[numb]                                  ),
                .o_valid             (fc_valid[numb]                                 ),
                .o_sop               (fc_sop[numb]                                   ),
                .o_eop               (fc_eop[numb]                                   ),
                .o_ready             (fc_ready[numb]                                 ),
                .weight_load_en      (fc_wld_en[numb]                                ),
                .weight_addr         (fc_in_addr                                     ),
                .weight_sel          (fc_sel                                         ),
                .weight_data         (fc_wld_data[numb]                              ),
                .weights_mem_in_data (PIX_WIDTH'(0)                                  ),
                .weights_mem_in_addr ('0                                             ),
                .weights_mem_sel_addr('0                                             ),
                .weights_mem_in_fc_wr(1'b0                                           ),
                .o_frame_start       (                                               ),
                .o_frame_done        (                                               ),
                .o_busy              (                                               ),
                .o_state             (                                               ),
                .o_col_cntr          (                                               ),
                .o_out_cntr          (                                               )
            );

            relu #(
                .PIX_WIDTH(PIX_WIDTH+$clog2(FLAT_IN_DIM[0])),
                .DIMENSION(1                                )
            ) inst_fc_relu (
                .i_data(fc_data[numb]     ),
                .o_data(fc_relu_data[numb])
            );

        end
    endgenerate

    // =========================================================================
    // Classification output collector
    // =========================================================================
    int classes_cntr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            classes      <= '0;
            classes_cntr <= '0;
            o_valid      <= 1'b0;
        end else if (clk_en) begin
            o_valid <= 1'b0;

            if (fc_valid[FLAT_NUMB-1]) begin
                classes[classes_cntr] <= 32'($signed(fc_data[FLAT_NUMB-1]));

                if (fc_eop[FLAT_NUMB-1]) begin
                    classes_cntr <= '0;
                    o_valid      <= 1'b1;
                end else begin
                    classes_cntr <= classes_cntr + 1;
                end
            end
        end
    end

    // =========================================================================
    // Status register — pipeline progress monitor (NEW)
    // The datapath above is free-running / no-backpressure (matching the
    // original CNN.sv design intent), so relu_en/pool_en/fc_en here are
    // informational status flags rather than data-gating enables: they track
    // which logical stage most recently completed a frame, and frame_done
    // pulses once the final FC layer has produced all CLASSES_QNT outputs.
    // =========================================================================
    logic relu0_done_mon, relu1_done_mon;
logic pool0_done_mon, pool1_done_mon;

logic fc0_done_mon;
logic fc1_done_mon;

// each stage's eop drives its own dedicated status_register input —
// no muxing by FSM state, so no race between pulse timing and state timing
assign relu0_done_mon = conv_eop[0];
assign pool0_done_mon = pool_eop[0];
assign relu1_done_mon = conv_eop[CONV_NUMB-1];
assign pool1_done_mon = pool_eop[CONV_NUMB-1];

assign fc0_done_mon = fc_eop[0];
assign fc1_done_mon = fc_eop[1];


    status_register inst_status_register (
        .clk       (clk           ),
        .rst_n     (rst_n         ),
        .relu0_done(relu0_done_mon),
        .pool0_done(pool0_done_mon),
        .relu1_done(relu1_done_mon),
        .pool1_done(pool1_done_mon),
        .fc0_done  (fc0_done_mon  ),
        .fc1_done  (fc1_done_mon  ),
        .relu_en   (relu_en       ),
        .pool_en   (pool_en       ),
        .fc_en     (fc_en         ),
        .frame_done(frame_done    )
    );
    
endmodule : cnn_top
