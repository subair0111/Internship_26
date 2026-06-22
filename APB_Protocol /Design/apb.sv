`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.06.2026 10:29:11
// Design Name: 
// Module Name: fa
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module apb_slave(apb_if apb);

logic [31:0] mem [0:255];
integer i;

// Write logic
always_ff @(posedge apb.PCLK or negedge apb.PRESETn)
begin
    if(!apb.PRESETn)
    begin
        apb.PREADY  <= 0;
        apb.PSLVERR <= 0;

        for(i=0;i<256;i++)
            mem[i] <= 0;
    end
    else
    begin
        apb.PREADY  <= 1;
        apb.PSLVERR <= 0;

        if(apb.PSEL && apb.PENABLE && apb.PWRITE)
            mem[apb.PADDR] <= apb.PWDATA;
    end
end

// Read logic
always_comb
begin
    if(apb.PSEL && !apb.PWRITE)
        apb.PRDATA = mem[apb.PADDR];
    else
        apb.PRDATA = 32'h0;
end

endmodule
