`timescale 1ns/1ps
// ============================================================================
// Branch Predictor — 16-entry Direct-Mapped BTB + 2-bit Saturating BHT
// ============================================================================
// Indexed by PC[5:2] (4 bits → 16 entries)
// Each entry: {valid, tag[25:0], target[31:0], counter[1:0]}
//   - Tag: PC[31:6]
//   - Counter states: 00=Strong NT, 01=Weak NT, 10=Weak T, 11=Strong T
//   - Predict taken when counter[1] = 1 (i.e., counter >= 2)
// ============================================================================
module branch_predictor (
    input         clk,
    input         reset,

    // Prediction port (combinational lookup, used in IF stage)
    input  [31:0] fetch_pc,
    output        predict_taken,
    output [31:0] predict_target,

    // Update port (from EX stage, on branch/jump resolution)
    input         update_en,         // 1 = update BTB/BHT
    input  [31:0] update_pc,         // PC of resolved branch
    input         actual_taken,      // actual outcome
    input  [31:0] actual_target      // actual target address
);

// ---- BTB + BHT storage ----
// btb_tag / btb_target guarded by btb_valid, so no reset needed on
// those arrays — force distributed RAM to shrink area.
reg        btb_valid   [0:15];
(* ram_style = "distributed" *)
reg [25:0] btb_tag     [0:15];
(* ram_style = "distributed" *)
reg [31:0] btb_target  [0:15];
reg  [1:0] bht_counter [0:15];

// ---- Prediction lookup (combinational) ----
wire [3:0]  pred_idx = fetch_pc[5:2];
wire [25:0] pred_tag = fetch_pc[31:6];

wire btb_hit = btb_valid[pred_idx] && (btb_tag[pred_idx] == pred_tag);

assign predict_taken  = btb_hit && bht_counter[pred_idx][1];
assign predict_target = btb_target[pred_idx];

// ---- Update logic (sequential) ----
wire [3:0]  upd_idx = update_pc[5:2];
wire [25:0] upd_tag = update_pc[31:6];

// Only `btb_valid` and `bht_counter` need reset. `btb_tag` and
// `btb_target` are guarded by btb_valid and live in distributed RAM,
// so we omit their reset to keep LUTRAM inference.
integer i;
initial begin
    for (i = 0; i < 16; i = i + 1) begin
        btb_tag[i]    = 26'b0;
        btb_target[i] = 32'b0;
    end
end
always @(posedge clk) begin
    if (update_en) begin
        btb_tag[upd_idx]   <= upd_tag;
        // Only update target when branch is actually taken
        if (actual_taken)
            btb_target[upd_idx] <= actual_target;
    end
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        for (i = 0; i < 16; i = i + 1) begin
            btb_valid[i]   <= 1'b0;
            bht_counter[i] <= 2'b00;
        end
    end
    else if (update_en) begin
        btb_valid[upd_idx] <= 1'b1;

        // 2-bit saturating counter update
        if (actual_taken) begin
            if (bht_counter[upd_idx] != 2'b11)
                bht_counter[upd_idx] <= bht_counter[upd_idx] + 1;
        end else begin
            if (bht_counter[upd_idx] != 2'b00)
                bht_counter[upd_idx] <= bht_counter[upd_idx] - 1;
        end
    end
end

endmodule
