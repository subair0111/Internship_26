`timescale 1ns / 1ps
class scoreboard;
   mailbox #(apb_transaction) mon2sb;
   bit [31:0] model_mem [256];
   function new(mailbox #(apb_transaction) mon2sb);
      this.mon2sb = mon2sb;
   endfunction
   task run();
      apb_transaction tr;
      forever
      begin
         mon2sb.get(tr);
         if(tr.write)
         begin
            model_mem[tr.addr] = tr.data;
            $display("WRITE PASS");
         end
         else
         begin
            if(model_mem[tr.addr] == tr.data)
               $display("READ PASS");
            else
               $display("READ FAIL exp=%0h got=%0h",
                        model_mem[tr.addr],
                        tr.data);
         end
      end
   endtask

endclass
