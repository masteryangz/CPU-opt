module register_renamer (
	input  logic             i_stall,
	input  decoder_output_t  i_decoded_instruction,
	input  CommitIndex       i_commit_index,
	input  PhysReg           i_free_reg,
	input  Address           i_pc,
	input  BranchOutcome     i_prediction,
	input  Address           i_recovery_target,

	remap_ifc.out            src1_remap,
	remap_ifc.out            src2_remap,

    output logic             o_dst_want_reg,
	output unit_enable_t     o_unit_enable,
	output instruction_t     o_instruction
);

always_comb
begin
	// Effectively do nothing if no incoming instruction
	o_instruction      = '0;
	o_dst_want_reg     = '0;
	src1_remap.mips    = MipsReg'(0);
	src2_remap.mips    = MipsReg'(0);
	o_unit_enable      = '0;

	if (i_decoded_instruction.valid && !i_stall)
	begin
		o_unit_enable.memory = i_decoded_instruction.is_mem_access;
		o_unit_enable.general = !o_unit_enable.memory;

		o_dst_want_reg  = i_decoded_instruction.uses_rw;
		src1_remap.mips = i_decoded_instruction.rs_addr;
		src2_remap.mips = i_decoded_instruction.rt_addr;

		o_instruction.meta.commit_index   = i_commit_index;
		o_instruction.meta.alu_ctl        = i_decoded_instruction.alu_ctl;
		o_instruction.meta.is_branch_jump = i_decoded_instruction.is_branch_jump;
		o_instruction.meta.is_jump        = i_decoded_instruction.is_jump;
		o_instruction.meta.is_jump_reg    = i_decoded_instruction.is_jump_reg;
		o_instruction.meta.is_mem_access  = i_decoded_instruction.is_mem_access;
		o_instruction.meta.immediate      = i_decoded_instruction.immediate;
		o_instruction.meta.branch_target  = i_decoded_instruction.branch_target;
		o_instruction.meta.uses_src1      = i_decoded_instruction.uses_rs;
		o_instruction.meta.uses_src2      = i_decoded_instruction.uses_rt;
		o_instruction.meta.uses_dst       = i_decoded_instruction.uses_rw;
		o_instruction.meta.mem_action     = i_decoded_instruction.mem_action;
		o_instruction.meta.pc             = i_pc;
		o_instruction.meta.prediction     = i_prediction;
		o_instruction.meta.recovery_target= i_recovery_target;
		o_instruction.src1                = src1_remap.phys;
		o_instruction.src2                = src2_remap.phys;
		o_instruction.dst                 = i_free_reg;
	end
end

endmodule