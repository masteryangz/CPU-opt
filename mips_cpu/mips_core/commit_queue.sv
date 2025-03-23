
// We need to:
// - Insert instruction into queue
//   -> need to give the index where we inserted the instruction
// - if there is a instruction that is ready to be committed
//   -> then we need to commit that instruction

module commit_queue (
    input logic clk,
    input logic rst_n,

    // From Hazard Controller
    input hazard_control_ifc.in i_hc,

    // From (Issue stage)
    input  logic         i_incoming_valid,
    input  instruction_t i_incoming_instruction,
    input  MipsReg       i_incoming_dst_mips,
    input  PhysReg       i_incoming_old_reg,

    // From (Execution stage)
    input  logic              i_execution_valid,
    input  CommitIndex        i_execution_commit_index,
    input  execution_result_t i_execution_result,
    
    // To (Rename stage)
    output CommitIndex    o_inserted_index,
    output opt_PhysReg    o_free_reg,

    // Write-Back (Commit stage)
    output write_back_t   o_write_back,
    output MipsReg        o_dst_mips,
    output logic          o_store, // was this command a memory store?

    // Output to Hazard Controller
    output logic          o_overflow,
    branch_result_ifc.out o_branch_result,
    
    // Output to the MIPS Core
    output mtc0_t         o_mtc0,
    output Address        o_pc
);

typedef struct packed {
    // From (Issue stage)
    logic         ready;      // Is this instruction ready to be committed?
    logic         want_write; // Does this instruction want to write to the regfile?
    PhysReg       dst;        // Which register do we write to?
    PhysReg       old;        // What register to free when we are done
    logic         is_branch;
    logic         is_jump;    // always TAKEN
    logic         is_jump_reg;
    logic         is_store;
    BranchOutcome prediction;
    Address       target;
    Address       pc; // DEBUG
    MipsReg       mips;

    // From (Dispatch stage)
    execution_result_t result;
} entry_t;

// REGISTERED
entry_t entries [COMMIT_QUEUE_SIZE];
CommitIndex commit_index;
CommitIndex insert_index;
logic full;

// COMBINATIONAL
entry_t commit_entry;
logic   want_commit_registered;
logic   want_commit_incoming;
logic   want_to_commit;

// There are 4 cases that we need to be handled for committing:
//   case 1: next entry to commit is ready to be committed
//      -> commit that entry
//   case 2: next entry to commit isn't ready but the
//           incoming result will make it ready
//      -> still need to commit that entry, but use the results we just got
//   case 3: next entry is not ready but we have an incoming result
//      -> write result to corresponding index
//   case 4: next entry is not ready and we don't have any incoming result

assign o_inserted_index = insert_index;
assign o_overflow = full && i_incoming_valid && !want_to_commit;
assign o_pc = entries[commit_index].pc;

always_comb
begin
    want_commit_incoming   =     i_execution_valid && (commit_index == i_execution_commit_index);
    want_commit_registered = !want_commit_incoming && entries[commit_index].ready;
    want_to_commit         =  want_commit_incoming || want_commit_registered;
end

always_comb
begin
    o_write_back.valid = want_to_commit && entries[commit_index].want_write;
    o_write_back.index = entries[commit_index].dst;
    o_write_back.data  = entries[commit_index].result.data;
    o_dst_mips         = entries[commit_index].mips;

    // only want to free a register, if we even had one to begin with
    //  --> meaning: if we are writing to a register,
    //               then we need to allocate one, (create a new mapping)
    //               which means we have an old mapping
    o_free_reg = {o_write_back.valid, entries[commit_index].old};

    o_branch_result.valid      = want_to_commit && entries[commit_index].is_branch;
    o_branch_result.prediction = entries[commit_index].prediction;
    o_branch_result.outcome    = entries[commit_index].result.outcome;
    o_store                    = want_to_commit && entries[commit_index].is_store;
    
    if (entries[commit_index].is_jump_reg)
        o_branch_result.recovery_target = Address'(entries[commit_index].result.data);
    else
        o_branch_result.recovery_target = entries[commit_index].target;

    o_mtc0 = entries[commit_index].result.mtc0;

    // Execution results are not yet written -> need to get it from incoming
    if (want_commit_incoming)
    begin
        o_write_back.data       = i_execution_result.data;
        o_branch_result.outcome = i_execution_result.outcome;
        o_mtc0                  = i_execution_result.mtc0;

        if (entries[commit_index].is_jump_reg)
            o_branch_result.recovery_target = Address'(i_execution_result.data);
    end

