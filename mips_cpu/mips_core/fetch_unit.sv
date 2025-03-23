/*
 * d_cache.sv
 * Author: Pravin P. Prabhu, Zinsser Zhang
 * Last Revision: 04/08/2018
 *
 * This module provides pc to i_cache to fetch the next instruction. Two outputs
 * exist. o_pc_current.pc is registered and represent the current pc, i.e. the
 * address of instruction needed to be fetched during the current cycle.
 * o_pc_next.pc is not registered and represent the next pc.
 *
 * All addresses in mips_core are byte addresses (26-bit), so all pc are also
 * byte addresses. Thus, it increases by 4 every cycle (without hazards).
 *
 * See wiki page "Synchronous Caches" for details.
 */
//`include "mips_core.svh"

module fetch_unit (
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	input Address dec_pc,
	branch_decoded_ifc.hazard dec_branch_decoded,

	// Feedback
	input Address ex_pc,
	branch_result_ifc.in ex_branch_result,

	// Stall
	hazard_control_ifc.in i_hc,

	// Load pc
	load_pc_ifc.in i_load_pc,

	// Output pc
	output Address o_pc_current,
	output Address o_pc_next
);
	logic [ADDR_WIDTH-1:0] btb_result;
	logic btb_valid;
	logic btb_hit;

	assign btb_hit = dec_branch_decoded.prediction && btb_valid && dec_branch_decoded.valid;
	branch_controller BRANCH_CONTROLLER (
		.clk, .rst_n,
		.dec_pc,
		.dec_branch_decoded,
		.ex_pc,
		.ex_branch_result
	);

	btb btb (
		.clk, .rst_n,
		.ex_pc,
		.i_ex(ex_branch_result),
		.i_req_pc(i_load_pc.new_pc),
		.valid(btb_valid),
		.o_req_target(btb_result)
	);

	always_comb
	begin
		if (!i_hc.stall) begin
			//if (dec_branch_decoded.prediction && btb_valid && dec_branch_decoded.valid) begin				
			////if (btb_hit) begin			// taken prediction from branch controller, use btb result
			//	o_pc_next = btb_result;
			//	btb_event (btb_hit);
			//	$display("btb result used: %x", btb_result);
			//	//$display("actual pc: %x", o_pc_next.pc);
			//	//$display("o_pc_current.pc: %x", o_pc_current.pc);
			//end
			//else
			begin
				if (i_load_pc.we)
					o_pc_next = i_load_pc.new_pc;
				else
				begin
					if (dec_branch_decoded.valid && (dec_branch_decoded.prediction == TAKEN)) begin
						//btb_event (1);
						//$display("btb result used: %x", btb_result);
					end
					o_pc_next = (dec_branch_decoded.valid && ((dec_branch_decoded.prediction == TAKEN) || dec_branch_decoded.is_jump))
							  ? dec_branch_decoded.target
							  //? btb_result
							  : o_pc_current + ADDR_WIDTH'(4);
				end
			end
		end
			
		else
			o_pc_next = o_pc_current;
	end

	always_ff @(posedge clk)
	begin
		if(~rst_n)
			o_pc_current <= '0;	// Start point of programs are always 0x0
		else
		begin
			o_pc_current <= o_pc_next;
		end
	end
endmodule

module btb #(
	parameter BTB_SIZE = 16    // btb size
) (
	input clk,
	input rst_n,
	branch_result_ifc.in i_ex,							// execution stage
	input Address ex_pc,									// execution pc
	input logic [ADDR_WIDTH - 1 : 0] i_req_pc,      	// input requested pc
	output logic valid,									// valid pc input
	output logic [ADDR_WIDTH - 1 : 0] o_req_target  	// output requested target
);

	logic [$clog2(BTB_SIZE)-1:0] btb_index;
	typedef struct packed {
		logic [ADDR_WIDTH-1:0] target;          // target
		logic [ADDR_WIDTH-1:0] pc;              // requested pc
		logic valid_bit;                         // valid bit
	} btb_entry;
	btb_entry btb_table [0:BTB_SIZE-1];

	assign btb_index = i_req_pc % BTB_SIZE;
	assign valid = btb_table[btb_index].valid_bit;
	assign o_req_target = ((i_req_pc == btb_table[btb_index].pc) && btb_table[btb_index].valid_bit) ? btb_table[btb_index].target : i_req_pc;

	// Update logic
	always_ff @(posedge clk or negedge rst_n) begin
		// reset logic
		if(!rst_n) begin
			//btb_index <= '0;
			for (int i = 0; i < BTB_SIZE; i++) begin
				btb_table[i].valid_bit = 1'b0;
			end
		// branch resolved
		end else if (!i_ex.valid) begin
			btb_table[btb_index].valid_bit <= 1'b0;
		// update at execution stage
		end else begin
			// if btb mispredicted or btb is missed, update
			if ((btb_table[btb_index].target != i_req_pc)||(!btb_table[btb_index].valid_bit)) begin
				//btb_index <= btb_index+1;
				btb_table[btb_index].valid_bit <= 1'b1;
				btb_table[btb_index].pc <= i_req_pc;
				btb_table[btb_index].target <= ex_pc;
				//o_req_target <= i_req_pc;
			end
		end
	end
	
