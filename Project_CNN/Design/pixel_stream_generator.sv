module pixel_stream_generator import cnn_config_pkg::*; #(
    parameter PIX_WIDTH  = cnn_config_pkg::PIX_WIDTH ,
    parameter IMG_WIDTH  = cnn_config_pkg::IMG_WIDTH ,
    parameter IMG_HEIGHT = cnn_config_pkg::IMG_HEIGHT
) (
    input  logic                  clk     ,
    input  logic                  rst_n   ,
    input  logic                  start   ,
    
    output logic [9:0]            rd_addr ,
    input  logic [PIX_WIDTH-1:0]  pixel_in,

    output logic [PIX_WIDTH-1:0]  o_data  ,
    output logic                  o_valid ,
    output logic                  o_sop   ,
    output logic                  o_eop   ,
    output logic                  done
);

    localparam int TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;

    logic [9:0] pixel_cnt;
    
    
    logic       streaming;          // NEW: latched run flag

    

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_cnt <= '0;
            rd_addr   <= '0;
            o_valid   <= 1'b0;
            o_sop     <= 1'b0;
            o_eop     <= 1'b0;
            done      <= 1'b0;
            streaming <= 1'b0;
        end
        else begin
            if (start) begin
                pixel_cnt <= '0;
                rd_addr   <= '0;
                done      <= 1'b0;
                streaming <= 1'b1;     // arm and keep running
            end

            if (streaming && !done) begin
                o_data  <= pixel_in;
                o_valid <= 1'b1;
                o_sop   <= (pixel_cnt == 0);
                o_eop   <= (pixel_cnt == TOTAL_PIXELS-1);
                rd_addr <= pixel_cnt+1'b1;

                if (pixel_cnt == TOTAL_PIXELS-1) begin
                    done      <= 1'b1;
                    streaming <= 1'b0;
                end
                else begin
                    pixel_cnt <= pixel_cnt + 1'b1;
                end
            end
            else begin
                o_valid <= 1'b0;
                o_sop   <= 1'b0;
                o_eop   <= 1'b0;
            end
        end
    end

endmodule : pixel_stream_generator
