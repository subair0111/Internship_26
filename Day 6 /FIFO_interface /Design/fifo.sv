module tb;
task add (
input bit [3:0] a,
input bit [3:0] b,
output bit [4:0] y
);
y = a + b;
endtask
bit [3:0] a, b;
bit [4:0] y;
bit clk = 0;
always #5 clk = ~clk;
task stim_clk();
@(posedge clk);
a = $urandom();
b = $urandom();
add(a, b, y);
$display("Time=%0t a=%0d b=%0d y=%0d", $time, a, b, y);
endtask
initial begin
stim_clk();
repeat (10) @(posedge clk);
$finish();
end
endmodule
