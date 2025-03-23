interface remap_ifc ();
	MipsReg mips;
	PhysReg phys;

	modport in  (input  mips, output phys);
	modport out (output mips, input  phys);
endinterface

module register_mapping_table (
    input logic clk,
    input logic rst_n,

    // From Hazard Controller
    input logic i_restore, // want to restore every mapping that has not committed

    // (Issue stage) Set new register mapping
    input  logic   i_want_new_mapping,
    input  PhysReg i_new_phys_reg,
    input  MipsReg i_dst_mips_reg,
    // But... we also need to get the old mapping
    //  so that we know what register to put
    //  into the free queue when we are done
    output PhysReg o_old_phys_reg,

    // (Commit stage) Write back
    input logic   i_commit_valid,
    input MipsReg i_commit_mips,
    input PhysReg i_commit_phys,

    // (Rename Stage) Mips -> Phys
	remap_ifc.in   src1_remap,
	remap_ifc.in   src2_remap
);

// Mips -> Phys
PhysReg map_mips_to_phys [MIPS_REG_COUNT];

PhysReg map_mips_to_phys_checkpoint [MIPS_REG_COUNT];

assign src1_remap.phys = map_mips_to_phys[src1_remap.mips];
assign src2_remap.phys = map_mips_to_phys[src2_remap.mips];

assign o_old_phys_reg  = map_mips_to_phys[i_dst_mips_reg];

always_ff @(posedge clk)
begin
    if (~rst_n)
    begin
        // Start off with registers mapped 1 to 1,
        // i.e. MIPS register i <=> Physical register i
        for (int i = 0; i < MIPS_REG_COUNT; ++i)
            map_mips_to_phys[i] = PhysReg'(i);

        for (int i = 0; i < MIPS_REG_COUNT; ++i)
            map_mips_to_phys_checkpoint[i] <= PhysReg'(i);
    end
    else if (i_restore)
    begin
        for (int i = 0; i < MIPS_REG_COUNT; ++i)
        begin
            if (i_commit_valid && MipsReg'(i) == i_commit_mips)
            begin
                map_mips_to_phys[i] <= i_commit_phys;
            end
            else
            begin
                map_mips_to_phys[i] <= map_mips_to_phys_checkpoint[i];
            end
        end

        if (i_commit_valid)
        begin
            map_mips_to_phys_checkpoint[i_commit_mips] <= i_commit_phys;
        end

        //if (i_commit_valid)
        //if (debug_level() >= 3)
        //$display("%t| set mapping! %s <=> p%0d", $time, mips_reg_to_string(i_commit_mips), i_commit_phys);
    end
    else
    begin
        // Create a new mapping
        if (i_want_new_mapping)
        begin
            map_mips_to_phys[i_dst_mips_reg] <= i_new_phys_reg;
        end

        if (i_commit_valid)
        begin
            map_mips_to_phys_checkpoint[i_commit_mips] <= i_commit_phys;

            //if (debug_level() >= 3)
            //$display("%t| set mapping! %s <=> p%0d", $time, mips_reg_to_string(i_commit_mips), i_commit_phys);
        end
    end
end

endmodule