`ifndef SIMULATION_PKG
`define SIMULATION_PKG
`ifdef SIMULATION

`define _5(X) X a, X b, X c, X d, X e, X f 

import "DPI-C" function void pc_event(input int pc);
import "DPI-C" function void wb_event(input int addr, input int data);
import "DPI-C" function void ls_event(input int op, input int addr, input int data);
import "DPI-C" function void log_pipeline_stage(input int stage, `_5(input int));
import "DPI-C" function int debug_level();
import "DPI-C" function void signal_handler(input int signal);
import "DPI-C" function string alu_ctl_to_string(input int alu_ctl);
import "DPI-C" function string mips_reg_to_string(input int index);
import "DPI-C" function void predictor_event (input int prediction, input int correct);
import "DPI-C" function void btb_event (input int btb_hit);

`define fetch_event(pc, raw_instruction)                     `SIM(log_pipeline_stage(0, pc, raw_instruction, 0,      0,       0,    0))
`define decode_event(pc, ins, rw, rs, rt, imm)               `SIM(log_pipeline_stage(1, pc, ins,             rw,     rs,      rt,   imm))
`define rename_event(pc, commit_index, old, dst, src1, src2) `SIM(log_pipeline_stage(2, pc, commit_index,    old,    dst,     src1, src2))
`define issue_event(pc, commit_index, result, outcome)       `SIM(log_pipeline_stage(3, pc, commit_index,    result, outcome, 0,    0))
`define commit_event(pc, commit_index, dst, free)            `SIM(log_pipeline_stage(4, pc, commit_index,    dst,    free,    0,    0))

package simulation;

// Must be in-sync with C++ definitions
typedef enum int {
	INS_ADD,
	INS_ADDU,
	INS_SUB,
	INS_SUBU,
	INS_ADDI,
	INS_ADDIU,

	INS_AND,
	INS_OR,
	INS_XOR,
	INS_NOR,
	INS_ANDI,
	INS_ORI,
	INS_XORI,
	INS_SLL,
	INS_SRL,
	INS_SRA,
	INS_SLLV,
	INS_SRLV,
	INS_SRAV,
	INS_SLT,
	INS_SLTU,
	INS_SLTI,
	INS_SLTIU,
	INS_LUI,	

	INS_J,
	INS_JAL,
	INS_JR,
	INS_JALR,
	INS_BEQ,
	INS_BNE,
	INS_BLEZ,
	INS_BGEZ,
	INS_BLTZ,
	INS_BGTZ,

	INS_LW,
	INS_SW,

	INS_MTC0,

	INS_INVALID
} Instruction;

endpackage

`define SIM(CODE) CODE ; 
`else
`define SIM(CODE)
`endif // SIMULATION

`endif // SIMULATION_PKG