/*
 * mips_core_pkg.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/09/2018
 *
 * This package defines all the enum types used across different units within
 * mips_core.
 *
 * See wiki page "Systemverilog Primer" section package and enum for details.
 */
package mips_core_pkg;

//`define NON_BLOCKING
//`define PREDICTOR_ALWAYS_TAKEN
//`define ONE_CYCLE_FORWARD

parameter DATA_WIDTH = 32;
parameter ADDR_WIDTH = 26;

parameter MIPS_REG_COUNT = 32;
parameter PHYS_REG_COUNT = 64;

parameter EXECUTION_UNIT_COUNT = 2;

parameter COMMIT_QUEUE_SIZE = 32; // (instruction window size)
parameter STORE_QUEUE_SIZE = 64; // (store buffer size)

parameter FREE_REG_COUNT = PHYS_REG_COUNT - MIPS_REG_COUNT;

typedef logic [DATA_WIDTH - 1 : 0] Data;
typedef logic [ADDR_WIDTH - 1 : 0] Address;
typedef logic [$clog2(COMMIT_QUEUE_SIZE)-1:0] CommitIndex;
typedef logic [$clog2(FREE_REG_COUNT)-1:0] FreeIndex;

typedef struct packed {
    logic general;
    logic memory;
} unit_enable_t;

typedef enum logic [$clog2(EXECUTION_UNIT_COUNT)-1:0] {
    GENERAL_UNIT = 'd00,
    LOAD_STORE_UNIT  = 'd01
} UnitIndex;

//parameter PHYS_WIDTH = $clog2(PHYS_REG_COUNT);
//parameter MIPS_WIDTH = $clog2(MIPS_REG_COUNT);

typedef enum logic [$clog2(MIPS_REG_COUNT)-1:0] {
    zero = 5'd0,
    at   = 5'd1,
    v0   = 5'd2,
    v1   = 5'd3,
    a0   = 5'd4,
    a1   = 5'd5,
    a2   = 5'd6,
    a3   = 5'd7,
    t0   = 5'd8,
    t1   = 5'd9,
    t2   = 5'd10,
    t3   = 5'd11,
    t4   = 5'd12,
    t5   = 5'd13,
    t6   = 5'd14,
    t7   = 5'd15,
    s0   = 5'd16,
    s1   = 5'd17,
    s2   = 5'd18,
    s3   = 5'd19,
    s4   = 5'd20,
    s5   = 5'd21,
    s6   = 5'd22,
    s7   = 5'd23,
    t8   = 5'd24,
    t9   = 5'd25,
    k0   = 5'd26,
    k1   = 5'd27,
    gp   = 5'd28,
    sp   = 5'd29,
    s8   = 5'd30,
    ra   = 5'd31
} MipsReg;

typedef logic [$clog2(PHYS_REG_COUNT) - 1 : 0] PhysReg;

typedef enum logic [4:0] {
    ALUCTL_NOP			= 'd00, // No Operation (noop)
    ALUCTL_ADD			= 'd01, // Add (signed)
    ALUCTL_ADDU			= 'd02, // Add (unsigned)
    ALUCTL_SUB			= 'd03, // Subtract (signed)
    ALUCTL_SUBU			= 'd04, // Subtract (unsigned)
    ALUCTL_AND			= 'd05, // AND
    ALUCTL_OR			= 'd06, // OR
    ALUCTL_XOR			= 'd07, // XOR
    ALUCTL_SLT	    	= 'd08, // Set on Less Than
    ALUCTL_SLTU			= 'd09, // Set on Less Than (unsigned)
    ALUCTL_SLL			= 'd10, // Shift Left Logical
    ALUCTL_SRL			= 'd11, // Shift Right Logical
    ALUCTL_SRA			= 'd12, // Shift Right Arithmetic
    ALUCTL_SLLV			= 'd13, // Shift Left Logical Variable
    ALUCTL_SRLV			= 'd14, // Shift Right Logical Variable
    ALUCTL_SRAV			= 'd15, // Shift Right Arithmetic Variable
    ALUCTL_NOR			= 'd16, // NOR
    ALUCTL_MTC0_PASS	= 'd17, // Move to Coprocessor (PASS)
    ALUCTL_MTC0_FAIL	= 'd18, // Move to Coprocessor (FAIL)
    ALUCTL_MTC0_DONE	= 'd19, // Move to Coprocessor (DONE)

    ALUCTL_BA,			// Unconditional branch
    ALUCTL_BEQ,
    ALUCTL_BNE,
    ALUCTL_BLEZ,
    ALUCTL_BGTZ,
    ALUCTL_BGEZ,
    ALUCTL_BLTZ
} AluCtl;

typedef enum logic {
    WRITE = 1'b0,
    READ  = 1'b1
} MemAccessType;

typedef enum logic {
    NOT_TAKEN = 1'b0,
    TAKEN     = 1'b1
} BranchOutcome;

typedef struct packed {
	logic valid;
	Data data;
} cache_output_t;

typedef struct packed {
	CommitIndex   commit_index; // index to commit in commit queue
    AluCtl        alu_ctl;
	logic         is_branch_jump; // b + j + jr
	logic         is_jump;        // j + jr
	logic         is_jump_reg;    // jr
	logic         is_mem_access;
    Data          immediate;
	Address       branch_target;
    logic         uses_src1; // if false, then replace with zero
	logic         uses_src2; // if false, the replace with immediate
	logic         uses_dst;
	MemAccessType mem_action;
	Address       pc; // DEBUG
    BranchOutcome prediction;
    Address       recovery_target;
} instruction_metadata_t;

typedef struct packed {
	instruction_metadata_t meta;
	PhysReg src1;
	PhysReg src2;
	PhysReg dst;
} instruction_t;

typedef struct packed {
	instruction_metadata_t meta;
    PhysReg dst;
    PhysReg src1;
	PhysReg src2;
} scheduler_entry_t;

typedef struct packed {
	AluCtl alu_ctl;
	Data   op1;
	Data   op2;
} execution_command_t;

typedef struct packed {
	MemAccessType access;
	AluCtl        alu_ctl;
	Data          op1;
	Data          op2;
    PhysReg       dst;
    Data          data;
} memory_command_t;

typedef struct packed {
	logic [1:0] id;
	Data  data; // TODO(mitch): remove this field
} mtc0_t;

typedef struct packed {
	Data          data;
	BranchOutcome outcome;
	mtc0_t        mtc0;
} execution_result_t;

typedef struct packed {
	logic    valid;
	PhysReg  index;
	Data     data;
} write_back_t;

typedef struct packed {
    logic   valid;
    Address addr;
    Data    data;
} opt_memory_write_t;

typedef struct packed {
	logic   valid;
	Address target;
} prediction_request_t;

function scheduler_entry_t scheduler_entry (input instruction_t incoming);
	begin
        scheduler_entry.meta = incoming.meta;
        scheduler_entry.dst  = incoming.dst;
        scheduler_entry.src1 = incoming.src1;
        scheduler_entry.src2 = incoming.src2;
	end
endfunction

endpackage

import mips_core_pkg::*;