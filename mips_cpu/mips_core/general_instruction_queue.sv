module general_instruction_queue #(
    parameter COUNT = COMMIT_QUEUE_SIZE // How many instructions can we hold?
)(
	input logic clk,    // Clock
    input logic rst_n,  // Synchronous reset active low

    // From Hazard Controller
    input logic                      i_flush,

    // (Issue stage) Instruction to insert
    input logic                      i_insert_enable,
    input instruction_t              i_instruction,
    input logic [PHYS_REG_COUNT-1:0] i_register_valid,

    // (Dispatch stage) Feedback
    input logic                      i_take,

    // To Execution Unit
    output logic                     o_want_to_execute,
	output scheduler_entry_t         o_next_to_execute
);

typedef logic [$clog2(COUNT) - 1 : 0] Index;

function logic entry_ready_to_execute (input scheduler_entry_t entry);
	begin
        entry_ready_to_execute =
            (!entry.meta.uses_src1 || i_register_valid[entry.src1])
        &&  (!entry.meta.uses_src2 || i_register_valid[entry.src2]);
	end
endfunction

function logic instr_ready_to_execute (input instruction_t instruction);
	begin
        instr_ready_to_execute =
            (!instruction.meta.uses_src1 || i_register_valid[instruction.src1])
        &&  (!instruction.meta.uses_src2 || i_register_valid[instruction.src2]);
	end
endfunction

// COMBINATIONAL
Index  next_to_execute_index; // which instruction to pick next
logic  want_to_execute_incoming;
Index  insert_index; // where to place the incoming instruction
logic  printed; // DEBUG

// REGISTERED
scheduler_entry_t instruction [COUNT];
logic             occupied    [COUNT]; // set if the instruction at the same index is valid

always_comb
begin
    // Only non-memory instructions allowed
    next_to_execute_index    = '0;
    want_to_execute_incoming = '0;
    o_want_to_execute        = '0;
    printed = '0;

    for (int i = 0; i < COUNT; ++i)
    begin
        if (occupied[i] && entry_ready_to_execute(instruction[i]))
        begin
            next_to_execute_index = Index'(i);
            o_want_to_execute = '1;
            break;
        end

        //if (debug_level() >= 4)
        //if (occupied[i])
        //begin
        //    $display("%t| not able to execute instruction at {%x} (%d) waiting for %b(p%0d) %b(p%0d)", $time,
        //        instruction[i].meta.pc,
        //        instruction[i].meta.commit_index,
        //        {instruction[i].meta.uses_src1, i_register_valid[instruction[i].src1]},
        //        instruction[i].src1,
        //        {instruction[i].meta.uses_src2, i_register_valid[instruction[i].src2]},
        //        instruction[i].src2,
        //    );
        //    printed = '1;
        //end
    end

    if (!o_want_to_execute)
    begin
        if (i_insert_enable && instr_ready_to_execute(i_instruction))
        begin
            want_to_execute_incoming = '1;
            o_want_to_execute = '1;
        end
    end

    // Pick which instruction to execute next
    if (want_to_execute_incoming)
        o_next_to_execute = scheduler_entry(i_instruction);
    else
        o_next_to_execute = instruction[next_to_execute_index];

    // Find an index to store the incoming instruction
    insert_index = next_to_execute_index;
    for (int i = 0; i < COUNT; ++i)
    begin
        if (!occupied[i])
        begin
            insert_index = Index'(i);
            break;
        end
    end
end

always_ff @(posedge clk)
begin
	if(~rst_n)
	begin
        for (int i = 0; i < COUNT; ++i)
        begin
            instruction[i] <= '0;
            occupied[i]    <= '0;
        end
	end
    else if (i_flush)
    begin
        for (int i = 0; i < COUNT; ++i)
            occupied[i] <= '0;
    end
	else
	begin
        if (
            (i_insert_enable && !want_to_execute_incoming)
        ||  (i_insert_enable && want_to_execute_incoming && !i_take))
        begin
            instruction[insert_index] <= scheduler_entry(i_instruction);
            occupied[insert_index] <= 1'b1;

            //$display("%t| inserted instruction {%x} at %d (%d %d %d)", $time,
            //    i_instruction.meta.pc,
            //    insert_index,
            //    i_insert_enable,
            //    want_to_execute_incoming,
            //    i_take,
            //);
        end

        if ( // Executing from storage
            o_want_to_execute && !want_to_execute_incoming
             // instruction is being committed
        &&  i_take
             // (and) NOT filling into the entry we are executing
        &&  (!i_insert_enable || (next_to_execute_index != insert_index)))
        begin
            if (debug_level() >= 4)
            $display("%t| removing instruction at {%x}", $time,
                instruction[next_to_execute_index].meta.pc,
            );

            occupied[next_to_execute_index] <= 1'b0;
        end
	end
end

endmodule