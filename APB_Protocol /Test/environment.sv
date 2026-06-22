`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.06.2026 10:42:39
// Design Name: 
// Module Name: environment
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

class environment;
  generator  gen;
  driver     drv;
  monitor    mon;
  scoreboard sb;
  mailbox #(apb_transaction) gen2drv;
  mailbox #(apb_transaction) mon2sb;
  virtual apb_if vif;
  function new(virtual apb_if vif);
    this.vif = vif;
    gen2drv = new();
    mon2sb  = new();
    gen = new(gen2drv);
    drv = new(gen2drv, vif);
    mon = new(mon2sb, vif);
    sb  = new(mon2sb);
  endfunction
  task pre_test();
    vif.PSEL    <= 0;
    vif.PENABLE <= 0;
    vif.PWRITE  <= 0;
    vif.PADDR   <= 0;
    vif.PWDATA  <= 0;
  endtask
  task test();
    fork
      gen.run();
      drv.run();
      mon.run();
      sb.run();
    join_none
  endtask
  task post_test();
    #1000;
    $display("APB Verification Completed");
  endtask
  task run();
    pre_test();
    test();
    post_test();
  endtask
endclass
