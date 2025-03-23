/*
 * branch_controller.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/08/2018
 *
 * branch_controller is a bridge between branch predictor to hazard controller.
 * Two simple predictors are also provided as examples.
 *
 * See wiki page "Branch and Jump" for details.
 */
`include "mips_core.svh"

module branch_controller (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	pc_ifc.in dec_pc,
	branch_decoded_ifc.hazard dec_branch_decoded,

	// Feedback
	pc_ifc.in ex_pc,
	branch_result_ifc.in ex_branch_result
);
	logic request_prediction;

	// Change the following line to switch predictor
	branch_predictor_always_not_taken PREDICTOR (
		.clk, .rst_n,

		.i_req_valid     (request_prediction),
		.i_req_pc        (dec_pc.pc),
		.i_req_target    (dec_branch_decoded.target),
		.o_req_prediction(dec_branch_decoded.prediction),

		.i_fb_valid      (ex_branch_result.valid),
		.i_fb_pc         (ex_pc.pc),
		.i_fb_prediction (ex_branch_result.prediction),
		.i_fb_outcome    (ex_branch_result.outcome)
	);

	always_comb
	begin
		request_prediction = dec_branch_decoded.valid & ~dec_branch_decoded.is_jump;
		dec_branch_decoded.recovery_target =
			(dec_branch_decoded.prediction == TAKEN)
			? dec_pc.pc + `ADDR_WIDTH'd8
			: dec_branch_decoded.target;
	end

endmodule

