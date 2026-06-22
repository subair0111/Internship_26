class fifo_transaction;
  rand bit       wr_en;
  rand bit       rd_en;
  rand bit [7:0] data_in;  
  bit [7:0]      data_out;
  bit            full;
  bit            empty; 
  constraint rw_dist_c {
    wr_en dist {1 := 5, 0 := 5}; 
    rd_en dist {1 := 4, 0 := 6}; 
  }  
  function void display(string s);
    $display("[%s] wr_en=%0b rd_en=%0b data_in=0x%0h | data_out=0x%0h full=%0b empty=%0b", 
             s, wr_en, rd_en, data_in, data_out, full, empty);
  endfunction
endclass
module tb_fifo;
  reg clk;
  reg rst;
  reg wr_en;
  reg rd_en;
  reg [7:0] data_in;
  wire [7:0] data_out;
  wire full;
  wire empty;  
  fifo dut (
    .clk(clk), .rst(rst), .wr_en(wr_en), .rd_en(rd_en),
    .data_in(data_in), .data_out(data_out), .full(full), .empty(empty)
  ); 
  always #5 clk = ~clk; 
  fifo_transaction trans;  
  initial begin
    $dumpfile("dump.vcd"); 
    $dumpvars(0, tb_fifo);
    clk = 0;
    rst = 1;
    wr_en = 0;
    rd_en = 0;
    data_in = 0;    
    trans = new(); 
    #15 rst = 0;     
    repeat(10) begin
      @(posedge clk);      
      if(!trans.randomize()) begin
        $error("Randomization failed!");
      end      
      wr_en   = trans.wr_en;
      rd_en   = trans.rd_en;
      data_in = trans.data_in;      
      #1;  
      trans.data_out = data_out;
      trans.full     = full;
      trans.empty    = empty;
    end
    #20;
    $finish;
  end
endmodule
