module store_queue #(
    parameter SIZE = STORE_QUEUE_SIZE
) (
    input logic clk,
    input logic rst_n,

    // From Hazard Controller
    input logic               i_flush,

    // (Execution stage) Store operation
    input opt_memory_write_t  i_memory_write,
    output logic              o_able_to_insert,

    // (Execution stage) Load forwarding
    load_forward_ifc.in       load_forward,

    // (Commit stage) Ready to evict
    input logic               i_want_evict,

    // (Commit stage) Store request
    d_cache_input_ifc.out     o_request,
    input cache_output_t      i_response
);

/*
    ------ Store Queue Illustration ------

+-----|-|-------------------------------|-|----------+
| /// | |        [empty entries]        | | //////// |
+-----|-|-------------------------------|-|----------+
       ^ insert_index                    ^ remove_index

After some insertions ...

+-----|-|-|-|---------------------------|-|----------+
| ////| |~| |      [emtpy entries]      | |  /////// |
+-----|-|-|-|---------------------------|-|----------+
       ^   ^ insert_index                ^ remove_index
       |
       \ evict_index

*/

typedef logic [$clog2(SIZE)-1:0] Index;

typedef struct packed {
    logic   occupied; // All inserted writes start off as occupied
    logic   valid;    // Overwritten writes become invalidated
    logic   evict;    // 
    Address addr;
    Data    data;
} entry_t;

function entry_t new_entry (input opt_memory_write_t write);
    begin
        new_entry.occupied = 1'b1;
        new_entry.valid    = 1'b1;
        new_entry.evict    = 1'b0;
        new_entry.addr     = write.addr;
        new_entry.data     = write.data;
    end
endfunction

// COMBINATIONAL
Index request_index;
logic want_to_remove;
logic has_duplicate_store;

// REGISTERED
entry_t entries [SIZE];
Index insert_index;
Index evict_index;
Index remove_index;
logic full;

/*always_comb
begin
    has_duplicate_store = '0;

    for (int i = 0; i < SIZE; ++i)
    begin
        if (entries[i].valid && entries[i].addr == i_memory_write.addr)
        begin
            has_duplicate_store = '1;
            $display("%d - %d", entries[i].data, i_memory_write.data);
            signal_handler(1);
        end
    end
end*/

// Request to Memory Unit
always_comb
begin
    request_index = remove_index; // always request WRITE using oldest entry 
    
    o_request.mem_action = WRITE;
    o_request.valid      = entries[request_index].valid && entries[request_index].evict;
    o_request.addr       = entries[request_index].addr;
    o_request.addr_next  = entries[request_index].addr;
    o_request.data       = entries[request_index].data;
end

assign want_to_remove =
    (i_response.valid && entries[remove_index].valid && entries[remove_index].evict)
||  (entries[remove_index].occupied && !entries[remove_index].valid && entries[remove_index].evict);
assign o_able_to_insert = !full || want_to_remove;

// Load forwarding
always_comb
begin
    load_forward.data_valid = 1'b0;
    load_forward.data       = '0;

    for (int i = 0; i < SIZE; ++i)
    begin
        if (entries[i].valid && load_forward.addr == entries[i].addr)
        begin
            load_forward.data_valid = 1'b1;
            load_forward.data       = entries[i].data;
            break;
        end
    end
end

always_ff @(posedge clk)
begin
    if (~rst_n)
    begin
        for (int i = 0; i < SIZE; ++i)
            entries[i] <= '0;

        insert_index  <= '0;
        evict_index   <= '0;
        remove_index  <= '0;
        full          <= '0;
    end
    else if (i_flush)
    begin
        // no longer full?
        if (evict_index != remove_index)
            full <= 1'b0;

        insert_index <= evict_index;
    end
    else
    begin
        if (i_memory_write.valid && o_able_to_insert)
        begin
            if (!want_to_remove && insert_index + Index'(1) == remove_index)
                full <= 1'b1;

            if (debug_level() >= 3)
            $display("%t| inserted into store queue! (%d):%d (addr=%x, data=%d)", $time,
                insert_index,
                remove_index,
                i_memory_write.addr,
                i_memory_write.data,
            );

            entries[insert_index] <= new_entry(i_memory_write);
            insert_index <= insert_index + Index'(1);

            if (insert_index + Index'(1) == evict_index)
            begin
                $display("NOOOOO!!! :(");
            end

            // Mark all duplicate stores as invalid
            for (int i = 0; i < SIZE; ++i)
            begin
                if (insert_index != Index'(i) && entries[i].addr == i_memory_write.addr)
                begin
                    entries[i].valid <= 1'b0;
                end
            end
        end

        if (i_want_evict)
        begin
            if (!entries[evict_index].occupied)
            begin
                $display("EVICT ERROR");
                signal_handler(1);
            end

            entries[evict_index].evict <= 1'b1;
            evict_index <= evict_index + Index'(1);
        end

        if (want_to_remove)
        begin
            if (!i_memory_write.valid && full)
                full <= 1'b0;

            if (debug_level() >= 3)
            $display("%t| removed last entry in store queue! (%d) |%d|", $time,
                remove_index,
                o_request.valid,
            );

            if (i_memory_write.valid && o_able_to_insert && full)
            begin
            end
            else
            begin
                entries[remove_index].occupied <= 1'b0;
                entries[remove_index].valid    <= 1'b0;
            end

            remove_index <= remove_index + Index'(1);
        end

        if (debug_level() >= 3)
        $display("%t| CURRENT store queue request! (%d) occupied=%b valid=%b evict=%b addr=%d data=%d", $time,
            remove_index,
            entries[remove_index].occupied,
            entries[remove_index].valid,
            entries[remove_index].evict,
            entries[remove_index].addr,
            entries[remove_index].data,
        );
    end
end

endmodule