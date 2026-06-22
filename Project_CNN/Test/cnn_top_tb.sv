`timescale 1ns/1ns
// =============================================================================
// CNN_TB.sv  —  Testbench for cnn_top
//
// Rebuilt on top of the cnn_top handshake interface (i_cfg_valid/i_cfg_data/
// i_cfg_layer_sel/o_cfg_ready) instead of the legacy CNN/weights_mem_in_*
// interface, and extended with:
//   - all 4 sample digits from the original CNN_TB (7, 2, 1, 0)
//   - a software-visible STATUS REGISTER built from relu_en/pool_en/fc_en/
//     frame_done/o_valid so the testbench (or any future register-mapped
//     wrapper) can poll CNN activity the same way a CPU/AXI host would
//   - a runtime weight reload task so weights can be re-loaded mid-run
//     (e.g. between frames) and not just once before the first image
// -----------------------------------------------------------------------------

`ifdef USE_TRAINED_WEIGHTS
`include "CNN.svh"
`endif

module CNN_TB ();

    // =========================================================================
    // Parameters (must match cnn_top instantiation below)
    // Pulled from cnn_config_pkg so the testbench can never silently drift
    // out of sync with the DUT's own defaults.
    // =========================================================================
    parameter int PIX_WIDTH          = cnn_config_pkg::PIX_WIDTH         ;
    parameter int WEIGHT_WIDTH       = cnn_config_pkg::WEIGHT_WIDTH      ;
    parameter int WEIGHT_FRACT_WIDTH = cnn_config_pkg::WEIGHT_FRACT_WIDTH;

    parameter int CONV_NUMB  = cnn_config_pkg::CONV_NUMB;
    parameter int CONV_IN_DIM  [0:CONV_NUMB-1] = cnn_config_pkg::CONV_IN_DIM ;
    parameter int CONV_OUT_DIM [0:CONV_NUMB-1] = cnn_config_pkg::CONV_OUT_DIM;
    parameter int KERNEL_DIM   [0:CONV_NUMB-1] = cnn_config_pkg::KERNEL_DIM  ;

    parameter int FLAT_NUMB  = cnn_config_pkg::FLAT_NUMB;
    parameter int FLAT_IN_DIM  [0:FLAT_NUMB-1] = cnn_config_pkg::FLAT_IN_DIM ;
    parameter int FLAT_OUT_DIM [0:FLAT_NUMB-1] = cnn_config_pkg::FLAT_OUT_DIM;

    parameter int IMG_WIDTH    = cnn_config_pkg::IMG_WIDTH ;
    parameter int IMG_HEIGHT   = cnn_config_pkg::IMG_HEIGHT;
    parameter int CLASSES_QNT  = cnn_config_pkg::CLASSES_QNT;

    localparam int R2I_COEF = 2**WEIGHT_FRACT_WIDTH;

    // =========================================================================
    // DUT I/O
    // =========================================================================
    logic                          clk    = 0;
    logic                          clk_en = 1;
    logic                          rst_n  = 0;

    logic [PIX_WIDTH-1:0]          wr_data = '0;
    logic [9:0]                    wr_addr = '0;
    logic                          wr_en   = 0;
    logic                          start   = 0;
    logic                          o_img_done;

    logic                          o_valid;
    logic [CLASSES_QNT-1:0][31:0]  classes;

    logic                          i_cfg_valid     = 0;
    logic [WEIGHT_WIDTH-1:0]       i_cfg_data      = '0;
    logic [3:0]                    i_cfg_layer_sel = '0;
    logic                          o_cfg_ready;

    logic                          relu_en, pool_en, fc_en, frame_done;

    // =========================================================================
    // STATUS REGISTER
    //   bit0 = relu_en        bit1 = pool_en
    //   bit2 = fc_en          bit3 = frame_done (sticky, cleared on read)
    //   bit4 = o_valid        bit5 = cfg busy (loader in progress)
    //   bit6 = weights_loaded (set once initial load completes)
    // =========================================================================
    logic [7:0] status_reg = '0;
    logic       cfg_busy   = 1'b0;
    logic       weights_loaded = 1'b0;
    logic       frame_done_prev = 1'b0;

    always @(posedge clk) begin
        status_reg[0] <= relu_en;
        status_reg[1] <= pool_en;
        status_reg[2] <= fc_en;
        status_reg[4] <= o_valid;
        status_reg[5] <= cfg_busy;
        status_reg[6] <= weights_loaded;

        if (frame_done)
            status_reg[3] <= 1'b1;          // sticky
        // status_reg[3] is cleared explicitly via clear_frame_done_flag()
    end

    task automatic clear_frame_done_flag();
        status_reg[3] <= 1'b0;
    endtask

    task automatic print_status_reg(string tag);
        $display("STATUS_REG[%s] = 8'b%08b  (relu=%0b pool=%0b fc=%0b frame_done=%0b o_valid=%0b cfg_busy=%0b weights_loaded=%0b)",
                  tag, status_reg,
                  status_reg[0], status_reg[1], status_reg[2], status_reg[3],
                  status_reg[4], status_reg[5], status_reg[6]);
    endtask

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    cnn_top #(
        .PIX_WIDTH         (PIX_WIDTH         ),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH      ),
        .WEIGHT_FRACT_WIDTH(WEIGHT_FRACT_WIDTH),
        .CONV_NUMB         (CONV_NUMB         ),
        .CONV_IN_DIM       (CONV_IN_DIM       ),
        .CONV_OUT_DIM      (CONV_OUT_DIM      ),
        .KERNEL_DIM        (KERNEL_DIM        ),
        .FLAT_NUMB         (FLAT_NUMB         ),
        .FLAT_IN_DIM       (FLAT_IN_DIM       ),
        .FLAT_OUT_DIM      (FLAT_OUT_DIM      ),
        .IMG_WIDTH         (IMG_WIDTH         ),
        .IMG_HEIGHT        (IMG_HEIGHT        ),
        .CLASSES_QNT       (CLASSES_QNT       )
    ) inst_cnn_top (
        .clk            (clk            ),
        .clk_en         (clk_en         ),
        .rst_n          (rst_n          ),
        .wr_en          (wr_en          ),
        .wr_addr        (wr_addr        ),
        .wr_data        (wr_data        ),
        .start          (start          ),
        .o_img_done     (o_img_done     ),
        .o_valid        (o_valid        ),
        .classes        (classes        ),
        .i_cfg_valid    (i_cfg_valid    ),
        .i_cfg_data     (i_cfg_data     ),
        .i_cfg_layer_sel(i_cfg_layer_sel),
        .o_cfg_ready    (o_cfg_ready    ),
        .relu_en        (relu_en        ),
        .pool_en        (pool_en        ),
        .fc_en          (fc_en          ),
        .frame_done     (frame_done     )
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial forever #10 clk = !clk;

    // =========================================================================
    // Weight-source helper: returns the next fixed-point weight/bias word
    // =========================================================================
    int rand_seed = 32'hC0FFEE;

    function automatic logic [WEIGHT_WIDTH-1:0] next_word();
        // Deterministic pseudo-random fixed-point value in roughly [-1, 1)
        real r;
        rand_seed = $random(rand_seed);
        r = $itor(rand_seed % 1000) / 1000.0;
        return WEIGHT_WIDTH'($rtoi(r * R2I_COEF));
    endfunction

`ifdef USE_TRAINED_WEIGHTS
    // Flattened trained-weight queues, built once at elaboration time so the
    // handshake loader below can just pop words off regardless of source.
    logic [WEIGHT_WIDTH-1:0] conv_q [CONV_NUMB-1:0][$];
    logic [WEIGHT_WIDTH-1:0] fc_q   [FLAT_NUMB-1:0][$];

    initial begin
        foreach (kernel_1_re[dim2, dim1, row, col])
            conv_q[0].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*kernel_1_re[dim2][dim1][row][col])));
        foreach (conv_1_bias_re[x])
            conv_q[0].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*conv_1_bias_re[x])));

        foreach (kernel_2_re[dim2, dim1, row, col])
            conv_q[1].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*kernel_2_re[dim2][dim1][row][col])));
        foreach (conv_2_bias_re[x])
            conv_q[1].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*conv_2_bias_re[x])));

        foreach (fc1_weights_re[x,y])
            fc_q[0].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*fc1_weights_re[x][y])));
        foreach (fc1_bias_re[x])
            fc_q[0].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*fc1_bias_re[x])));

        foreach (fc2_weights_re[x,y])
            fc_q[1].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*fc2_weights_re[x][y])));
        foreach (fc2_bias_re[x])
            fc_q[1].push_back(WEIGHT_WIDTH'($rtoi(R2I_COEF*fc2_bias_re[x])));
    end
`endif

    // =========================================================================
    // Generic handshaken layer loader
    //   layer_sel : 0..CONV_NUMB-1            -> conv stage  [layer_sel]
    //               CONV_NUMB..CONV_NUMB+FLAT_NUMB-1 -> fc layer [layer_sel-CONV_NUMB]
    //   n_words   : total words for that layer (weights + bias)
    // =========================================================================
    task automatic load_layer(input int layer_sel, input int n_words);
        i_cfg_layer_sel = layer_sel[3:0];
        for (int w = 0; w < n_words; w++) begin
`ifdef USE_TRAINED_WEIGHTS
            if (layer_sel < CONV_NUMB)
                i_cfg_data = conv_q[layer_sel].pop_front();
            else
                i_cfg_data = fc_q[layer_sel-CONV_NUMB].pop_front();
`else
            i_cfg_data  = next_word();
`endif
            i_cfg_valid = 1'b1;
            @(posedge clk);
            while (!o_cfg_ready) @(posedge clk);
        end
        i_cfg_valid = 1'b0;
        @(posedge clk);
    endtask

    task automatic load_all_weights();
        int n;
        cfg_busy = 1'b1;
        $display("---- Loading weights ----");
        for (int c = 0; c < CONV_NUMB; c++) begin
            n = CONV_OUT_DIM[c] * (CONV_IN_DIM[c]*KERNEL_DIM[c]*KERNEL_DIM[c]) + CONV_OUT_DIM[c];
            $display("  conv stage %0d : %0d words", c, n);
            load_layer(c, n);
        end
        for (int f = 0; f < FLAT_NUMB; f++) begin
            n = FLAT_OUT_DIM[f] * (FLAT_IN_DIM[f] + 1);
            $display("  fc layer %0d   : %0d words", f, n);
            load_layer(CONV_NUMB + f, n);
        end
        $display("---- Weight loading complete ----");
        cfg_busy       = 1'b0;
        weights_loaded = 1'b1;
    endtask

    // Runtime reload: re-issues the handshake load mid-simulation (e.g.
    // between frames) instead of only once before the first image.
    task automatic reload_weights_runtime();
        $display("\n>>> Runtime weight RELOAD requested (t=%0t) <<<", $time);
        // Make sure the DUT is fully idle before reloading, otherwise the
        // cfg bus and the in-flight frame's pipeline can collide.
        wait (!inst_cnn_top.o_valid);
        @(posedge clk);
        weights_loaded = 1'b0;
        load_all_weights();
    endtask

    // =========================================================================
    // Image load — write one full frame into image_bram, then kick off the
    // internal pixel_stream_generator. This replaces the old model where
    // the testbench drove conv1's i_data/i_valid/i_sop/i_eop directly every
    // cycle; now it only has to fill the frame buffer (at its own pace) and
    // pulse `start`, just like a real frame-grabber/DMA front end would.
    // =========================================================================
    task automatic load_image(input real img [IMG_HEIGHT][IMG_WIDTH]);
        int idx;
        idx = 0;
        for (int r = 0; r < IMG_HEIGHT; r++) begin
            for (int c = 0; c < IMG_WIDTH; c++) begin
                wr_en   = 1'b1;
                wr_addr = 10'(idx);
                wr_data = PIX_WIDTH'($rtoi((img[r][c]/255.0) * R2I_COEF));

                @(posedge clk);
                idx++;
            end
        end
        wr_en = 1'b0;
    endtask
task automatic stream_image(input real img [IMG_HEIGHT][IMG_WIDTH]);
begin
    load_image(img);
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
end

endtask
task automatic run_image(
    input string name,
    input real img [IMG_HEIGHT][IMG_WIDTH]
);
begin
    $display("\nStarting %s", name);

    stream_image(img);

    @(posedge o_valid);

    $display("%s completed", name);

    repeat(5) @(posedge clk);
end
endtask

    // =========================================================================
    // Sample MNIST-like digit images : 7, 2, 1, 0  (all 4 from legacy CNN_TB)
    // =========================================================================
    real image_7[IMG_HEIGHT][IMG_WIDTH] =
        '{
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,84,185,159,151,60,36,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,222,254,254,254,254,241,198,198,198,198,198,198,198,198,170,52,0,0,0,0,0,0},
            '{0,0,0,0,0,0,67,114,72,114,163,227,254,225,254,254,254,250,229,254,254,140,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,17,66,14,67,67,67,59,21,236,254,106,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,83,253,209,18,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,22,233,255,83,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,129,254,238,44,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,59,249,254,62,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,133,254,187,5,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,9,205,248,58,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,126,254,182,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,75,251,240,57,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,19,221,254,166,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,3,203,254,219,35,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,38,254,254,77,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,31,224,254,115,1,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,133,254,254,52,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,61,242,254,254,52,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,121,254,254,219,40,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,121,254,207,18,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
        };

    real image_2[IMG_HEIGHT][IMG_WIDTH] =
        '{
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,116,125,171,255,255,150,93,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,169,253,253,253,253,253,253,218,30,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,169,253,253,253,213,142,176,253,253,122,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,52,250,253,210,32,12,0,6,206,253,140,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,77,251,210,25,0,0,0,122,248,253,65,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,31,18,0,0,0,0,209,253,253,65,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,117,247,253,198,10,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,76,247,253,231,63,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,128,253,253,144,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,176,246,253,159,12,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,25,234,253,233,35,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,198,253,253,141,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,78,248,253,189,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,19,200,253,253,141,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,134,253,253,173,12,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,248,253,253,25,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,248,253,253,43,20,20,20,20,5,0,5,20,20,37,150,150,150,147,10,0},
            '{0,0,0,0,0,0,0,0,248,253,253,253,253,253,253,253,168,143,166,253,253,253,253,253,253,253,123,0},
            '{0,0,0,0,0,0,0,0,174,253,253,253,253,253,253,253,253,253,253,253,249,247,247,169,117,117,57,0},
            '{0,0,0,0,0,0,0,0,0,118,123,123,123,166,253,253,253,155,123,123,41,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
        };

    real image_1[IMG_HEIGHT][IMG_WIDTH] =
        '{
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,38,254,109,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,87,252,82,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,135,241,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,45,244,150,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,84,254,63,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,202,223,11,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,32,254,216,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,95,254,195,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,140,254,77,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,57,237,205,8,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,124,255,165,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,171,254,81,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,24,232,215,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,120,254,159,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,151,254,142,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,228,254,66,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,61,251,254,66,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,141,254,205,3,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,10,215,254,121,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,5,198,176,10,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
        };

    real image_0[IMG_HEIGHT][IMG_WIDTH] =
        '{
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,11,150,253,202,31,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,37,251,251,253,107,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,21,197,251,251,253,107,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,110,190,251,251,251,253,169,109,62,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,253,251,251,251,251,253,251,251,220,51,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,182,255,253,253,253,253,234,222,253,253,253,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,63,221,253,251,251,251,147,77,62,128,251,251,105,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,32,231,251,253,251,220,137,10,0,0,31,230,251,243,113,5,0,0,0,0,0},
            '{0,0,0,0,0,0,0,37,251,251,253,188,20,0,0,0,0,0,109,251,253,251,35,0,0,0,0,0},
            '{0,0,0,0,0,0,0,37,251,251,201,30,0,0,0,0,0,0,31,200,253,251,35,0,0,0,0,0},
            '{0,0,0,0,0,0,0,37,253,253,0,0,0,0,0,0,0,0,32,202,255,253,164,0,0,0,0,0},
            '{0,0,0,0,0,0,0,140,251,251,0,0,0,0,0,0,0,0,109,251,253,251,35,0,0,0,0,0},
            '{0,0,0,0,0,0,0,217,251,251,0,0,0,0,0,0,21,63,231,251,253,230,30,0,0,0,0,0},
            '{0,0,0,0,0,0,0,217,251,251,0,0,0,0,0,0,144,251,251,251,221,61,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,217,251,251,0,0,0,0,0,182,221,251,251,251,180,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,218,253,253,73,73,228,253,253,255,253,253,253,253,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,113,251,251,253,251,251,251,251,253,251,251,251,147,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,31,230,251,253,251,251,251,251,253,230,189,35,10,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,62,142,253,251,251,251,251,253,107,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,72,174,251,173,71,72,30,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
            '{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
        };

   
    // =========================================================================
    // Main stimulus
    // =========================================================================
integer i=0;
integer max_idx=0;
integer max_val=0;
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
        #100;

        @(posedge clk);
        load_all_weights();
        print_status_reg("after_initial_load");
        run_image("image_7", image_7);
        run_image("image_2", image_2);
        run_image("image_1", image_1);
        run_image("image_0", image_0);

        #1000;
        $finish;
    end
    // =========================================================================
    // Dataflow / status monitors
    // =========================================================================
 
    

    always @(posedge clk) begin
        if (o_valid) begin
            @(posedge clk); // allow classes[] to settle

            $display("\n========== CNN OUTPUT ==========");
        

            max_idx = 0;
            max_val = $signed(classes[0]);
            for (i = 1; i < CLASSES_QNT; i = i + 1) begin
                if ($signed(classes[i]) > max_val) begin
                    max_val = $signed(classes[i]);
                    max_idx = i;
                end
            end

            $display("--------------------------------");
            $display("Predicted Digit = %0d", max_idx);
            $display("Maximum Score   = %0d", max_val);
            $display("================================\n");
        end
    end

endmodule : CNN_TB