module gshare #(
    parameter COUNTER_SIZE = 2,  // Size of saturating counters
    parameter PHT_SIZE = 2**`ADDR_WIDTH   // Number of entries in the Choice PHT
) (
    input logic clk, 
    input logic rst_n,

    // Request
    input logic i_req_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
    output mips_core_pkg::BranchOutcome o_req_prediction,
    
    // Feedback
    input logic i_fb_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
    input mips_core_pkg::BranchOutcome i_fb_prediction,
    input mips_core_pkg::BranchOutcome i_fb_outcome
);
    // Choice Predictor Table (2-bit saturating counters)
    logic [COUNTER_SIZE-1:0] choice_pht [0:PHT_SIZE-1];

    // Global History Register
    logic [`ADDR_WIDTH-1:0] global_history;

    logic [$clog2(PHT_SIZE)-1:0] pht_index;                     // Choice PHT Index

    assign pht_index = i_req_pc[$clog2(PHT_SIZE)-1:0] ^ global_history[$clog2(PHT_SIZE)-1:0];
    assign o_req_prediction = choice_pht[pht_index][COUNTER_SIZE - 1] ? TAKEN : NOT_TAKEN;

    // Feedback Update Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_history <= 0;
            for (int i = 0; i < PHT_SIZE; i++) begin
                choice_pht[i] = 2'b01; // Weakly NOT_TAKEN
            end
        end else if (i_fb_valid) begin
            global_history <= {global_history[`ADDR_WIDTH-2:0], i_fb_outcome};
            //predictor_event (o_req_prediction, i_fb_outcome);
            // Update Choice PHT
            if (i_fb_outcome) begin
                if (choice_pht[pht_index] != 2'b11) begin
                    choice_pht[pht_index] <= choice_pht[pht_index] + 2'b01;
                end
            end else begin
                if (choice_pht[pht_index] != 2'b00) begin
                    choice_pht[pht_index] <= choice_pht[pht_index] - 2'b01;
                end
            end
        end
    end

endmodule

module imp_yags_predictor #(
    parameter COUNTER_SIZE = 2,  // Size of saturating counters
    parameter PHT_SIZE = 2**`ADDR_WIDTH,   // Number of entries in the Choice PHT
    parameter TAG_BITS = 8,       // Tag size for Direction Cache
    parameter ASSOCIATIVITY = 4    // Set associativity level (2-way or 4-way)
)(
    input logic clk, 
    input logic rst_n,
    
    // Request
    input logic i_req_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
    input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
    output mips_core_pkg::BranchOutcome o_req_prediction,
    
    // Feedback
    input logic i_fb_valid,
    input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
    input mips_core_pkg::BranchOutcome i_fb_prediction,
    input mips_core_pkg::BranchOutcome i_fb_outcome
);

    // Choice Predictor Table (2-bit saturating counters)
    logic [COUNTER_SIZE-1:0] choice_pht [0:PHT_SIZE-1];

    // Global History Register
    logic [`ADDR_WIDTH-1:0] global_history;

    // Unified Direction Cache Entry
    typedef struct packed {
        logic [TAG_BITS-1:0] tag;               // Tag (PC lower bits + GBH bits)
        logic [COUNTER_SIZE-1:0] counter;       // 2-bit saturating counter
    } cache_entry_t;
    
    // Set-Associative Direction Cache
    cache_entry_t direction_cache [0:PHT_SIZE/ASSOCIATIVITY-1][0:ASSOCIATIVITY-1];
    logic [$clog2(ASSOCIATIVITY):0] lru_bits [0:PHT_SIZE/ASSOCIATIVITY-1];    // LRU replacement bits
    logic [$clog2(ASSOCIATIVITY)-1:0] replace_way;                              // way being replaced

    // Index and Tag Generation
    logic [$clog2(PHT_SIZE)-1:0] pht_index;                     // Choice PHT Index
    logic [$clog2(PHT_SIZE/ASSOCIATIVITY)-1:0] cache_index;     // Direction Cache Index
    logic [TAG_BITS-1:0] pc_tag;                                // Tag for Direction Cache
    logic cache_hit;
    logic cache_output;
    logic final_output;
    logic test;

    assign pht_index = i_req_pc[$clog2(PHT_SIZE)-1:0];
    assign cache_index = i_req_pc[$clog2(PHT_SIZE/ASSOCIATIVITY)-1:0] ^ global_history[$clog2(PHT_SIZE/ASSOCIATIVITY)-1:0];
    assign pc_tag = i_req_pc[TAG_BITS-1:0];
    assign replace_way = (lru_bits[cache_index] < ASSOCIATIVITY) ? lru_bits[cache_index][$clog2(ASSOCIATIVITY)-1:0] : '0;
    assign o_req_prediction = final_output ? TAKEN : NOT_TAKEN;
    // Prediction Logic
    always_comb begin
        cache_hit = 0;
        cache_output = choice_pht[pht_index][COUNTER_SIZE-1]; // Default to choice predictor
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (direction_cache[cache_index][i].tag == pc_tag) begin
                cache_hit = 1;
                cache_output = direction_cache[cache_index][i].counter[COUNTER_SIZE-1];
                break;
            end
        end
        final_output = cache_hit ? cache_output : choice_pht[pht_index][COUNTER_SIZE-1];
    end

    // Feedback Update Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test <= 0;
            global_history <= 0;
            for (int i = 0; i < PHT_SIZE; i++) choice_pht[i] = 2'b01; // Weakly NOT_TAKEN
            for (int i = 0; i < PHT_SIZE/ASSOCIATIVITY; i++) begin
                for (int j = 0; j < ASSOCIATIVITY; j++) begin
                    direction_cache[i][j].tag = '0;
                    direction_cache[i][j].counter = 2'b01;
                end
            end
        end else if (i_fb_valid) begin
            //predictor_event (final_output, i_fb_outcome);
            global_history <= {global_history[`ADDR_WIDTH-2:0], i_fb_outcome};
            
            // Update Choice PHT
            // Chioce PHT used
            if (!cache_hit) begin
                if (i_fb_outcome) begin
                    if (choice_pht[pht_index] != 2'b11) choice_pht[pht_index] <= choice_pht[pht_index] + 2'b01;
                end else begin
                    if (choice_pht[pht_index] != 2'b00) choice_pht[pht_index] <= choice_pht[pht_index] - 2'b01;
                end
            end
            // Chioce PHT predicted correctly 
            else if (i_fb_outcome == choice_pht[pht_index][COUNTER_SIZE-1]) begin
                if (i_fb_outcome) begin
                    if (choice_pht[pht_index]!=2'b11) choice_pht[pht_index] <= choice_pht[pht_index] + 2'b01;
                end else begin     
                    if (choice_pht[pht_index]!=2'b00) choice_pht[pht_index] <= choice_pht[pht_index] - 2'b01;
                end

            end
            // Direction caches predicted wrongly
            else if (i_fb_outcome != cache_output) begin
                if (i_fb_outcome) begin
                    if (choice_pht[pht_index]!=2'b11) choice_pht[pht_index] <= choice_pht[pht_index] + 2'b01;
                end else begin
                    if (choice_pht[pht_index]!=2'b00) choice_pht[pht_index] <= choice_pht[pht_index] - 2'b01;
                end
            end

            // Update Direction Cache using LRU
            // cache output is used
            if (cache_hit) begin
                //test <= 1;
                lru_bits[cache_index] <= replace_way + 1;
                if (i_fb_outcome) begin
                    if (direction_cache[cache_index][replace_way].counter != 2'b11) begin
                        direction_cache[cache_index][replace_way].tag <= pc_tag;
                        direction_cache[cache_index][replace_way].counter <= direction_cache[cache_index][replace_way].counter + 2'b01;
                    end
                end else begin
                    if (direction_cache[cache_index][replace_way].counter != 2'b00) begin
                        direction_cache[cache_index][replace_way].tag <= pc_tag;
                        direction_cache[cache_index][replace_way].counter <= direction_cache[cache_index][replace_way].counter - 2'b01;
                    end
                end
            // choice pht predicted wrongly
            end else if (i_fb_outcome != choice_pht[pht_index][COUNTER_SIZE-1]) begin
                //test <= i_fb_valid;
                lru_bits[cache_index] <= replace_way + 1;
                if (i_fb_outcome) begin
                    if (direction_cache[cache_index][replace_way].counter != 2'b11) begin
                        direction_cache[cache_index][replace_way].tag <= pc_tag;
                        direction_cache[cache_index][replace_way].counter <= direction_cache[cache_index][replace_way].counter + 2'b01;
                    end
                end else begin
                    if (direction_cache[cache_index][replace_way].counter != 2'b00) begin
                        direction_cache[cache_index][replace_way].tag <= pc_tag;
                        direction_cache[cache_index][replace_way].counter <= direction_cache[cache_index][replace_way].counter - 2'b01;
                    end
                end
            end
        end
    end
endmodule

module yags_predictor #(
    parameter COUNTER_SIZE = 2,  // Size of saturating counters (optimized for low CPI)
    parameter PHT_SIZE = 2**`ADDR_WIDTH,   // Number of entries in the Choice PHT
    parameter TAG_BITS = 8       // Tag size for Direction Cache
)(
    input logic clk,                            // Clock signal
    input logic rst_n,                          // Reset signal (active low)
    
	// Request
	input logic i_req_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
	output mips_core_pkg::BranchOutcome o_req_prediction,
    
	// Feedback
	input logic i_fb_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
	input mips_core_pkg::BranchOutcome i_fb_prediction,
	input mips_core_pkg::BranchOutcome i_fb_outcome
);

    // Choice PHT (2-bit saturating counters)
    logic [COUNTER_SIZE-1:0] choice_pht [0:PHT_SIZE-1];

    // Direction Caches (Tag + Counter)
    typedef struct packed {
        logic [TAG_BITS-1:0] tag;               // Tag (lower bits of PC)
        logic [COUNTER_SIZE-1:0] counter;       // 2-bit saturating counter
    } cache_entry_t;

    cache_entry_t cache [0:`ADDR_WIDTH/2-1];

    // Global History Register (GHR)
    logic [`ADDR_WIDTH-1:0] global_history;

    // Index and Tag Generation
    logic [$clog2(PHT_SIZE)-1:0] pht_index;       // Index for Choice PHT
    logic [$clog2(PHT_SIZE/2)-1:0] cache_index;   // Index for Direction Caches
    logic [TAG_BITS-1:0] pc_tag;                // Tag for Direction Caches
	logic cache_hit;                            // cache hit
	logic cache_output;                         // cache output
	logic final_output;                         // final output in 0 or 1 form

	assign pht_index = i_req_pc[$clog2(PHT_SIZE)-1:0];                // index of pht has the same size as req pc
    assign cache_index = i_req_pc[TAG_BITS+$clog2(PHT_SIZE/2)-1:TAG_BITS] ^ global_history[TAG_BITS+$clog2(PHT_SIZE/2)-1:TAG_BITS];  // cache index is data with length `ADDR_WIDTH/2-1 next to tag bits
	assign pc_tag = i_req_pc[TAG_BITS-1:0];     // tag bits is lsb in i_req_pc

    // Prediction Logic
    always_comb begin
		cache_output = cache[cache_index].counter[COUNTER_SIZE-1];                                // cache output is choosed from T cache output and NT cache output based on choice pht output
		cache_hit = cache[cache_index].tag == pc_tag;                                             // cache hit is choosed from T cache hit and NT cache hit based on choice pht output
		final_output = cache_hit ? cache_output : choice_pht[pht_index][COUNTER_SIZE-1];          // final output is choosed from choice pht output(choice_pht[pht_index][counter_size-1]) and cache output based on cache hit
		o_req_prediction = final_output ? TAKEN : NOT_TAKEN;                                      // o_req_prediction is determined based on final output
	
    end

    // Feedback Update Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all tables and history
            global_history <= '0;
            for (int i = 0; i < PHT_SIZE; i++) choice_pht[i] = 2'b01; // Weakly NOT_TAKEN
            for (int i = 0; i < 2**(`ADDR_WIDTH/2); i++) begin
                cache[i].tag = {TAG_BITS{1'b0}};
                cache[i].counter = 2'b01; // Weakly NOT_TAKEN
            end
        end else if (i_fb_valid) begin
            //predictor_event (final_output, i_fb_outcome);
            // Update Global History
            global_history <= {global_history[`ADDR_WIDTH-2:0], i_fb_outcome};

            // Update Choice PHT
            // Chioce PHT used
            if (!cache_hit) begin
                if (i_fb_outcome) begin
                    if (choice_pht[pht_index] != 2'b11) choice_pht[pht_index] <= choice_pht[pht_index] + 2'b01;
                end else begin
                    if (choice_pht[pht_index] != 2'b00) choice_pht[pht_index] <= choice_pht[pht_index] - 2'b01;
                end
            end
            // Chioce PHT predicted correctly 
            if (i_fb_outcome == choice_pht[pht_index][COUNTER_SIZE-1]) begin
                if (i_fb_outcome) begin
                    if (choice_pht[pht_index]!=2'b11) choice_pht[pht_index] <= choice_pht[pht_index] + 2'b01;
                end else begin     
                    if (choice_pht[pht_index]!=2'b00) choice_pht[pht_index] <= choice_pht[pht_index] - 2'b01;
                end
            end
            // Direction caches predicted wrongly
            if (i_fb_outcome != cache_output) begin
                if (i_fb_outcome) begin
                    if (choice_pht[pht_index]!=2'b11) choice_pht[pht_index] <= choice_pht[pht_index] + 2'b01;
                end else begin
                    if (choice_pht[pht_index]!=2'b00) choice_pht[pht_index] <= choice_pht[pht_index] - 2'b01;
                end
            end

            // Update Direction Caches
            // exceptions
            if (i_fb_outcome != choice_pht[pht_index][COUNTER_SIZE-1]) begin
                cache[cache_index].tag <= pc_tag;
                if (cache[cache_index].counter!=2'b11) cache[cache_index].counter <= cache[cache_index].counter + 2'b01;
            end
            // cache hit
            if ((i_fb_outcome != choice_pht[pht_index][COUNTER_SIZE-1]) || cache_hit) begin
                cache[cache_index].tag <= pc_tag;
                if (i_fb_outcome) begin
                    if (cache[cache_index].counter!=2'b11) cache[cache_index].counter <= cache[cache_index].counter + 2'b01;
                end else begin
                    if (cache[cache_index].counter!=2'b00) cache[cache_index].counter <= cache[cache_index].counter - 2'b01;
                end
            end
        end
    end

endmodule

module branch_predictor_always_not_taken (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	input logic i_req_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
	output mips_core_pkg::BranchOutcome o_req_prediction,

	// Feedback
	input logic i_fb_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
	input mips_core_pkg::BranchOutcome i_fb_prediction,
	input mips_core_pkg::BranchOutcome i_fb_outcome
);

	always_comb
	begin
		o_req_prediction = NOT_TAKEN;
	end

endmodule

module branch_predictor_2bit (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	input logic i_req_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_pc,
	input logic [`ADDR_WIDTH - 1 : 0] i_req_target,
	output mips_core_pkg::BranchOutcome o_req_prediction,

	// Feedback
	input logic i_fb_valid,
	input logic [`ADDR_WIDTH - 1 : 0] i_fb_pc,
	input mips_core_pkg::BranchOutcome i_fb_prediction,
	input mips_core_pkg::BranchOutcome i_fb_outcome
);

	logic [1:0] counter;

	task incr;
		begin
			if (counter != 2'b11)
				counter <= counter + 2'b01;
		end
	endtask

	task decr;
		begin
			if (counter != 2'b00)
				counter <= counter - 2'b01;
		end
	endtask

	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			counter <= 2'b01;	// Weakly not taken
		end
		else
		begin
			if (i_fb_valid)
			begin
				case (i_fb_outcome)
					NOT_TAKEN: decr();
					TAKEN:     incr();
				endcase
			end
		end
	end

	always_comb
	begin
		o_req_prediction = counter[1] ? TAKEN : NOT_TAKEN;
	end

endmodule
