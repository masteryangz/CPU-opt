#pragma once

// All instructions (hopefully) that we implement
#define SIM_ALL_INSTRUCTIONS \
	X(ADD) \
	X(ADDU) \
	X(SUB) \
	X(SUBU) \
	X(ADDI) \
	X(ADDIU) \
	X(AND) \
	X(OR) \
	X(XOR) \
	X(NOR) \
	X(ANDI) \
	X(ORI) \
	X(XORI) \
	X(SLL) \
	X(SRL) \
	X(SRA) \
	X(SLLV) \
	X(SRLV) \
	X(SRAV) \
	X(SLT) \
	X(SLTU) \
	X(SLTI) \
	X(SLTIU) \
	X(LUI) \
	X(J) \
	X(JAL) \
	X(JR) \
	X(JALR) \
	X(BEQ) \
	X(BNE) \
	X(BLEZ) \
	X(BGEZ) \
	X(BLTZ) \
	X(BGTZ) \
	X(LW) \
	X(SW) \
	X(MTC0) \
	X(INVALID)

// !! must be in same order as defined in Verilog !!
#define SIM_ALL_ALU_OPERATIONS \
	X(NOP) \
	X(ADD) \
	X(ADDU) \
	X(SUB) \
	X(SUBU) \
	X(AND) \
	X(OR) \
	X(XOR) \
	X(SLT) \
	X(SLTU) \
	X(SLL) \
	X(SRL) \
	X(SRA) \
	X(SLLV) \
	X(SRLV) \
	X(SRAV) \
	X(NOR) \
	X(MTC0_PASS) \
	X(MTC0_FAIL) \
	X(MTC0_DONE) \
	X(BA) \
	X(BEQ) \
	X(BNE) \
	X(BLEZ) \
	X(BGTZ) \
	X(BGEZ) \
	X(BLTZ)


typedef enum {
#   define X(NAME) INS_ ## NAME,
    SIM_ALL_INSTRUCTIONS
#   undef X
} Instruction;

typedef enum {
#   define X(NAME) ALU_ ## NAME,
    SIM_ALL_ALU_OPERATIONS
#   undef X
} ALU_Operation;

typedef enum {} Register; // need C++ to see this as a distinct type

static constexpr const char* to_string(Instruction const& ins) {
    switch (ins)
    {
    default: return "(unknown instruction)";
#   define X(NAME) case INS_ ## NAME: return #NAME;
        SIM_ALL_INSTRUCTIONS
#   undef X
    }
}

static constexpr const char* to_string(ALU_Operation const& op) {
    switch (op)
    {
    default: return "(unknown operation)";
#   define X(NAME) case ALU_ ## NAME: return #NAME;
        SIM_ALL_ALU_OPERATIONS
#   undef X
    }
}

static const char* to_string(Register const& reg) {
	switch (reg) {
		case 0:  return "zero";
		case 1:  return "at";
		case 2:  return "v0";
		case 3:  return "v1";
		case 4:  return "a0";
		case 5:  return "a1";
		case 6:  return "a2";
		case 7:  return "a3";
		case 8:  return "t0";
		case 9:  return "t1";
		case 10: return "t2";
		case 11: return "t3";
		case 12: return "t4";
		case 13: return "t5";
		case 14: return "t6";
		case 15: return "t7";
		case 16: return "s0";
		case 17: return "s1";
		case 18: return "s2";
		case 19: return "s3";
		case 20: return "s4";
		case 21: return "s5";
		case 22: return "s6";
		case 23: return "s7";
		case 24: return "t8";
		case 25: return "t9";
		case 26: return "k0";
		case 27: return "k1";
		case 28: return "gp";
		case 29: return "sp";
		case 30: return "s8";
		case 31: return "ra";
		default: return "(invalid register)";
	}
}
