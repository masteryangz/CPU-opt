/* mips_core.sv
* Author: Pravin P. Prabhu, Dean Tullsen, and Zinsser Zhang
* Last Revision: 03/13/2022
* Abstract:
*   The core module for the MIPS32 processor. This is a classic 5-stage
* MIPS pipeline architecture which is intended to follow heavily from the model
* presented in Hennessy and Patterson's Computer Organization and Design.
* All addresses used in this scope are byte addresses (26-bit)
*/
import mips_core_pkg::*;

`include "simulation.svh"

module mips_core (
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low
	output done,  // Execution is done

	// AXI interfaces
	input AWREADY,
	output AWVALID,
	output [3:0] AWID,
	output [3:0] AWLEN,
	output [ADDR_WIDTH - 1 : 0] AWADDR,

	input WREADY,
	output WVALID,
	output WLAST,
	output [3:0] WID,
	output [DATA_WIDTH - 1 : 0] WDATA,

	output BREADY,
	input BVALID,
	input [3:0] BID,

	input ARREADY,
	output ARVALID,
	output [3:0] ARID,
	output [3:0] ARLEN,
	output [ADDR_WIDTH - 1 : 0] ARADDR,

	output RREADY,
	input RVALID,
	input RLAST,
	input [3:0] RID,
	input [DATA_WIDTH - 1 : 0] RDATA
);

	// FETCH           <=> F_
	// DECODE          <=> D_
	// RENAME          <=> R_
	// ISSUE & EXECUTE <=> I_ & E_
	// COMMIT          <=> C_

	// --- Fetch Stage -----------------------------------------
	Address                      F_pc_current;
	Address                      F_pc_next;
	cache_output_t               F_i_cache_output;
	branch_decoded_ifc           dec_branch_decoded ();
	// --- Decode Stage ----------------------------------------
	cache_output_t               D_raw_instruction;
	Address                      D_input_pc;
	decoder_output_t             D_decoded_instruction;
	BranchOutcome                D_prediction;
	Address                      D_recovery_target;
	// --- Rename Stage ----------------------------------------
	decoder_output_t             R_decoded_instruction;
	Address                      R_input_pc;
	BranchOutcome                R_prediction;
	Address                      R_recovery_target;
	logic                        R_want_dst_reg;
	PhysReg                      R_next_free_reg;
	PhysReg                      R_old_reg;
	remap_ifc                    R_src1_remap ();
	remap_ifc                    R_src2_remap ();
	instruction_t                R_output_instruction;
	unit_enable_t                R_output_unit_enable;
	// --- Issue & Execute Stage -------------------------------
	instruction_t                I_incoming_instruction;
	unit_enable_t                I_unit_enable;
	logic [PHYS_REG_COUNT-1:0]   register_valid_bits; // Async read from physical registers
	Data                         dispatch_src1_data [EXECUTION_UNIT_COUNT];
	Data                         dispatch_src2_data [EXECUTION_UNIT_COUNT];
	logic                        dispatch_take_from_general_unit;
	logic                        dispatch_take_from_memory_unit;
	scheduler_entry_t            dispatched_instruction   [EXECUTION_UNIT_COUNT];
	logic                        dispatch_want_to_execute [EXECUTION_UNIT_COUNT];
	execution_result_t           dispatch_result          [EXECUTION_UNIT_COUNT];
	execution_result_t           dispatch_outgoing_result;
	CommitIndex                  dispatch_outgoing_commit_index;
	logic                        dispatch_want_commit;
	opt_memory_write_t           memory_write;
	logic                        wrote_store_queue;
	load_forward_ifc             load_forward ();
	// --- Commit Stage ----------------------------------------
	logic                        C_incoming_valid;
	CommitIndex                  C_incoming_index;
	execution_result_t           C_incoming_result;
	write_back_t                 C_write_back;
	MipsReg                      C_dst_mips;
	CommitIndex                  C_next_index;
	logic                        C_queue_overflow;
	opt_PhysReg                  C_free_reg;
	branch_result_ifc            C_branch_result ();
	mtc0_t                       C_mtc0;
	logic                        C_store_operation;
	Address                      o_commit_pc;
	// ---------------------------------------------------------
	d_cache_input_ifc            d_cache_input   ();
	cache_output_t               d_cache_output;
	d_cache_input_ifc            load_request    ();
	cache_output_t               load_response;
	d_cache_input_ifc            store_request   ();
	cache_output_t               store_response;
	// ---------------------------------------------------------

	// +++++++++++++++++++++++++++++++++++++++++++++++++++++++
	hazard_control_ifc fetch_hc    ();
	hazard_control_ifc decode_hc   ();
	hazard_control_ifc rename_hc   ();
	hazard_control_ifc issue_hc    ();
	hazard_control_ifc commit_hc   ();
	// +++++++++++++++++++++++++++++++++++++++++++++++++++++++

	// BRANCH CONTROLLER
	load_pc_ifc load_pc();

	// xxxx Memory
	axi_write_address  axi_write_address  ();
	axi_write_data     axi_write_data     ();
	axi_write_response axi_write_response ();
	axi_read_address   axi_read_address   ();
	axi_read_data      axi_read_data      ();

	axi_write_address  mem_write_address  [1]();
	axi_write_data     mem_write_data     [1]();
	axi_write_response mem_write_response [1]();
`ifdef NON_BLOCKING
	axi_read_address   mem_read_address   [9]();
	axi_read_data      mem_read_data      [9]();
