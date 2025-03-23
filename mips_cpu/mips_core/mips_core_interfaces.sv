/*
 * mips_core_interfaces.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/09/2018
 *
 * These are interfaces that are not the input or output of one specific unit.
 *
 * See wiki page "Systemverilog Primer" section interfaces for details.
 */
 //import mips_core_pkg::*;
 
typedef struct packed {
	logic   valid;
	PhysReg index;
} opt_PhysReg;

interface load_pc_ifc ();
	logic   we; // Write Enable
	Address new_pc;

	modport in  (input we, new_pc);
	modport out (output we, new_pc);
endinterface

interface load_forward_ifc ();
    logic   addr_valid;
    Address addr;
    logic   data_valid;
    Data    data;

    modport in  (input  addr_valid, addr, output data_valid, data);
    modport out (output addr_valid, addr, input  data_valid, data);
endinterface

interface branch_decoded_ifc ();
	logic valid;	// High means the instruction is a branch or a jump
	logic is_jump;	// High means the instruction is a jump
	mips_core_pkg::Address target;

	mips_core_pkg::BranchOutcome prediction;
	mips_core_pkg::Address recovery_target;

	modport decode (
		output valid, is_jump, target,
		input  prediction, recovery_target
	);
	modport hazard (
		output prediction, recovery_target,
		input  valid, is_jump, target
	);
endinterface

interface branch_result_ifc ();
	logic valid;
	mips_core_pkg::BranchOutcome prediction;
	mips_core_pkg::BranchOutcome outcome;
	logic [ADDR_WIDTH - 1 : 0] recovery_target;

	modport in  (input valid, prediction, outcome, recovery_target);
	modport out (output valid, prediction, outcome, recovery_target);
endinterface

interface d_cache_input_ifc ();
	logic valid;
	MemAccessType mem_action;
	logic [ADDR_WIDTH - 1 : 0] addr;
	logic [ADDR_WIDTH - 1 : 0] addr_next;
	logic [DATA_WIDTH - 1 : 0] data;

	modport in  (input valid, mem_action, addr, addr_next, data);
	modport out (output valid, mem_action, addr, addr_next, data);
endinterface

interface hazard_control_ifc ();
	// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
	// !!! Flush signal now has higher priority !!!
	// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

	logic flush;	// Flush signal of the previous stage
	logic stall;	// Stall signal of the next stage

	modport in  (input flush, stall);
	modport out (output flush, stall);
endinterface