endmodule
/*
module btb #(
	parameter ASSOCIATIVITY = 4,
	parameter BTB_SIZE = 16    // btb size
) (
	input clk,
	input rst_n,
	branch_result_ifc.in i_ex,							// execution stage
	input Address ex_pc,								// execution pc
	input logic [ADDR_WIDTH - 1 : 0] i_req_pc,      	// input requested pc
	output logic valid,									// valid pc input
	output logic [ADDR_WIDTH - 1 : 0] o_req_target  	// output requested target
);

	logic [$clog2(BTB_SIZE/ASSOCIATIVITY)-1:0] btb_index;
	logic [$clog2(ASSOCIATIVITY):0] replace_way;                              // way being replaced
	logic [$clog2(ASSOCIATIVITY):0] lru_bits [0:BTB_SIZE/ASSOCIATIVITY-1];    // LRU replacement bits

	typedef struct packed {
		logic [ADDR_WIDTH-1:0] target;          // target
		logic [ADDR_WIDTH-1:0] pc;              // requested pc
		logic valid_bit;                        // valid bit
	} btb_entry;

	// BTB table storing targets
	btb_entry btb_table [0:BTB_SIZE/ASSOCIATIVITY-1][0:ASSOCIATIVITY-1];

	assign btb_index = i_req_pc[$clog2(BTB_SIZE/ASSOCIATIVITY)-1:0];
	assign valid = btb_table[btb_index][replace_way].valid_bit;
	assign o_req_target = ((i_req_pc == btb_table[btb_index][replace_way].pc) && btb_table[btb_index][replace_way].valid_bit) ? btb_table[btb_index][replace_way].target : i_req_pc;

	// output target is produced
	/*
	always_comb begin
		for (int i = 0; i < ASSOCIATIVITY; i++) begin
			if (btb_table[btb_index][i].pc==i_req_pc && btb_table[btb_index][i].valid_bit) begin
				o_req_target = btb_table[btb_index][i].target;
				break;
			end
		end
	end
*//*
	// Update logic
	always_ff @(posedge clk or negedge rst_n) begin
		// reset logic
		if(!rst_n) begin
			//btb_index <= '0;
			for (int i = 0; i < BTB_SIZE/ASSOCIATIVITY; i++) begin
				lru_bits[i] = '0;
				for (int j = 0; j < ASSOCIATIVITY; j++) begin
					btb_table[i][j].valid_bit = 1'b0;
				end
			end
		// branch resolved
		end else if (!i_ex.valid) begin
			btb_table[btb_index][replace_way].valid_bit <= 1'b0;
		// update at execution stage
		end else begin
			replace_way = (lru_bits[btb_index] < ASSOCIATIVITY) ? lru_bits[btb_index] : '0;
			lru_bits[btb_index] <= replace_way + 1;
			// if btb mispredicted or btb is missed, update
			if ((btb_table[btb_index][replace_way].target != i_req_pc)||(!btb_table[btb_index][replace_way].valid_bit)) begin
				//btb_index <= btb_index+1;
				btb_table[btb_index][replace_way].valid_bit <= 1'b1;
				btb_table[btb_index][replace_way].pc <= i_req_pc;
				btb_table[btb_index][replace_way].target <= ex_pc;
			end
		end
	end
endmodule*/