`else
	axi_read_address   mem_read_address   [2]();
	axi_read_data      mem_read_data      [2]();
`endif


	hazard_controller HAZARD_CONTROLLER (
		.clk, .rst_n,

		.F_i_cache_output,
		.C_branch_result,
		.C_queue_overflow,
		.D_prediction,
		.D_prediction_valid(dec_branch_decoded.valid),

		.fetch_hc,
		.decode_hc,
		.rename_hc,
		.issue_hc,
		.commit_hc,
		.load_pc
	);

	// ------------------------------------------------------------------------
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

	//always_comb
	//begin
	//	dec_branch_decoded.valid = D_decoded_instruction.is_branch_jump & ~D_decoded_instruction.is_jump_reg;
	//	//						 & (~D_decoded_instruction.is_jump_reg | (register_valid_bits[jump_remap.phys] & (R_decoded_instruction.rw_addr != D_decoded_instruction.rs_addr)));
	//	dec_branch_decoded.is_jump = D_decoded_instruction.is_jump;
	//	dec_branch_decoded.target = D_decoded_instruction.branch_target;
	//end

	assign dec_branch_decoded.valid = D_decoded_instruction.is_branch_jump & ~D_decoded_instruction.is_jump_reg;
	assign dec_branch_decoded.is_jump = D_decoded_instruction.is_jump;
	assign dec_branch_decoded.target = D_decoded_instruction.branch_target;

	always_comb
	begin
		D_prediction      = NOT_TAKEN;
		D_recovery_target = D_decoded_instruction.branch_target;
		if (dec_branch_decoded.valid)
		begin
			D_prediction      = dec_branch_decoded.is_jump? TAKEN : dec_branch_decoded.prediction;
			D_recovery_target = dec_branch_decoded.recovery_target;
		end
	end

	fetch_unit FETCH_UNIT (
		.clk, .rst_n,

		.i_hc         (fetch_hc),
		.i_load_pc    (load_pc),
		.dec_pc(D_input_pc),
		.dec_branch_decoded,
		.ex_pc(o_commit_pc),
		.ex_branch_result(C_branch_result),
		//.i_branch_decoded (D_branch_decoded),
		//.i_branch_result  (C_branch_result),

		.o_pc_current (F_pc_current),
		.o_pc_next    (F_pc_next)
	);

	i_cache I_CACHE (
		.clk, .rst_n,

		.mem_read_address (mem_read_address[0]),
		.mem_read_data    (mem_read_data[0]),
		.i_pc_current     (F_pc_current),
		.i_pc_next        (F_pc_next),
		.out              (F_i_cache_output)
	);
	
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	
	pipeline_barrier #(
		.WIDTH($bits({F_i_cache_output, F_pc_current}))
	) FETCH_TO_DECODE (
		.clk, .rst_n,

		.i_hc (decode_hc),
		.in   ({F_i_cache_output,  F_pc_current}),
		.out  ({D_raw_instruction, D_input_pc})
	);

	decoder DECODER (
		.i_pc   (D_input_pc),
		.i_inst (D_raw_instruction),
		.out    (D_decoded_instruction)
	);

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

	pipeline_barrier #(
		.WIDTH($bits({D_decoded_instruction, D_input_pc, D_prediction, D_recovery_target}))
	) DECODE_TO_RENAME (
		.clk, .rst_n,

		.i_hc (rename_hc),
		.in   ({D_decoded_instruction, D_input_pc, D_prediction, D_recovery_target}),
		.out  ({R_decoded_instruction, R_input_pc, R_prediction, R_recovery_target})
	);

	register_mapping_table REGISTER_MAP (
		.clk, .rst_n,

		.i_restore          (rename_hc.flush),
		.i_want_new_mapping (R_want_dst_reg),
		.i_new_phys_reg     (R_next_free_reg),
		.i_dst_mips_reg     (R_decoded_instruction.rw_addr),
		.o_old_phys_reg     (R_old_reg),
		.i_commit_valid     (C_write_back.valid),
		.i_commit_mips      (C_dst_mips),
		.i_commit_phys      (C_write_back.index),
		.src1_remap         (R_src1_remap),
		.src2_remap         (R_src2_remap)
	);

	register_free_list FREE_LIST (
		.clk, .rst_n,
		
		.i_restore      (rename_hc.flush),
		.i_want_reg     (R_want_dst_reg),
		.o_free_reg     (R_next_free_reg),
		.i_inserted_reg (C_free_reg)
	);
	
	register_renamer REGISTER_RENAMER (
		.i_stall               (rename_hc.stall),
		.i_decoded_instruction (R_decoded_instruction),
		.i_commit_index        (C_next_index),
		.i_free_reg            (R_next_free_reg),
		.i_pc                  (R_input_pc), // DEBUG
		.i_prediction          (R_prediction),
		.i_recovery_target     (R_recovery_target),
		.src1_remap            (R_src1_remap),
		.src2_remap            (R_src2_remap),
		.o_dst_want_reg        (R_want_dst_reg),
		.o_unit_enable         (R_output_unit_enable),
		.o_instruction         (R_output_instruction)
	);

	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

	// HACK: Forward Unit
	struct packed {
		logic   valid;
		PhysReg index;
		Data    data;
	} next_forward, forward;

	typedef logic [PHYS_REG_COUNT-1 : 0] ValidBits;

	pipeline_barrier #(
		.WIDTH($bits({R_output_instruction, R_output_unit_enable}))
	) RENAME_TO_ISSUE (
		.clk, .rst_n,

		.i_hc (issue_hc),
		.in   ({R_output_instruction,   R_output_unit_enable}),
		.out  ({I_incoming_instruction, I_unit_enable})
	);

	general_instruction_queue GENERAL_QUEUE (
		.clk, .rst_n,

		.i_flush           (issue_hc.flush),
		.i_insert_enable   (I_unit_enable.general),
		.i_instruction     (I_incoming_instruction),
	`ifdef ONE_CYCLE_FORWARD
		.i_register_valid  (register_valid_bits | (ValidBits'(forward.valid) << forward.index)),
	`else
		.i_register_valid  (register_valid_bits),
	`endif
		.i_take            (dispatch_take_from_general_unit),
		.o_want_to_execute (dispatch_want_to_execute[0]),
		.o_next_to_execute (dispatched_instruction[0])
	);

	load_store_instruction_queue LOAD_STORE_QUEUE (
		.clk, .rst_n,

		.i_flush           (issue_hc.flush),
		.i_insert_enable   (I_unit_enable.memory),
		.i_instruction     (I_incoming_instruction),
	`ifdef ONE_CYCLE_FORWARD
		.i_register_valid  (register_valid_bits | (ValidBits'(forward.valid) << forward.index)),
	`else
		.i_register_valid  (register_valid_bits),
	`endif
		.i_take            (dispatch_take_from_memory_unit),
		.o_want_to_execute (dispatch_want_to_execute[1]),
		.o_next_to_execute (dispatched_instruction[1])
	);
	
	physical_registers #(
		.WIDTH(EXECUTION_UNIT_COUNT) // ???
	) PHYSICAL_REGISTERS (
		.clk, .rst_n,

		.i_flush   (issue_hc.flush),

		.i_we      (C_write_back.valid),
		.i_windex  (C_write_back.index),
		.i_wdata   (C_write_back.data),

		.i_set_invalid_en    (R_want_dst_reg),
		.i_set_invalid_index (R_next_free_reg),

		.i_rindex1 ({dispatched_instruction[0].src1, dispatched_instruction[1].src1}),
		.i_rindex2 ({dispatched_instruction[0].src2, dispatched_instruction[1].src2}),

		.o_rdata1  (dispatch_src1_data),
		.o_rdata2  (dispatch_src2_data),
		.o_valid   (register_valid_bits)
	);

	execution_command_t dispatched_general_command;
	memory_command_t    dispatched_memory_command;

	Data intermediate [EXECUTION_UNIT_COUNT * 2]; // HACK

	// General Execution Unit Command
	always_comb
	begin
		intermediate[0] = dispatch_src1_data[0];
		intermediate[1] = dispatch_src2_data[0];

		`ifdef ONE_CYCLE_FORWARD
			if (forward.valid && dispatched_instruction[0].src1 == forward.index) intermediate[0] = forward.data;
			if (forward.valid && dispatched_instruction[0].src2 == forward.index) intermediate[1] = forward.data;
		`endif

		dispatched_general_command.alu_ctl = dispatched_instruction[0].meta.alu_ctl;
		dispatched_general_command.op1 = dispatched_instruction[0].meta.uses_src1? intermediate[0] : '0;
		dispatched_general_command.op2 = dispatched_instruction[0].meta.uses_src2? intermediate[1] : dispatched_instruction[0].meta.immediate;
	end
	
	// Memory Unit Command
	always_comb
	begin
		intermediate[2] = dispatch_src1_data[1];
		intermediate[3] = dispatch_src2_data[1];

		`ifdef ONE_CYCLE_FORWARD
			if (forward.valid && dispatched_instruction[1].src1 == forward.index) intermediate[2] = forward.data;
			if (forward.valid && dispatched_instruction[1].src2 == forward.index) intermediate[3] = forward.data;
		`endif

		dispatched_memory_command.access = dispatched_instruction[1].meta.mem_action;
		dispatched_memory_command.alu_ctl = dispatched_instruction[1].meta.alu_ctl;
		dispatched_memory_command.op1 = dispatched_instruction[1].meta.uses_src1? intermediate[2] : '0;
		dispatched_memory_command.op2 = dispatched_instruction[1].meta.immediate;
		dispatched_memory_command.dst = dispatched_instruction[1].dst;
		dispatched_memory_command.data = intermediate[3]; // Data to be stored
	end

	logic [EXECUTION_UNIT_COUNT-1:0] execution_done;

	integer_execution_unit INTEGER_EXECUTION_UNIT (
		.i_valid   (dispatch_want_to_execute[0]),
		.i_command (dispatched_general_command),
		.o_done    (execution_done[0]),
		.o_result  (dispatch_result[0])
	);

	load_store_execution_unit LOAD_STORE_EXECUTION_UNIT (
		.i_valid        (dispatch_want_to_execute[1]),
		.i_command      (dispatched_memory_command),
		.o_done         (execution_done[1]),
		.o_result       (dispatch_result[1]),
		.o_memory_write (memory_write),
		.i_wrote        (wrote_store_queue),
		.i_response     (load_response),
		.o_request      (load_request),
		.load_forward
	);
	
	always_comb
	begin
		dispatch_want_commit = |execution_done;
		dispatch_take_from_general_unit = '0;
		dispatch_take_from_memory_unit  = '0;
		dispatch_outgoing_result        = '0;
		dispatch_outgoing_commit_index  = '0;
		
		next_forward = '0; 

		// Always prefer memory instructions
		if (execution_done[LOAD_STORE_UNIT])
		begin
			dispatch_take_from_memory_unit = '1;
			dispatch_outgoing_result = dispatch_result[1];
			dispatch_outgoing_commit_index = dispatched_instruction[1].meta.commit_index;
			if (dispatched_instruction[1].meta.uses_dst)
			begin
				next_forward.valid = '1;
				next_forward.index = dispatched_instruction[1].dst;
			end
		end
		else if (execution_done[GENERAL_UNIT])
		begin
			dispatch_take_from_general_unit = '1;
			dispatch_outgoing_result = dispatch_result[0];
			dispatch_outgoing_commit_index = dispatched_instruction[0].meta.commit_index;
			if (dispatched_instruction[0].meta.uses_dst)
			begin
				next_forward.valid = '1;
				next_forward.index = dispatched_instruction[0].dst;
			end
		end

		next_forward.data = dispatch_outgoing_result.data;
	end

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			forward <= '0;
		end
		else
		begin
			if (dispatch_want_commit) forward <= next_forward;
		end
	end
	
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

	pipeline_barrier #(
		.WIDTH($bits({dispatch_want_commit, dispatch_outgoing_result, dispatch_outgoing_commit_index}))
	) EXECUTE_TO_COMMIT (
		.clk, .rst_n,

		.i_hc (commit_hc),
		.in   ({dispatch_want_commit,  dispatch_outgoing_result,  dispatch_outgoing_commit_index}),
		.out  ({C_incoming_valid,      C_incoming_result,         C_incoming_index})
	);
	
	commit_queue COMMIT_QUEUE (
		.clk, .rst_n,

		.i_hc                      (commit_hc),
		.i_incoming_valid          (R_decoded_instruction.valid),
		.i_incoming_instruction    (R_output_instruction),
		.i_incoming_dst_mips       (R_decoded_instruction.rw_addr),
		.i_incoming_old_reg        (R_old_reg),
		.i_execution_valid         (C_incoming_valid),
		.i_execution_commit_index  (C_incoming_index),
		.i_execution_result        (C_incoming_result),
		.o_inserted_index          (C_next_index),
		.o_free_reg                (C_free_reg),
		.o_write_back              (C_write_back),
		.o_dst_mips                (C_dst_mips),
		.o_overflow                (C_queue_overflow),
		.o_branch_result           (C_branch_result),
		.o_mtc0                    (C_mtc0),
		.o_store                   (C_store_operation),
		.o_pc                      (o_commit_pc)
	);

	assign done = C_mtc0.id == 2'd3;

	store_queue STORE_QUEUE (
		.clk, .rst_n,
		.load_forward,
		.i_flush          (commit_hc.flush),
		.i_memory_write   (memory_write),
		.o_able_to_insert (wrote_store_queue),
		.i_want_evict     (C_store_operation),
		.o_request        (store_request),
		.i_response       (store_response)
	);

	memory_unit MEMORY_UNIT (
		.clk, .rst_n,
		.d_cache_input,
		.d_cache_output,
		.load_input   (load_request),
		.load_output  (load_response),
		.store_input  (store_request),
		.store_output (store_response)
	);

	d_cache D_CACHE (
		.clk, .rst_n,
		.in                 (d_cache_input),
		.out                (d_cache_output),
`ifdef NON_BLOCKING
		.mem_write_address  (mem_write_address),
		.mem_write_data     (mem_write_data),
		.mem_write_response (mem_write_response[0]),
		.mem_read_address   (mem_read_address[1:8]),
		.mem_read_data      (mem_read_data[1:8])
`else
		.mem_write_address  (mem_write_address[0]),
		.mem_write_data     (mem_write_data[0]),
		.mem_write_response (mem_write_response[0]),
		.mem_read_address   (mem_read_address[1]),
		.mem_read_data      (mem_read_data[1])
`endif
	);



	// ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
	// ------------------------------------------------------------------------


	// xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
	// xxxx Memory Arbiter
	// xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
`ifdef NON_BLOCKING
	memory_arbiter #(.WRITE_MASTERS(1), .READ_MASTERS(9)) MEMORY_ARBITER (
`else
	memory_arbiter #(.WRITE_MASTERS(1), .READ_MASTERS(2)) MEMORY_ARBITER (
`endif
		.clk, .rst_n,
		.axi_write_address,
		.axi_write_data,
		.axi_write_response,
		.axi_read_address,
		.axi_read_data,

		.mem_write_address,
		.mem_write_data,
		.mem_write_response,
		.mem_read_address,
		.mem_read_data
	);

	assign axi_write_address.AWREADY = AWREADY;
	assign AWVALID = axi_write_address.AWVALID;
	assign AWID    = axi_write_address.AWID;
	assign AWLEN   = axi_write_address.AWLEN;
	assign AWADDR  = axi_write_address.AWADDR;

	assign axi_write_data.WREADY = WREADY;
	assign WVALID = axi_write_data.WVALID;
	assign WLAST  = axi_write_data.WLAST;
	assign WID    = axi_write_data.WID;
	assign WDATA  = axi_write_data.WDATA;

	assign axi_write_response.BVALID = BVALID;
	assign axi_write_response.BID = BID;
	assign BREADY = axi_write_response.BREADY;

	assign axi_read_address.ARREADY = ARREADY;
	assign ARVALID = axi_read_address.ARVALID;
	assign ARID    = axi_read_address.ARID;
	assign ARLEN   = axi_read_address.ARLEN;
	assign ARADDR  = axi_read_address.ARADDR;

	assign RREADY = axi_read_data.RREADY;
	assign axi_read_data.RVALID = RVALID;
	assign axi_read_data.RLAST  = RLAST;
	assign axi_read_data.RID    = RID;
	assign axi_read_data.RDATA  = RDATA;

	// xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
	// xxxx Debug and statistic collect logic (Not synthesizable)
	// xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
