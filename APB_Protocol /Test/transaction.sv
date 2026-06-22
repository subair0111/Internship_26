`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.06.2026 10:29:46
// Design Name: 
// Module Name: transaction
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

class apb_transaction;
   rand bit write;
   rand bit [7:0] addr;
   rand bit [31:0] data;
   function void display(string name);
      $display("[%s] write=%0b addr=%0h data=%0h",
                name,write,addr,data);
   endfunction
endclass
