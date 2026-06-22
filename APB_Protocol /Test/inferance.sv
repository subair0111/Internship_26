`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 17.06.2026 14:30:08
// Design Name: 
// Module Name: interface
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


interface apb_if(input bit PCLK);
  logic PRESETn;
  logic PSEL;
  logic PENABLE;
  logic PWRITE;
  logic [7:0]  PADDR;
  logic [31:0] PWDATA;
  logic [31:0] PRDATA;
  logic PREADY;
  logic PSLVERR;
endinterface
