`timescale 1ns/1ps
module instr_mem (
	input  wire    	clk,
	input  wire [31:0] pc, 	// byte address
	output reg  [31:0] instr,
	input wire reset
);

	(* ram_style = "block" *)
	reg [31:0] imem [0:1023];

	initial begin
    	$readmemh("imem.hex", imem);
	end

	always @(posedge clk or posedge reset) begin
	if(reset)
	   instr <= 32'b0;
	else 
	   instr <= imem[pc[11:2]];	// word address
	end

endmodule

//====================================
// Data Memory (DMEM) - FPGA-safe
//====================================
module data_mem (
	input     	clk,

	// Read port
	input     	re,
	input  [31:0] raddr,   // byte address
	output reg [31:0] rdata,

	// Write port
	input     	we,
	input  [31:0] waddr,   // byte address
	input  [31:0] wdata,
	input  [3:0]  wstrb
);

   (* ram_style = "block" *)
	reg [31:0] dmem [0:1023];

	wire [9:0] rindex = raddr[11:2];
	wire [9:0] windex = waddr[11:2];

    initial begin
    	$readmemh("dmem.hex", dmem);
	end

	always @(posedge clk) begin
    	// ---- WRITE ----
    	if (we) begin
        	if (wstrb[0]) dmem[windex][7:0]   <= wdata[7:0];
			if (wstrb[1]) dmem[windex][15:8]  <= wdata[15:8];
        	if (wstrb[2]) dmem[windex][23:16] <= wdata[23:16];
        	if (wstrb[3]) dmem[windex][31:24] <= wdata[31:24];
    	end

    	// ---- READ (1-cycle latency, RAW-safe) ----
    	if (re) begin
        	if (we && (rindex == windex)) begin
            	rdata[7:0]   <= wstrb[0] ? wdata[7:0]   : dmem[rindex][7:0];
            	rdata[15:8]  <= wstrb[1] ? wdata[15:8]  : dmem[rindex][15:8];
            	rdata[23:16] <= wstrb[2] ? wdata[23:16] : dmem[rindex][23:16];
            	rdata[31:24] <= wstrb[3] ? wdata[31:24] : dmem[rindex][31:24];
        	end
        	else begin
            	rdata <= dmem[rindex];
			end
    	end
	end
endmodule