`ifdef SIMULATION
    if (want_to_commit)
    begin
        if (o_mtc0.id == 2'd1) $display("%m (%t) \x1b[92mPASS\x1b[0m test %x", $time, o_mtc0.data);
        if (o_mtc0.id == 2'd2) $display("%m (%t) \x1b[91mFAIL\x1b[0m test %x", $time, o_mtc0.data);
        if (o_mtc0.id == 2'd3) $display("%m (%t) \x1b[97mDONE\x1b[0m test %x", $time, o_mtc0.data);
    end
`endif

    if (entries[commit_index].is_jump)
        o_branch_result.outcome = TAKEN;
end

always_ff @(posedge clk)
begin
    if (~rst_n || i_hc.flush)
    begin
        commit_index <= '0;
        insert_index <= '0;
        full         <= '0;

        for (int i = 0; i < COMMIT_QUEUE_SIZE; ++i)
            entries[i] <= '0;
    end
    // If we do any inserts, then we will overflow, so we must wait
    // for the next instruction to be committed
    else if (o_overflow)
    begin
        // But we can still ready instructions
        if (i_execution_valid && !want_commit_incoming)
        begin
            entries[i_execution_commit_index].result <= i_execution_result;
            entries[i_execution_commit_index].ready <= 1'b1;
            //if (debug_level() >= 6)
            //$display("COMMIT entry at %d is READY!", i_execution_commit_index);
        end
    end
    else
    begin
        if (i_incoming_valid)
        begin
            // Writing to the last value in commit queue
            if (!want_to_commit && insert_index + CommitIndex'(1) == commit_index)
            begin
                full <= 1'b1;
            end

            if (debug_level() >= 6)
            $display("COMMIT new entry at %d!", insert_index);

            entries[insert_index].ready       <= '0;
            entries[insert_index].want_write  <= i_incoming_instruction.meta.uses_dst;
            entries[insert_index].dst         <= i_incoming_instruction.dst;
            entries[insert_index].old         <= i_incoming_old_reg;
            entries[insert_index].is_branch   <= i_incoming_instruction.meta.is_branch_jump;
            entries[insert_index].is_jump     <= i_incoming_instruction.meta.is_jump;
            entries[insert_index].is_jump_reg <= i_incoming_instruction.meta.is_jump_reg;
            entries[insert_index].is_store    <= i_incoming_instruction.meta.is_mem_access && (i_incoming_instruction.meta.mem_action == WRITE);
            entries[insert_index].prediction  <= i_incoming_instruction.meta.prediction;
            entries[insert_index].target      <= i_incoming_instruction.meta.recovery_target;
            entries[insert_index].pc          <= i_incoming_instruction.meta.pc;
            entries[insert_index].mips        <= i_incoming_dst_mips;
            insert_index                      <= insert_index + CommitIndex'(1);
        end

        if (want_to_commit)
        begin
            // Removing an instruction that will not be replaced
            if (!i_incoming_valid && full)
            begin
                full <= 1'b0;
            end

            entries[commit_index].ready <= 1'b0;

            commit_index <= commit_index + 1;
        end

        if (i_execution_valid && !want_commit_incoming)
        begin
            entries[i_execution_commit_index].result <= i_execution_result;
            entries[i_execution_commit_index].ready <= 1'b1;
            //if (debug_level() >= 6)
            //$display("COMMIT entry at %d is READY!", i_execution_commit_index);
        end
    end
end

endmodule
