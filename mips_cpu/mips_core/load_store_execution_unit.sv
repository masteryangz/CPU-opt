module load_store_execution_unit (
	input  logic              i_valid,
	input  memory_command_t   i_command,
	output logic              o_done,
	output execution_result_t o_result,
	
    // Store queue
    output opt_memory_write_t o_memory_write,
    input logic               i_wrote,
    load_forward_ifc.out      load_forward,

    // D-Cache communication
    input cache_output_t     i_response,
    d_cache_input_ifc.out    o_request
);

// LOAD
// -> send read request to memory unit
// -> done when we response is valid
// STORE
// -> write (addr, data) into store queue
// -> done same cycle

alu_input_ifc  in  ();
alu_output_ifc out ();

assign in.valid   = i_valid;
assign in.alu_ctl = ALUCTL_ADD;
assign in.op1     = i_command.op1;
assign in.op2     = i_command.op2;

alu ALU (
    .in,
    .out,
    .mtc0 ()
);

Address memory_address;

assign memory_address = Address'(out.result);

always_comb
begin
    o_request.valid      = '0;
    o_request.mem_action = READ;
    o_request.addr       = '0;
    o_request.addr_next  = '0;
    o_request.data       = '0;
    o_result.data        = '0;
    o_result.outcome     = NOT_TAKEN; // Not used
    o_result.mtc0        = '0; // Not used
    o_memory_write       = '0;
    o_done               = '0;

    // See if we can get some forwarding action going
    load_forward.addr_valid = i_command.access == READ;
    load_forward.addr       = memory_address;

    if (i_valid)
    begin
        if (i_command.access == READ)
        begin
            o_request.valid      = 1'b1;
            o_request.mem_action = READ;
            o_request.addr       = memory_address;
            o_request.addr_next  = memory_address;
            o_request.data       = '0; // No used

            //if (debug_level() >= 5)
            //$display("want to read from addr=%d %d(%d) %d(%d)", memory_address,
            //    load_forward.data_valid, load_forward.data,
            //    i_response.valid, i_response.data,
            //);

            if (load_forward.data_valid)
            begin
                o_done        = 1'b1; // If forward data is valid, then we are done!
                o_result.data = load_forward.data;
            end
            else
            begin
                o_done        = i_response.valid;
                o_result.data = i_response.data;

                //if (i_response.valid)
                //$display("read from memory at (addr=%x, data=%d)", o_request.addr, i_response.data);
            end
        end
        else if (i_command.access == WRITE)
        begin
            o_memory_write.valid = 1'b1;
            o_memory_write.addr  = memory_address;
            o_memory_write.data  = i_command.data;
            o_done = i_wrote;
        end
    end
end

endmodule