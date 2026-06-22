`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.06.2026 10:32:03
// Design Name: 
// Module Name: monitor
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


class monitor;
   virtual apb_if vif;
   mailbox #(apb_transaction) mon2sb;
   function new(
      mailbox #(apb_transaction) mon2sb,
      virtual apb_if vif );
      this.mon2sb = mon2sb;
      this.vif    = vif;
   endfunction
   task run();
      apb_transaction tr;
      forever begin
         @(posedge vif.PCLK);
         if(vif.PSEL && vif.PENABLE && vif.PREADY)
         begin
            tr = new();
            tr.write = vif.PWRITE;
            tr.addr  = vif.PADDR;
            if(vif.PWRITE)
            begin
               tr.data = vif.PWDATA;
               $display("[MON-WRITE] Addr=%0h Data=%0h Time=%0t",
                         vif.PADDR,
                         vif.PWDATA,
                         $time);
            end
            else
            begin
               tr.data = vif.PRDATA;
               $display("[MON-READ ] Addr=%0h Data=%0h Time=%0t",
                         vif.PADDR,
                         vif.PRDATA,
                         $time);
            end
            mon2sb.put(tr);
         end
      end
endclass