`ifdef SIMULATION
	/* verilator lint_off WIDTHEXPAND */
	always_ff @(posedge clk)
	begin
		/*if (debug_level() >= 1 && dec_branch_decoded.valid)
		begin
			$display("%t| {%x} Predict %s: target=%x next_pc=%x recovery=%x load_pc.we=%x stall=%x decode=%x", $time,
				D_input_pc,
				(D_prediction == TAKEN?"TAKEN":"NOT_TAKEN"),
				dec_branch_decoded.target,
				F_pc_next,
				D_recovery_target,
				load_pc.we,
				fetch_hc.stall, 
				decode_hc.stall
			);
		end*/

		if (debug_level() >= 1)
		if(
			(R_decoded_instruction.valid && !rename_hc.stall)
		|	dispatch_want_commit
		|	COMMIT_QUEUE.want_to_commit
		|	GENERAL_QUEUE.printed
		) begin
			$display();
		end
		if (F_i_cache_output.valid)
		begin
			`fetch_event(F_pc_current, F_i_cache_output.data)
		end
		if (D_raw_instruction.valid)
		begin
			//$display("%t| \x1b[91mDECODE   {%x} (%d) op=%s [%s <- %s, %s] => [p%0d <- p%0d, p%0d] %d(%s) branch?=%d %x %x \x1b[0m", $time,
			`decode_event(
				D_input_pc,
				DECODER.instruction,
				D_decoded_instruction.rw_addr,
				D_decoded_instruction.rs_addr,
				D_decoded_instruction.rt_addr,
				D_decoded_instruction.immediate
			)
		end
		if (R_decoded_instruction.valid && !rename_hc.stall)
		begin
			if (debug_level() >= 1)
			$display("%t| \x1b[91mRENAME   {%x} (%d) op=%s [%s <- %s, %s] => [p%0d <- p%0d, p%0d]\x1b[0m", $time,
				R_input_pc,
				C_next_index,
				alu_ctl_to_string(R_output_instruction.meta.alu_ctl),
				mips_reg_to_string(R_decoded_instruction.rw_addr),
				mips_reg_to_string(R_decoded_instruction.rs_addr),
				mips_reg_to_string(R_decoded_instruction.rt_addr),
				R_output_instruction.dst,
				R_output_instruction.src1,
				R_output_instruction.src2,
			);
			
			`rename_event(
				R_input_pc,
				R_output_instruction.meta.commit_index,
				R_old_reg,
				{R_output_instruction.dst,  R_output_instruction.meta.uses_dst},
				{R_output_instruction.src1, R_output_instruction.meta.uses_src1},
				{R_output_instruction.src2, R_output_instruction.meta.uses_src2}
			);
		end

		if (dispatch_want_commit)
		begin
			if (debug_level() >= 1)
			begin
			if (dispatch_take_from_general_unit)
			$display("%t| \x1b[92mISSUE    {%x} (%d) op=%s reg=(%d,%d) (%d, %d) => %d|%0s| (%b)\x1b[0m", $time,
				dispatched_instruction[0].meta.pc,
				dispatch_outgoing_commit_index,
				alu_ctl_to_string(dispatched_general_command.alu_ctl),
				dispatched_instruction[0].src1,
				dispatched_instruction[0].src2,
				signed'(dispatched_general_command.op1),
				signed'(dispatched_general_command.op2),
				signed'(dispatch_outgoing_result.data),
				dispatch_outgoing_result.outcome == TAKEN ? "TAKEN" : "NOT_TAKEN",
				dispatch_want_commit,
			);
			else
			$display("%t| \x1b[92mISSUE    {%x} (%d) op=%s addr=%d => %d\x1b[0m", $time,
				dispatched_instruction[1].meta.pc,
				dispatch_outgoing_commit_index,
				dispatched_memory_command.access == READ? "READ" : "WRITE",
				LOAD_STORE_EXECUTION_UNIT.memory_address,
				dispatched_memory_command.access == READ? dispatch_outgoing_result.data : memory_write.data
			);
			end

			`issue_event(
				dispatch_take_from_general_unit? dispatched_instruction[0].meta.pc : dispatched_instruction[1].meta.pc,
				dispatch_outgoing_commit_index,
				dispatch_outgoing_result.data,
				dispatch_outgoing_result.outcome
			)
		end

		if (COMMIT_QUEUE.want_to_commit)
		begin
			if (debug_level() >= 1)
			$display("%t| \x1b[96mCOMMIT   {%x} (%d) (%s) p%0d <- %d(%d) free=%d(%d)\x1b[0m", $time,
				COMMIT_QUEUE.entries[COMMIT_QUEUE.commit_index].pc,
				COMMIT_QUEUE.commit_index,
				mips_reg_to_string(C_dst_mips),
				C_write_back.index,
				C_write_back.valid,
				signed'(C_write_back.data),
				C_free_reg.valid,
				C_free_reg.index,
			);
			
			`commit_event(
				COMMIT_QUEUE.entries[COMMIT_QUEUE.commit_index].pc,
				COMMIT_QUEUE.commit_index,
				{C_write_back.index, C_write_back.valid},
				{C_free_reg.index,   C_free_reg.valid}
			)
		end

		if (C_branch_result.valid)
		begin
			if (debug_level() >= 2)
			$display("%t| \x1b[93mCOMMIT\x1b[0m [branch] misprediction=%d %x (jump_reg?=%d)", $time,
				HAZARD_CONTROLLER.commit_misprediction,
				C_branch_result.recovery_target,
				COMMIT_QUEUE.entries[COMMIT_QUEUE.commit_index].is_jump_reg,
			);

			//for (int i = 0; i < MIPS_REG_COUNT; ++i)
			//begin
			//	$display(" -- MAPPING [%d] <=> p%0d", i, REGISTER_MAP.map_mips_to_phys[i]);
			//end
		end

		if (D_decoded_instruction.valid && !decode_hc.stall)
		begin
			pc_event(COMMIT_QUEUE.entries[COMMIT_QUEUE.commit_index].pc);
		end
	end
`endif
endmodule