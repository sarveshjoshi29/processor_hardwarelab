module top_module (
    input  wire        clock,    // 100 MHz oscillator
    input  wire        reset,    // Active HIGH button
    output wire [15:0] led       // Active LOW LEDs
);


    wire clk_en_1hz;
    reg [7:0] addr = 0;

    clock_divider #(
        .DIVISOR(100_000_000)
    ) clk_div_u (
        .clk    (clock),
        .reset  (reset),
        .clk_en (clk_en_1hz)
    );


    always @(posedge clock) begin
        if (reset) begin
            addr <= 0;
        end else if (clk_en_1hz) begin
            if (addr >= 18) 
                addr <= TODO;
            else
                addr <= TODO;
        end
    end

    //////////////////////////////////////////////////
    // 2. Stimulus Memory & Decoding
    //////////////////////////////////////////////////
    (* rom_style = "block" *)
    reg [208:0] stimulus_mem [0:18];
    wire [208:0] stim;

    initial begin
        $readmemb("ex_out_b.mem", stimulus_mem);
    end

    assign stim = stimulus_mem[addr];

    wire [31:0] f_pc        = stim[208:177];
    wire [31:0] f_alu1      = stim[176:145]; 
    wire [31:0] f_alu2      = stim[144:113];
    wire [31:0] f_waddr     = stim[112:81];
    wire        f_bstall    = stim[80];
    wire [31:0] f_nextpc    = stim[79:48];   
    wire        f_btaken    = stim[47];      
    wire [31:0] f_wb_res    = stim[46:15];
    wire        f_mwr       = stim[14];
    wire        f_alu2reg   = stim[13];      
    wire [4:0]  f_dest      = stim[12:8];   
    wire        f_wb_br     = stim[7];
    wire        f_wb_br_nxt = stim[6];       
    wire        f_m2reg     = stim[5];
    wire [1:0]  f_raddr     = stim[4:3];
    wire [2:0]  f_alu_op    = stim[2:0];

    //////////////////////////////////////////////////
    // 3. WB Module Instantiation
    //////////////////////////////////////////////////
   
    wire [31:0] wb_write_address_o;
    wire [31:0] wb_write_data_o;
    wire [3:0]  wb_write_byte_o;
    wire [31:0] wb_read_data_o;
    wire [31:0] inst_fetch_pc_o;

    wb #(
        .RESET(32'h0000_0000)
    ) uut (
        .clk                (clock),          
        .reset              (~reset),         
        .stall_read_i       (1'b0),           
        .fetch_pc_i         (f_pc),
        .wb_branch_i        (f_wb_br),
        .wb_mem_to_reg_i    (f_m2reg),
        .mem_write_i        (f_mwr),
        .write_address_i    (f_waddr),
        .alu_operand2_i     (f_alu2),
        .alu_operation_i    (f_alu_op),
        .wb_alu_operation_i (f_alu_op),       
        .wb_read_address_i  (f_raddr),
        .dmem_read_data_i   (f_wb_res),       
        .dmem_write_valid_i (1'b1),        
        // Outputs
        .wb_write_address_o (wb_write_address_o),
        .wb_write_data_o    (wb_write_data_o),
        .wb_write_byte_o    (wb_write_byte_o),
        .wb_read_data_o     (wb_read_data_o),
        .inst_fetch_pc_o    (inst_fetch_pc_o)
    );

 
    assign led = f_pc[15:0];

endmodule

//////////////////////////////////////////////////
// Clock Divider (Unchanged)
//////////////////////////////////////////////////
module clock_divider #(
    parameter DIVISOR = 100_000_000
)(
    input  wire clk,
    input  wire reset,
    output reg  clk_en
);
    reg [26:0] counter;
    always @(posedge clk) begin
        if (reset) begin
            counter <= 0;
            clk_en  <= 1'b0;
        end
        else if (counter == DIVISOR-1) begin
            counter <= 0;
            clk_en  <= 1'b1;
        end
        else begin
            counter <= counter + 1;
            clk_en  <= 1'b0;
        end
    end
endmodule
