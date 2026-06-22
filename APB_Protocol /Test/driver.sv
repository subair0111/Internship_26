`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.06.2026 10:31:19
// Design Name: 
// Module Name: driver
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


class driver;
   virtual apb_if vif;
   mailbox #(apb_transaction) gen2drv;
   function new(
      mailbox #(apb_transaction) gen2drv,
      virtual apb_if vif);
      this.gen2drv = gen2drv;
      this.vif     = vif;
   endfunction
   task run();
      apb_transaction tr;
      forever
      begin
         gen2drv.get(tr);
         @(posedge vif.PCLK);
         vif.PSEL    <= 1'b1;
         vif.PENABLE <= 1'b0;
         vif.PWRITE  <= tr.write;
         vif.PADDR   <= tr.addr;
         vif.PWDATA  <= tr.data;
         @(posedge vif.PCLK);
         vif.PENABLE <= 1'b1;
         wait(vif.PREADY);
         @(posedge vif.PCLK);
         vif.PSEL    <= 0;
         vif.PENABLE <= 0;
      end
   endtask

endclass
