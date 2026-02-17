module top_mem_fpga (
    input  wire        clock,    
    input  wire        reset,    
    output wire [15:0] led      
);

    // ---------------------------------------------------------
    // 1. Clock Enable Generation (1 Hz)
    // ---------------------------------------------------------
    wire clk_en;
    // ---------------------------------------------------------
    // Memory Instantiations
    // ---------------------------------------------------------
    wire [31:0] instr_out;

	// TODO-TOP-MEM-1: Instantiate IMEM
    assign led = ~instr_out[15:0];

endmodule

//======================================================
// Clock Divider (clock enable generator)
//======================================================
module clock_divider #(
	parameter DIVISOR = 100_000_000
)(
	input  wire clk,
	input  wire reset,
	output reg  clk_en
);

	  reg [26:0] count_reg;

	always @(posedge clk) begin
    	if (reset) begin
        	counter <= // TODO
        	clk_en  <= 1'b0;
    	end else if (counter == DIVISOR - 1) begin
        	counter <= 0;
        	clk_en  <= 1'b1;   // one-cycle pulse
    	end else begin
        	// TODO: Counter?
        	clk_en  <= 1'b0;
    	end
	end

endmodule
