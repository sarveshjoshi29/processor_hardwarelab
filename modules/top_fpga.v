`timescale 1ns / 1ps

module top_fpga #(
	parameter IMEMSIZE = 4096,
	parameter DMEMSIZE = 4096
)(
	input  wire clk,    	// fast board clock (e.g. 100 MHz)
	input  wire reset,  	// reset (active-high)
	input  wire core_sel, // 0=show core0 PC on LEDs, 1=show core1 PC on LEDs
	output wire uart_tx,
	output wire [6:0] seg,  // 7-seg segments (CA..CG), active-low
	output wire dp,         // 7-seg decimal point, active-low
	output wire [7:0] an,   // 7-seg anodes, active-low
 
 
output [15:0] led
);

	// =====================================================================
	// Dual-core CPU (shared instr/data memory inside dual_core_top)
	// =====================================================================
	wire        c0_exception, c1_exception;
	wire [31:0] c0_pc_out, c1_pc_out;
	wire [31:0] c0_inst_word_out, c1_inst_word_out;
	wire        c0_dmem_write_ready, c1_dmem_write_ready;
	wire [31:0] c0_dmem_write_addr,  c1_dmem_write_addr;
	wire [31:0] c0_dmem_write_data,  c1_dmem_write_data;
	wire [3:0]  c0_dmem_write_byte,  c1_dmem_write_byte;

	// Stall the CPU while draining UART so we don't miss events.
	reg dbg_stall_req;
	wire cpu_stall = dbg_stall_req;

	dual_core_top u_dual (
		.clk                (clk),
		.reset              (reset),
		.stall              (cpu_stall),

		.c0_exception       (c0_exception),
		.c0_pc_out          (c0_pc_out),
		.c0_inst_fetch_pc   (),
		.c0_inst_word_out   (c0_inst_word_out),
		.c0_dmem_write_ready(c0_dmem_write_ready),
		.c0_dmem_write_addr (c0_dmem_write_addr),
		.c0_dmem_write_data (c0_dmem_write_data),
		.c0_dmem_write_byte (c0_dmem_write_byte),

		.c1_exception       (c1_exception),
		.c1_pc_out          (c1_pc_out),
		.c1_inst_fetch_pc   (),
		.c1_inst_word_out   (c1_inst_word_out),
		.c1_dmem_write_ready(c1_dmem_write_ready),
		.c1_dmem_write_addr (c1_dmem_write_addr),
		.c1_dmem_write_data (c1_dmem_write_data),
		.c1_dmem_write_byte (c1_dmem_write_byte)
	);

	// Sync the external switch/button to avoid metastability.
	reg core_sel_ff1, core_sel_ff2;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			core_sel_ff1 <= 1'b0;
			core_sel_ff2 <= 1'b0;
		end else begin
			core_sel_ff1 <= core_sel;
			core_sel_ff2 <= core_sel_ff1;
		end
	end

	// =====================================================================
	// Human-visible display (slow latch + 7-seg mux)
	// =====================================================================
	localparam integer CLK_HZ = 100_000_000;
	localparam integer LED_UPDATE_HZ = 4; // how often LEDs/7seg update (Hz)
	localparam integer LED_UPDATE_CYCLES = CLK_HZ / LED_UPDATE_HZ;
	localparam integer SEG_SCAN_HZ = 2000; // digit scan rate (Hz)
	localparam integer SEG_SCAN_CYCLES = CLK_HZ / SEG_SCAN_HZ;

	wire [31:0] pc_sel = core_sel_ff2 ? c1_pc_out : c0_pc_out;

	reg [31:0] disp_pc;
	reg [31:0] led_update_cnt;
	reg [15:0] led_r;
	assign led = led_r;

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			disp_pc        <= 32'b0;
			led_update_cnt <= 32'b0;
			led_r          <= 16'b0;
		end else begin
			if (led_update_cnt == (LED_UPDATE_CYCLES - 1)) begin
				led_update_cnt <= 32'b0;
				disp_pc        <= pc_sel;
				led_r          <= pc_sel[15:0];
			end else begin
				led_update_cnt <= led_update_cnt + 32'd1;
			end
		end
	end

	function automatic [6:0] seg7_hex(input [3:0] nib);
		begin
			// seg[6:0] = {CG, CF, CE, CD, CC, CB, CA}, active-low
			case (nib)
				4'h0: seg7_hex = 7'b1000000;
				4'h1: seg7_hex = 7'b1111001;
				4'h2: seg7_hex = 7'b0100100;
				4'h3: seg7_hex = 7'b0110000;
				4'h4: seg7_hex = 7'b0011001;
				4'h5: seg7_hex = 7'b0010010;
				4'h6: seg7_hex = 7'b0000010;
				4'h7: seg7_hex = 7'b1111000;
				4'h8: seg7_hex = 7'b0000000;
				4'h9: seg7_hex = 7'b0010000;
				4'hA: seg7_hex = 7'b0001000;
				4'hB: seg7_hex = 7'b0000011;
				4'hC: seg7_hex = 7'b1000110;
				4'hD: seg7_hex = 7'b0100001;
				4'hE: seg7_hex = 7'b0000110;
				4'hF: seg7_hex = 7'b0001110;
				default: seg7_hex = 7'b1111111;
			endcase
		end
	endfunction

	reg [2:0] seg_digit;
	reg [31:0] seg_cnt;
	reg [6:0] seg_r;
	reg dp_r;
	reg [7:0] an_r;
	assign seg = seg_r;
	assign dp  = dp_r;
	assign an  = an_r;

	wire [3:0] seg_nib = (seg_digit == 3'd0) ? disp_pc[3:0] :
	                 (seg_digit == 3'd1) ? disp_pc[7:4] :
	                 (seg_digit == 3'd2) ? disp_pc[11:8] :
	                 (seg_digit == 3'd3) ? disp_pc[15:12] :
	                 (seg_digit == 3'd4) ? disp_pc[19:16] :
	                 (seg_digit == 3'd5) ? disp_pc[23:20] :
	                 (seg_digit == 3'd6) ? disp_pc[27:24] :
	                                     disp_pc[31:28];

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			seg_digit <= 3'd0;
			seg_cnt   <= 32'd0;
			seg_r     <= 7'b1111111;
			dp_r      <= 1'b1;
			an_r      <= 8'hFF;
		end else begin
			// Digit scan tick
			if (seg_cnt == (SEG_SCAN_CYCLES - 1)) begin
				seg_cnt   <= 32'd0;
				seg_digit <= seg_digit + 3'd1;
			end else begin
				seg_cnt <= seg_cnt + 32'd1;
			end

			// Drive current digit (combinational choice, registered outputs)
			seg_r <= seg7_hex(seg_nib);
			dp_r  <= 1'b1; // DP off
			an_r  <= ~(8'b00000001 << seg_digit);
		end
	end

	// =====================================================================
	// UART transmitter + message generator
	// Prints on each store commit (either core):
	//   C0 PC=XXXXXXXX W@XXXXXXXX=XXXXXXXX\r\n
	//   C1 PC=XXXXXXXX W@XXXXXXXX=XXXXXXXX\r\n
	// =====================================================================

	// Snapshot registers captured on store events.
	reg [31:0] snap_c0_pc,   snap_c1_pc;
	reg [31:0] snap_c0_addr, snap_c1_addr;
	reg [31:0] snap_c0_data, snap_c1_data;
	reg        pend_c0,      pend_c1;

	// Debug send state.
	reg        dbg_start_delay;
	reg        dbg_sending;
	reg        dbg_line;     // 0=core0, 1=core1
	reg [5:0]  dbg_idx;      // 0..DBG_LAST
	localparam [5:0] DBG_LAST = 6'd48;

	// Decimal conversion (BCD) for store data. Runs while CPU is stalled.
	reg        dec_busy;
	reg        dec_core;     // 0=core0, 1=core1
	reg [5:0]  dec_iter;     // 0..31
	reg [31:0] dec_work;
	reg [39:0] bcd_work;
	reg [39:0] bcd_c0;
	reg [39:0] bcd_c1;
	reg [39:0] bcd_adj;
	integer    dd;

	// UART byte interface.
	wire [7:0] uart_data;
	wire       uart_valid;
	wire       uart_ready;

	assign uart_valid = dbg_sending && uart_ready;
	assign uart_data  = (!dbg_line)
		? dbg_byte(1'b0, dbg_idx, snap_c0_pc, snap_c0_addr, snap_c0_data, bcd_c0)
		: dbg_byte(1'b1, dbg_idx, snap_c1_pc, snap_c1_addr, snap_c1_data, bcd_c1);

	uart_tx #(
		.CLK_HZ(100_000_000),
		.BAUD  (115_200)
	) u_uart_tx (
		.clk   (clk),
		.reset (reset),
		.data  (uart_data),
		.valid (uart_valid),
		.ready (uart_ready),
		.tx    (uart_tx)
	);

	function automatic [7:0] hex_ascii(input [3:0] nib);
		begin
			if (nib < 4'd10) hex_ascii = 8'd48 + nib;      // '0'..'9'
			else             hex_ascii = 8'd55 + nib;      // 'A'..'F'
		end
	endfunction

	function automatic [7:0] dbg_byte(
		input        core_sel,
		input  [5:0] idx,
		input [31:0] pc,
		input [31:0] addr,
		input [31:0] data,
		input [39:0] bcd
	);
		integer sh;
		reg [3:0] nib;
		begin
			// Default
			dbg_byte = 8'h3F; // '?'

			case (idx)
				6'd0:  dbg_byte = 8'd67;                    // 'C'
				6'd1:  dbg_byte = core_sel ? 8'd49 : 8'd48; // '1' or '0'
				6'd2:  dbg_byte = 8'd32;                    // ' '
				6'd3:  dbg_byte = 8'd80;                    // 'P'
				6'd4:  dbg_byte = 8'd67;                    // 'C'
				6'd5:  dbg_byte = 8'd61;                    // '='

				6'd14: dbg_byte = 8'd32;                    // ' '
				6'd15: dbg_byte = 8'd87;                    // 'W'
				6'd16: dbg_byte = 8'd64;                    // '@'

				6'd25: dbg_byte = 8'd61;                    // '='

				6'd34: dbg_byte = 8'd32;                    // ' '
				6'd35: dbg_byte = 8'd68;                    // 'D'
				6'd36: dbg_byte = 8'd61;                    // '='

				6'd47: dbg_byte = 8'd13;                    // '\r'
				6'd48: dbg_byte = 8'd10;                    // '\n'
				default: begin
					// PC hex digits [6..13]
					if ((idx >= 6'd6) && (idx <= 6'd13)) begin
						sh  = (13 - idx) * 4;
						nib = (pc >> sh) & 32'hF;
						dbg_byte = hex_ascii(nib);
					end
					// ADDR hex digits [17..24]
					else if ((idx >= 6'd17) && (idx <= 6'd24)) begin
						sh  = (24 - idx) * 4;
						nib = (addr >> sh) & 32'hF;
						dbg_byte = hex_ascii(nib);
					end
					// DATA hex digits [26..33]
					else if ((idx >= 6'd26) && (idx <= 6'd33)) begin
						sh  = (33 - idx) * 4;
						nib = (data >> sh) & 32'hF;
						dbg_byte = hex_ascii(nib);
					end
					// Decimal digits [37..46] (10 digits, most-significant first)
					else if ((idx >= 6'd37) && (idx <= 6'd46)) begin
						sh  = (46 - idx) * 4;
						nib = (bcd >> sh) & 32'hF;
						dbg_byte = 8'd48 + nib; // '0'..'9'
					end
				end
			endcase
		end
	endfunction

	always @(posedge clk or posedge reset) begin
		if (reset) begin
			snap_c0_pc      <= 32'b0;
			snap_c1_pc      <= 32'b0;
			snap_c0_addr    <= 32'b0;
			snap_c1_addr    <= 32'b0;
			snap_c0_data    <= 32'b0;
			snap_c1_data    <= 32'b0;
			pend_c0         <= 1'b0;
			pend_c1         <= 1'b0;
			bcd_c0          <= 40'b0;
			bcd_c1          <= 40'b0;
			dec_busy        <= 1'b0;
			dec_core        <= 1'b0;
			dec_iter        <= 6'd0;
			dec_work        <= 32'b0;
			bcd_work        <= 40'b0;

			dbg_stall_req   <= 1'b0;
			dbg_start_delay <= 1'b0;
			dbg_sending     <= 1'b0;
			dbg_line        <= 1'b0;
			dbg_idx         <= 6'd0;
		end else begin
			// Update snapshots on store commit(s).
			if (c0_dmem_write_ready) begin
				snap_c0_addr <= c0_dmem_write_addr;
				snap_c0_data <= c0_dmem_write_data;
			end
			if (c1_dmem_write_ready) begin
				snap_c1_addr <= c1_dmem_write_addr;
				snap_c1_data <= c1_dmem_write_data;
			end
			// Always capture PCs at the moment we decide to print.

			// Arm a print when either core commits a store.
			if (!dbg_stall_req && (c0_dmem_write_ready || c1_dmem_write_ready)) begin
				snap_c0_pc      <= c0_pc_out;
				snap_c1_pc      <= c1_pc_out;
				pend_c0         <= c0_dmem_write_ready;
				pend_c1         <= c1_dmem_write_ready;
				dbg_stall_req   <= 1'b1;
				dbg_start_delay <= 1'b1; // let core-level stall_read take effect
				dec_busy        <= 1'b0;
			end
			// If we are in the 1-cycle delay before sending, allow updating
			// snapshots for a back-to-back store.
			else if (dbg_stall_req && dbg_start_delay) begin
				if (c0_dmem_write_ready) begin
					snap_c0_pc <= c0_pc_out;
					pend_c0    <= 1'b1;
				end
				if (c1_dmem_write_ready) begin
					snap_c1_pc <= c1_pc_out;
					pend_c1    <= 1'b1;
				end
			end

			// After one stall cycle, convert store data to BCD (decimal).
			if (dbg_stall_req && dbg_start_delay) begin
				dbg_start_delay <= 1'b0;
				dec_busy        <= 1'b1;
				dec_iter        <= 6'd0;
				bcd_work        <= 40'b0;
				if (pend_c0) begin
					dec_core <= 1'b0;
					dec_work <= snap_c0_data;
				end else begin
					dec_core <= 1'b1;
					dec_work <= snap_c1_data;
				end
			end

			// One double-dabble iteration per cycle while stalled.
			if (dec_busy) begin
				bcd_adj = bcd_work;
				for (dd = 0; dd < 10; dd = dd + 1) begin
					if (bcd_adj[dd*4 +: 4] >= 4'd5)
						bcd_adj[dd*4 +: 4] = bcd_adj[dd*4 +: 4] + 4'd3;
				end

				bcd_work <= {bcd_adj[38:0], dec_work[31]};
				dec_work <= {dec_work[30:0], 1'b0};

				if (dec_iter == 6'd31) begin
					// Final BCD value for this core
					if (!dec_core)
						bcd_c0 <= {bcd_adj[38:0], dec_work[31]};
					else
						bcd_c1 <= {bcd_adj[38:0], dec_work[31]};

					// Convert the other core if pending, otherwise start UART.
					if (!dec_core && pend_c1) begin
						dec_core <= 1'b1;
						dec_work <= snap_c1_data;
						dec_iter <= 6'd0;
						bcd_work <= 40'b0;
					end else if (dec_core && pend_c0) begin
						dec_core <= 1'b0;
						dec_work <= snap_c0_data;
						dec_iter <= 6'd0;
						bcd_work <= 40'b0;
					end else begin
						dec_busy    <= 1'b0;
						dec_iter    <= 6'd0;
						dbg_sending <= 1'b1;
						dbg_line    <= pend_c0 ? 1'b0 : 1'b1;
						dbg_idx     <= 6'd0;
					end
				end else begin
					dec_iter <= dec_iter + 6'd1;
				end
			end

			// Drain UART bytes.
			if (dbg_sending && uart_ready) begin
				if (dbg_idx == DBG_LAST) begin
					// Finished one line; clear its pending flag and either send the
					// other core (if pending) or release the stall.
					if (!dbg_line) begin
						pend_c0 <= 1'b0;
						if (pend_c1) begin
							dbg_line <= 1'b1;
							dbg_idx  <= 6'd0;
						end else begin
							dbg_sending   <= 1'b0;
							dbg_stall_req <= 1'b0;
							dbg_idx       <= 6'd0;
							dbg_line      <= 1'b0;
						end
					end else begin
						pend_c1 <= 1'b0;
						if (pend_c0) begin
							dbg_line <= 1'b0;
							dbg_idx  <= 6'd0;
						end else begin
							dbg_sending   <= 1'b0;
							dbg_stall_req <= 1'b0;
							dbg_idx       <= 6'd0;
							dbg_line      <= 1'b0;
						end
					end
				end else begin
					dbg_idx <= dbg_idx + 6'd1;
				end
			end
		end
	end

endmodule
