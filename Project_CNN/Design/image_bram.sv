`timescale 1ns / 1ps
// =============================================================================
// -----------------------------------------------------------------------------

module image_bram import cnn_config_pkg::*; #(
    parameter PIX_WIDTH  = cnn_config_pkg::PIX_WIDTH ,
    parameter IMG_WIDTH  = cnn_config_pkg::IMG_WIDTH ,
    parameter IMG_HEIGHT = cnn_config_pkg::IMG_HEIGHT
) (
    input  logic                  clk    ,
    input  logic                  wr_en  ,
    input  logic [9:0]            wr_addr,
    input  logic [PIX_WIDTH-1:0]  wr_data,
    input  logic [9:0]            rd_addr,
    output logic [PIX_WIDTH-1:0]  rd_data
);

    localparam int DEPTH = IMG_WIDTH * IMG_HEIGHT;

    logic [PIX_WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule : image_bram
