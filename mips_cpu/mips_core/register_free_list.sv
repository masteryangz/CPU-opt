module register_free_list (
    input logic clk,
    input logic rst_n,

    // From Hazard Controller
    input logic i_restore,

    // (Issue Stage) Register Allocation
    input  logic    i_want_reg,
	output PhysReg  o_free_reg,

    // (Commit Stage) Register Freeing
    input opt_PhysReg i_inserted_reg
);

/*
    --- Register Free Queue Illustration ---

+-----|-|---------------------------------|-|----------+
| /// | |        [free registers]         | | //////// |
+-----|-|---------------------------------|-|----------+
       ^ allocate_index                    ^ insert_index


After some allocations ...

+-----|-|-|-|------------------------------|-|---------+
| ////| | | |        [free registers]      | | /////// |
+-----|-|-|-|------------------------------|-|---------+
       ^   ^ allocate_index                 ^ insert_index
       |
       \ allocate_restore_index

allocate_restore_index will always run behind allocate_index
 for easy recovery of registers that were allocated
*/

// REGISTERED
PhysReg registers [FREE_REG_COUNT]; // circular queue of free registers
FreeIndex allocate_index;           // place to allocate a register
FreeIndex insert_index;             // place to insert a free register
FreeIndex allocate_restore_index;   // where to restore the value of `allocate_index` when flushing

always_comb
begin
    o_free_reg = registers[allocate_index];
end

always_ff @(posedge clk)
begin
    if (~rst_n)
    begin
        // We initialize the mapping to be all the physical
        //  registers that are not initially mapped by the
        //  mapping table.
        for (int i = 0; i < FREE_REG_COUNT; ++i)
            registers[i] <= PhysReg'(i + MIPS_REG_COUNT);

        allocate_index         <= '0;
        insert_index           <= '0;
        allocate_restore_index <= '0;
    end
    else
    begin
        if (i_restore)
        begin
            // Why do we add one?
            //   because we want THIS instruction that caused the flush
            //   to free the register it has
            // -> ONLY Commit can insert registers
            // -> ONLY Commit can cause a flush
            allocate_index <= allocate_restore_index + (i_inserted_reg.valid? FreeIndex'(1) : FreeIndex'(0));
        end
        else
        begin
            // Here we are able to do an allocation (Issue Stage)
            if (i_want_reg)
            begin
                //debug_set_register(1, registers[allocate_index], 0);

                allocate_index <= allocate_index + FreeIndex'(1);

            `ifdef SIMULATION
                if ((allocate_index + FreeIndex'(1)) == insert_index)
                begin
                    $display("This is a bug, impossible to happen on normal execution :)");
                end
            `endif
            end
        end

        // Insert a register back into the free queue (Commit Stage)
        if (i_inserted_reg.valid)
        begin
            //debug_set_register(0, i_inserted_reg.index, 0);

            registers[insert_index] <= i_inserted_reg.index;
            insert_index            <= insert_index           + FreeIndex'(1);
            allocate_restore_index  <= allocate_restore_index + FreeIndex'(1);

            if (debug_level() >= 3)
            $display("%t| freed register (p%0d)", $time, i_inserted_reg.index);
        end

        
        // Check for duplicates in the queue
        for (int i = 0; i < FREE_REG_COUNT; i++) begin
            for (int j = i + 1; j < FREE_REG_COUNT; j++) begin
                if (registers[i] == registers[j]) begin
                    $display("ERROR: Duplicate register %d detected at indices %d and %d at time %0t (insert=%0d, allocate=%0d)",
                             registers[i], i, j, $time, insert_index, allocate_index);
                    signal_handler(1);  // Halt simulation for debugging
                end
            end
        end
    end
end

endmodule