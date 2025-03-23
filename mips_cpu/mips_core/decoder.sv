/*
 * decoder.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/08/2018
 *
 * Decoder decode an instruction to control signals.
 *
 * See wiki page "Branch and Jump" for details about branch/jump instructions.
 * See wiki page "Handle Register Zero" for deatils about instructions reading
 * from or writing to register zero.
 */
`include "simulation.svh"

typedef struct packed {
	logic valid;
	mips_core_pkg::AluCtl alu_ctl;

	logic is_branch_jump;
	logic is_jump;
	logic is_jump_reg;
	Address branch_target;

	logic is_mem_access;
	mips_core_pkg::MemAccessType mem_action;

	logic uses_rs;
	mips_core_pkg::MipsReg rs_addr;

	logic uses_rt;
	mips_core_pkg::MipsReg rt_addr;

	logic uses_immediate;
	Data immediate;

	logic uses_rw;
	mips_core_pkg::MipsReg rw_addr;
} decoder_output_t;

module decoder (
	input  Address          i_pc,
	input  cache_output_t   i_inst,
	output decoder_output_t out
);

	task rs;
		begin
			// Only set uses_rs if it is not register zero
			out.uses_rs = |i_inst.data[25:21];
			out.rs_addr = mips_core_pkg::MipsReg'(i_inst.data[25:21]);
		end
	endtask

	task rt;
		begin
			// Only set uses_rt if it is not register zero
			out.uses_rt = |i_inst.data[20:16];
			out.rt_addr = mips_core_pkg::MipsReg'(i_inst.data[20:16]);
		end
	endtask

	task route_rt_to_rs;
		begin
			// Rerouting rt to rs for sll, srl, sra
			// Only set uses_rs if it is not register zero
			out.uses_rs = |i_inst.data[20:16];
			out.rs_addr = mips_core_pkg::MipsReg'(i_inst.data[20:16]);
		end
	endtask

	task immediate_raw;
		input [31:0] immediate;
		begin
			out.uses_immediate = 1'b1;
			out.immediate = immediate;
		end
	endtask

	task immediate_zero_extend;
		immediate_raw(32'(unsigned'(i_inst.data[15:0])));
	endtask

	task immediate_signed_extend;
		immediate_raw(32'(signed'(i_inst.data[15:0])));
	endtask

	task immediate_shamt;
		immediate_raw(32'(unsigned'(i_inst.data[10:6])));
	endtask

	task rw_raw;
		input [4:0] rw;
		begin
			// Only set uses_rw if it is not register zero
			out.uses_rw = |rw;
			out.rw_addr = mips_core_pkg::MipsReg'(rw);
		end
	endtask

	task rw_rtype;
		rw_raw(i_inst.data[15:11]);
	endtask

	task rw_itype;
		rw_raw(i_inst.data[20:16]);
	endtask

	task typical_rtype;
		begin
			rs();
			rt();
			rw_rtype();
		end
	endtask

	task shamt_rtype;
		begin
			route_rt_to_rs();
			rw_rtype();
			immediate_shamt();
		end
	endtask

	task signed_extend_itype;
		begin
			rs();
			rw_itype();
			immediate_signed_extend();
		end
	endtask

	task zero_extend_itype;
		begin
			rs();
			rw_itype();
			immediate_zero_extend();
		end
	endtask


	`SIM(int instruction)

	always_comb
	begin
		// Set defaults to nop
		`SIM(instruction = simulation::INS_INVALID)
		out.valid = i_inst.valid;
		out.alu_ctl = ALUCTL_NOP;
		out.is_branch_jump = 1'b0;
		out.is_jump = 1'b0;
		out.is_jump_reg = 1'b0;
		out.branch_target = '0;
		out.is_mem_access = 1'b0;
		out.mem_action = READ;

		out.uses_rs = 1'b0;
		out.rs_addr = zero;

		out.uses_rt = 1'b0;
		out.rt_addr = zero;

		out.uses_immediate = 1'b0;
		out.immediate = '0;

		out.uses_rw = 1'b0;
		out.rw_addr = zero;

		if (i_inst.valid)
		begin
			case(i_inst.data[31:26])
				6'h0:  //r-type
				begin
					case (i_inst.data[5:0])
						6'h20:  // add
						begin
							`SIM(instruction = simulation::INS_ADD)
							out.alu_ctl = ALUCTL_ADD;
							typical_rtype();
						end

						6'h21:  // addu
						begin
							`SIM(instruction = simulation::INS_ADDU)
							out.alu_ctl = ALUCTL_ADDU;
							typical_rtype();
						end

						6'h22:  // sub
						begin
							`SIM(instruction = simulation::INS_SUB)
							out.alu_ctl = ALUCTL_SUB;
							typical_rtype();
						end

						6'h23:  // subu
						begin
							`SIM(instruction = simulation::INS_SUBU)
							out.alu_ctl = ALUCTL_SUBU;
							typical_rtype();
						end

						6'h24:  // and
						begin
							`SIM(instruction = simulation::INS_AND)
							out.alu_ctl = ALUCTL_AND;
							typical_rtype();
						end

						6'h25:  // or
						begin
							`SIM(instruction = simulation::INS_OR)
							out.alu_ctl = ALUCTL_OR;
							typical_rtype();
						end

						6'h26:  // xor
						begin
							`SIM(instruction = simulation::INS_XOR)
							out.alu_ctl = ALUCTL_XOR;
							typical_rtype();
						end

						6'h27:  // nor
						begin
							`SIM(instruction = simulation::INS_NOR)
							out.alu_ctl = ALUCTL_NOR;
							typical_rtype();
						end

						6'h00:  // sll
						begin
							`SIM(instruction = simulation::INS_SLL)
							out.alu_ctl = ALUCTL_SLL;
							shamt_rtype();
						end

						6'h02:  // srl
						begin
							`SIM(instruction = simulation::INS_SRL)
							out.alu_ctl = ALUCTL_SRL;
							shamt_rtype();
						end

						6'h03:  // sra
						begin
							`SIM(instruction = simulation::INS_SRA)
							out.alu_ctl = ALUCTL_SRA;
							shamt_rtype();
						end

						6'h04:  // sllv
						begin
							`SIM(instruction = simulation::INS_SLLV)
							out.alu_ctl = ALUCTL_SLLV;
							typical_rtype();
						end

						6'h06:  // srlv
						begin
							`SIM(instruction = simulation::INS_SRLV)
							out.alu_ctl = ALUCTL_SRLV;
							typical_rtype();
						end

						6'h07:  // srav
						begin
							`SIM(instruction = simulation::INS_SRAV)
							out.alu_ctl = ALUCTL_SRAV;
							typical_rtype();
						end

						6'h2a:  // slt
						begin
							`SIM(instruction = simulation::INS_SLT)
							out.alu_ctl = ALUCTL_SLT;
							typical_rtype();
						end

						6'h2b:  // sltu
						begin
							`SIM(instruction = simulation::INS_SLTU)
							out.alu_ctl = ALUCTL_SLTU;
							typical_rtype();
						end

						6'h08:  // jr
						begin
							`SIM(instruction = simulation::INS_JR)
							//out.alu_ctl = ALUCTL_NOP;	// jr does not use alu
							rs();
							out.is_branch_jump = 1'b1;
							out.is_jump = 1'b1;
							out.is_jump_reg = 1'b1;
							// MODIFICATION(mitch): need to read the register value
							out.alu_ctl = ALUCTL_OR;
						end

						6'h09:  //jalr
						begin
							`SIM(instruction = simulation::INS_JALR)
							out.alu_ctl = ALUCTL_OR;
							rs();
							rw_raw(ra);	// jalr always write to ra (31)
							immediate_raw(32'(unsigned'(i_pc)) + 8);
							out.is_branch_jump = 1'b1;
							out.is_jump = 1'b1;
							out.is_jump_reg = 1'b1;
						end

						6'h18:  // mul
						begin
						`ifdef SIMULATION
							if (debug_level() >= 1) $display("%m (%t) mul not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
						`endif
							out.valid = 1'b0;
						end

						6'h19:  //mulu
						begin
						`ifdef SIMULATION
							if (debug_level() >= 1) $display("%m (%t) mulu not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
						`endif
							out.valid = 1'b0;
						end

						6'h1a:  //div
						begin
						`ifdef SIMULATION
							if (debug_level() >= 1) $display("%m (%t) div not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
						`endif
							out.valid = 1'b0;
						end

						6'h1b:  //divu
						begin
						`ifdef SIMULATION
							if (debug_level() >= 1) $display("%m (%t) divu not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
						`endif
							out.valid = 1'b0;
						end

						default:
						begin
						`ifdef SIMULATION
							if (debug_level() >= 1) $display("%m (%t) unknown R-type funct code %b. Treated as a NOP. PC=0x%x", $time, i_inst.data[5:0], i_pc);
						`endif
							out.valid = 1'b0;
						end
					endcase
				end

				6'h08:  		//addi
				begin
					`SIM(instruction = simulation::INS_ADDI)
					out.alu_ctl = ALUCTL_ADD;
					signed_extend_itype();
				end

				6'h09:  //addiu
				begin
					`SIM(instruction = simulation::INS_ADDIU)
					out.alu_ctl = ALUCTL_ADDU;
					signed_extend_itype();
				end

				6'h0c:  //andi
				begin
					`SIM(instruction = simulation::INS_ANDI)
					out.alu_ctl = ALUCTL_AND;
					zero_extend_itype();
				end

				6'h0d:  //ori
				begin
					`SIM(instruction = simulation::INS_ORI)
					out.alu_ctl = ALUCTL_OR;
					zero_extend_itype();
				end

				6'h0e:  //xori
				begin
					`SIM(instruction = simulation::INS_XORI)
					out.alu_ctl = ALUCTL_XOR;
					zero_extend_itype();
				end

				6'h0a:  //slti
				begin
					`SIM(instruction = simulation::INS_SLTI)
					out.alu_ctl = ALUCTL_SLT;
					signed_extend_itype();
				end

				6'h0b:  //sltiu
				begin
					`SIM(instruction = simulation::INS_SLTIU)
					out.alu_ctl = ALUCTL_SLTU;
					signed_extend_itype();
				end

				6'h0f:  //lui Implemented as 0 | Immediate
				begin
					`SIM(instruction = simulation::INS_LUI)
					out.alu_ctl = ALUCTL_OR;
					rw_itype();
					immediate_raw({i_inst.data[15:0], 16'h0000});
				end

				6'h04:  //beq
				begin
					`SIM(instruction = simulation::INS_BEQ)
					out.alu_ctl = ALUCTL_BEQ;
					rs();
					rt();
					out.is_branch_jump = 1'b1;
					out.branch_target = i_pc + ADDR_WIDTH'(4) + ADDR_WIDTH'(signed'({i_inst.data[15:0], 2'b00}));
				end

				6'h05:  //bne
				begin
					`SIM(instruction = simulation::INS_BNE)
					out.alu_ctl = ALUCTL_BNE;
					rs();
					rt();
					out.is_branch_jump = 1'b1;
					out.branch_target = i_pc + ADDR_WIDTH'(4) + ADDR_WIDTH'(signed'({i_inst.data[15:0], 2'b00}));
				end

				6'h06:  //blez
				begin
					`SIM(instruction = simulation::INS_BLEZ)
					out.alu_ctl = ALUCTL_BLEZ;
					rs();
					rt();
					out.is_branch_jump = 1'b1;
					out.branch_target = i_pc + ADDR_WIDTH'(4) + ADDR_WIDTH'(signed'({i_inst.data[15:0], 2'b00}));
				end

				6'h01:  //bgez or bltz
				begin
					if( i_inst.data[16] )
					begin
						`SIM(instruction = simulation::INS_BGEZ)
						out.alu_ctl = ALUCTL_BGEZ;
					end
					else
					begin
						`SIM(instruction = simulation::INS_BLTZ)
						out.alu_ctl = ALUCTL_BLTZ;
					end
					rs();
					rt();
					out.is_branch_jump = 1'b1;
					out.branch_target = i_pc + ADDR_WIDTH'(4) + ADDR_WIDTH'(signed'({i_inst.data[15:0], 2'b00}));
				end

				6'h07:  //bgtz
				begin
					`SIM(instruction = simulation::INS_BGTZ)
					out.alu_ctl = ALUCTL_BGTZ;
					rs();
					rt();
					out.is_branch_jump = 1'b1;
					out.branch_target = i_pc + ADDR_WIDTH'(4) + ADDR_WIDTH'(signed'({i_inst.data[15:0], 2'b00}));
				end

				6'h02:  // j
				begin
					`SIM(instruction = simulation::INS_J)
					out.alu_ctl = ALUCTL_NOP;	// jr does not use alu
					out.is_branch_jump = 1'b1;
					out.is_jump = 1'b1;
					out.branch_target = {i_inst.data[ADDR_WIDTH - 3: 0], 2'b00};
				end

				6'h03:  // jal
				begin
					`SIM(instruction = simulation::INS_JAL)
					out.alu_ctl = ALUCTL_OR;
					rw_raw(ra);	// jal always write to ra (31)
					immediate_raw(32'(unsigned'(i_pc)) + 8);
					out.is_branch_jump = 1'b1;
					out.is_jump = 1'b1;
					out.branch_target = {i_inst.data[ADDR_WIDTH - 3: 0], 2'b00};
				end

				6'h20: //lb
				begin
				`ifdef SIMULATION
					if (debug_level() >= 1) $display("%m (%t) lb not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
				`endif
					out.valid = 1'b0;
				end

				6'h24: //lbu
				begin
				`ifdef SIMULATION
					if (debug_level() >= 1) $display("%m (%t) lbu not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
				`endif
					out.valid = 1'b0;
				end

				6'h21: //lh
				begin
				`ifdef SIMULATION
					if (debug_level() >= 1) $display("%m (%t) lh not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
				`endif
					out.valid = 1'b0;
				end

				6'h25: //lhu
				begin
				`ifdef SIMULATION
					if (debug_level() >= 1) $display("%m (%t) lhu not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
				`endif
					out.valid = 1'b0;
				end

				6'h23: //lw
				begin
					`SIM(instruction = simulation::INS_LW)
					out.alu_ctl = ALUCTL_ADD;
					out.is_mem_access = 1'b1;
					out.mem_action = READ;
					signed_extend_itype();
				end

				6'h28:  //sb
				begin
				`ifdef SIMULATION
					if (debug_level() >= 1)
					$display("%m (%t) sb not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
				`endif
					out.valid = 1'b0;
				end

				6'h29:  //sh
				begin
				`ifdef SIMULATION
					if (debug_level() >= 1) $display("%m (%t) sh not supported. Treated as a NOP. PC=0x%x", $time, i_pc);
				`endif
					out.valid = 1'b0;
				end

				6'h2b:  //sw
				begin
					`SIM(instruction = simulation::INS_SW)
					out.alu_ctl = ALUCTL_ADD;
					out.is_mem_access = 1'b1;
					out.mem_action = WRITE;
					rs();
					rt();
					immediate_signed_extend();
				end

				6'h10:  //mtc0
				begin
					case(i_inst.data[15:11])
						5'h17:
						begin
							out.alu_ctl = ALUCTL_MTC0_PASS;
							rt();
						end

						5'h18:
						begin
							out.alu_ctl = ALUCTL_MTC0_FAIL;
							rt();
						end

						5'h19:
						begin
							out.alu_ctl = ALUCTL_MTC0_DONE;
							rt();
						end

						default:
						begin
						`ifdef SIMULATION
							if (debug_level() >= 1) $display("%m (%t) unknown MTC0 value 0x%x. Treated as a NOP. PC=0x%x", $time, i_inst.data[15:11], i_pc);
						`endif
							out.valid = 1'b0;
						end
					endcase
					
					if (out.valid)
						`SIM(instruction = simulation::INS_MTC0)
				end

				default:
				begin
				`ifdef SIMULATION
					if (debug_level() >= 1) $display("%m (%t) unknown opcode %b. Treated as a NOP. PC=0x%x", $time, i_inst.data[31:26], i_pc);
				`endif
					out.valid = 1'b0;
				end
			endcase
		end
	end
endmodule
