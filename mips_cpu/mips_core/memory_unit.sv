module memory_unit (
    input logic clk,
    input logic rst_n,

    // Memory communication
	d_cache_input_ifc.out d_cache_input,
	input cache_output_t  d_cache_output,

    d_cache_input_ifc.in  load_input,
    output cache_output_t load_output,
    d_cache_input_ifc.in  store_input,
    output cache_output_t store_output
);

typedef struct packed {
    logic         valid;
    MemAccessType access;
    Address       addr;
    Data          data;
} memory_request_t;

// COMBINATIONAL
logic want_new_request;
logic have_new_request;
logic request_finished;
memory_request_t next_request;

// REGISTERED
memory_request_t current_request;

always_comb
begin
    request_finished = current_request.valid && d_cache_output.valid;
    want_new_request = request_finished || !current_request.valid;
end

always_comb
begin
    have_new_request = '0;

    next_request = current_request;

    if (want_new_request)
    begin
        // Check if we can do a load
        if (load_input.valid)
        begin
            next_request.valid  = load_input.valid;
            next_request.access = READ;
            next_request.addr   = load_input.addr;
            next_request.data   = load_input.data;
            have_new_request    = 1'b1;
        end
        else 
        // Check if we can do a store
        if (store_input.valid)
        begin
            next_request.valid  = store_input.valid;
            next_request.access = WRITE;
            next_request.addr   = store_input.addr;
            next_request.data   = store_input.data;
            have_new_request    = 1'b1;
        end
    end
end

always_comb
begin
    load_output  = '0;
    store_output = '0;

    // Complete the final request to the data cache
    d_cache_input.valid      = current_request.valid;
    d_cache_input.mem_action = current_request.access;
    d_cache_input.addr       = current_request.addr;
    d_cache_input.addr_next  = next_request.addr;
    d_cache_input.data       = current_request.data;

    if (current_request.valid)
    begin
        if (current_request.access == READ)
        begin
            if (load_input.addr == current_request.addr)
                load_output = d_cache_output;
        end
        else
        begin
            if (store_input.addr == current_request.addr)
                store_output = d_cache_output;
        end
    end
end

always_ff @(posedge clk)
begin
    if (~rst_n)
    begin
        current_request <= '0;
    end
    else
    begin
        if (request_finished)
        begin
            if (debug_level() >= 4)
            $display("CACHE DONE!  %s addr=%d load=%d [%d] (%b)",
                current_request.access == READ? "READ" : "WRITE",
                current_request.addr,
                load_input.addr,
                current_request.access == READ? d_cache_output.data : current_request.data,
                {load_input.valid, store_input.valid},
            );
        end

        if (want_new_request && have_new_request)
        begin
            if (debug_level() >= 4)
            if (next_request.valid)
            $display("%t| NEW REQUEST! %s addr=%d [%d] |%d|", $time,
                next_request.access == READ? "READ" : "WRITE",
                next_request.addr,
                next_request.data,
                next_request.valid,
            );
            current_request <= next_request;
        end
    end
end


endmodule