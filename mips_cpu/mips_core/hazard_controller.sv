/*
 * hazard_controller.sv
 * Author: Zinsser Zhang
 * Last Revision: 03/13/2022
 *
 * hazard_controller collects feedbacks from each stage and detect whether there
 * are hazards in the pipeline. If so, it generate control signals to stall or
 * flush each stage. It also contains a branch_controller, which talks to
 * a branch predictor to make a prediction when a branch instruction is decoded.
 *
 * It also contains simulation only logic to report hazard conditions to C++
 * code for execution statistics collection.
 *
 * See wiki page "Hazards" for details.
 * See wiki page "Branch and Jump" for details of branch and jump instructions.
 */

`ifdef SIMULATION
import "DPI-C" function void stats_event (input string e);
`endif

/*
	Every possible hazard:

	Fetch stage
		- cache miss
			-> stall fetch
	Commit stage
		- branch result != branch prediction
			-> flush pipeline and load new pc
		- commit queue is full
			-> stall pipeline (fetch, decode, issue)
*/

module hazard_controller (
	input logic clk,
	input logic rst_n,

	// From (Fetch stage)
	input cache_output_t F_i_cache_output,
	
	// From (Decode stage)
	input logic         D_prediction_valid,
	input BranchOutcome D_prediction,
	
	// From (Commit stage)
	branch_result_ifc.in C_branch_result,
	input logic          C_queue_overflow,

	// Hazard control output
	hazard_control_ifc.out fetch_hc,
	hazard_control_ifc.out decode_hc,
	hazard_control_ifc.out rename_hc,
	hazard_control_ifc.out issue_hc,
	hazard_control_ifc.out commit_hc,

	// Load pc output
	load_pc_ifc.out load_pc
);
	/*
	branch_decoded_ifc dec_branch_decoded ();
	branch_result_ifc ex_branch_result    ();
	Address ex_pc;

/*
	branch_controller BRANCH_CONTROLLER (
		.clk, .rst_n,
		
		.dec_pc('0),
		.dec_branch_decoded,

		.ex_pc,
		.ex_branch_result
	);
	*/

	// Potential hazards
	logic ic_miss;			    // I-Cache miss
	logic commit_misprediction; // Branch prediction wrong
	//logic dec_overload;		// Branch predict taken or Jump
	//logic dc_miss;			// D cache miss

	// Determine if we have these hazards
	always_comb
	begin
		ic_miss = !F_i_cache_output.valid;

		commit_misprediction = C_branch_result.valid
			& (C_branch_result.prediction != C_branch_result.outcome);

		//ds_miss = ic_miss & dec_branch_decoded.valid;
		/* dec_overload = dec_branch_decoded.valid
			& (dec_branch_decoded.is_jump
				| (dec_branch_decoded.prediction == TAKEN));*/
		// lw_hazard is determined by forward unit.
		/* dc_miss = ~mem_done; */
	end

	// Control signals
	// wb doesn't need to be stalled or flushed
	// i.e. any data goes to wb is finalized and waiting to be commited

	/*
	 * Now let's go over the solution of all hazards
	 * ic_miss:
	 *     if_stall, if_flush
	 * ds_miss:
	 *     dec_stall, dec_flush (if_stall and if_flush handled by ic_miss)
	 * dec_overload:
	 *     load_pc
	 * ex_overload:
	 *     load_pc, ~if_stall, if_flush
	 * lw_hazard:
	 *     dec_stall, dec_flush
	 * dc_miss:
	 *     mem_stall, mem_flush
	 *
	 * The only conflict here is between ic_miss and ex_overload.
	 * ex_overload should have higher priority than ic_miss. Because i cache
	 * does not register missed request, it's totally fine to directly overload
	 * the pc value.
	 *
	 * In addition to above hazards, each stage should also stall if its
	 * downstream stage stalls (e.g., when mem stalls, if & dec & ex should all
	 * stall). This has the highest priority.
	 */

	always_comb
	begin : to_fetch
		// never want to flush, flushing would erase the program counter
		fetch_hc.flush = 1'b0;
		fetch_hc.stall = 1'b0;

		if (ic_miss)
			fetch_hc.stall = 1'b1;

		if (commit_misprediction)
			fetch_hc.stall = 1'b0;
			
		if (D_prediction_valid && (D_prediction == TAKEN))
			fetch_hc.stall = 1'b0;
			
		if (decode_hc.stall)
			fetch_hc.stall = 1'b1;
	end

	always_comb
	begin : to_decode
		decode_hc.stall = 1'b0;
		decode_hc.flush = 1'b0;
			
		if (rename_hc.stall)
			decode_hc.stall = 1'b1;
			
		if (!decode_hc.stall && D_prediction_valid && (D_prediction == TAKEN))
			decode_hc.flush = 1'b1;

		if (commit_misprediction)
			decode_hc.flush = 1'b1;
	end
	
	always_comb
	begin : to_rename
		rename_hc.stall = 1'b0;
		rename_hc.flush = 1'b0;

		if (commit_misprediction)
			rename_hc.flush = 1'b1;

		if (C_queue_overflow)
			rename_hc.stall = 1'b1;
	end
	
	always_comb
	begin : to_issue
		issue_hc.stall = 1'b0;
		issue_hc.flush = 1'b0;
		
		if (commit_misprediction)
			issue_hc.flush = 1'b1;
	end

	always_comb
	begin : to_commit
		commit_hc.stall = 1'b0;
		commit_hc.flush = 1'b0;
		
		if (commit_misprediction)
			commit_hc.flush = 1'b1;
	end

	always_comb
	begin
		load_pc.we     = commit_misprediction;
		load_pc.new_pc = C_branch_result.recovery_target;
	end


`ifdef SIMULATION
	always_ff @(posedge clk)
	begin
		if (ic_miss)      stats_event("ic_miss");
	//	if (ds_miss)      stats_event("ds_miss");
	//	if (dec_overload) stats_event("dec_overload");
	//	if (ex_overload)  stats_event("ex_overload");
	//	if (lw_hazard)    stats_event("lw_hazard");
	//	if (dc_miss)      stats_event("dc_miss");
	//	if (if_stall)     stats_event("if_stall");
	//	if (if_flush)     stats_event("if_flush");
	//	if (dec_stall)    stats_event("dec_stall");
	//	if (dec_flush)    stats_event("dec_flush");
	//	if (ex_stall)     stats_event("ex_stall");
	//	if (ex_flush)     stats_event("ex_flush");
	//	if (mem_stall)    stats_event("mem_stall");
	//	if (mem_flush)    stats_event("mem_flush");
		if (commit_misprediction) stats_event("br_miss");
	end
`endif


endmodule
