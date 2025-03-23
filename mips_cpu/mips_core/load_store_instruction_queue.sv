module load_store_instruction_queue #(
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
logic want_to_execute_incoming;
Index next_index;

// TODO(mitch): Replace occupied with 1-bit `full` register

// REGISTERED
scheduler_entry_t instruction [COUNT];
logic             occupied    [COUNT]; // set if the instruction at the same index is valid
Index insert_index;
Index execute_index;
Index back_index;
logic r_move;

assign next_index = execute_index + Index'(1);

always_comb
begin
    want_to_execute_incoming = 1'b0;
    o_want_to_execute = occupied[execute_index] && entry_ready_to_execute(instruction[execute_index]);

    if (!o_want_to_execute)
    begin
        if (i_insert_enable && instr_ready_to_execute(i_instruction))
        begin
            want_to_execute_incoming  = 1'b1;
            o_want_to_execute = 1'b1;
        end
    end

    if (want_to_execute_incoming)
        o_next_to_execute = scheduler_entry(i_instruction);
    else
        o_next_to_execute = instruction[execute_index];

    if (debug_level() >= 4)
    $display("Want to execute instruction {%x} (%d) %b %b(p%0d) %b(p%0d)",
        o_next_to_execute.meta.pc,
        execute_index,
        occupied[execute_index],
        {instruction[execute_index].meta.uses_src1, i_register_valid[instruction[execute_index].src1]},
        instruction[execute_index].src1,
        {instruction[execute_index].meta.uses_src2, i_register_valid[instruction[execute_index].src2]},
        instruction[execute_index].src2,
    );
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
        insert_index <= '0;
        execute_index <= '0;

        back_index <= '0;
        r_move     <= '0;
	end
    else if (i_flush)
    begin
        for (int i = 0; i < COUNT; ++i)
            occupied[i] <= '0;
        insert_index  <= '0;
        execute_index <= '0;
        back_index <= '0;
        r_move     <= '0;
    end
	else
	begin
        if (
            (i_insert_enable && !want_to_execute_incoming)
        ||  (i_insert_enable && want_to_execute_incoming && !i_take))
        begin
            instruction [insert_index] <= scheduler_entry(i_instruction);
            occupied    [insert_index] <= 1'b1;
            insert_index <= insert_index + Index'(1);
            
            if (debug_level() >= 5)
            $display("%t| inserted {%x} into load-store queue at %d", $time,
                i_instruction.meta.pc,
                insert_index,
            );
        end

        if ( // Executing from storage
            o_want_to_execute && !want_to_execute_incoming
             // instruction is being committed
        &&  i_take)
        begin
        `ifdef NON_BLOCKING
            if (back_index != execute_index) // case 1: Need swap
            begin
            //    $display("INVALID %d %d", execute_index, back_index);
            //    signal_handler(1);
                instruction[execute_index] <= instruction[back_index];
            end

            occupied[back_index] <= 1'b0;
            execute_index <= back_index + Index'(1);
            back_index    <= back_index + Index'(1);
        `else
            occupied[execute_index] <= 1'b0;
            execute_index <= execute_index + Index'(1);
        `endif

            if (debug_level() >= 5)
            $display("%t| removed {%x} into load-store queue at %d", $time,
                instruction[execute_index].meta.pc,
                execute_index,
            );
        end
    `ifdef NON_BLOCKING
        // When we are stuck on a instruction we "o_want_to_execute" from storage
        //   -> look at the next instruction
        //       ~occupied          -> goto back_index
        //        occupied & ready  -> goto execute_index + 1
        //            -> (BUT) if instruction[execute_index] is STORE -> goto back_index
        //        occupied & !ready -> goto back_index
        else if (o_want_to_execute && !want_to_execute_incoming)
        begin
            if (r_move)
            begin
                if (occupied[next_index]
                && entry_ready_to_execute(instruction[next_index])
                && (instruction[execute_index].meta.mem_action == READ)
                //&& (instruction[next_index].meta.mem_action == READ)
                )
                begin
                    execute_index <= execute_index + Index'(1);
                //    $display("Moving to next instruction!");
                end
                else
                begin
                    execute_index <= back_index;
                //    $display("Moving to back to first instruction!");
                end
            end
            r_move <= ~r_move;
        end
    `endif
    end
end

endmodule