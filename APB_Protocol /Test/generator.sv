`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.06.2026 10:30:25
// Design Name: 
// Module Name: generator
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


class generator;
   mailbox #(apb_transaction) gen2drv;
   function new(mailbox #(apb_transaction) gen2drv);
      this.gen2drv = gen2drv;
   endfunction
   task run();
      apb_transaction tr;
      bit [7:0]  addr;
      bit [31:0] data;
      repeat(20)
      begin
         addr = $urandom_range(0,255);
         data = $urandom;
         tr = new();
         tr.write = 1'b1;
         tr.addr  = addr;
         tr.data  = data;
         gen2drv.put(tr);
         tr.display("GEN-WR");
         tr = new();
         tr.write = 1'b0;
         tr.addr  = addr;
         gen2drv.put(tr);
         tr.display("GEN-RD");
      end
   endtask
endclass
