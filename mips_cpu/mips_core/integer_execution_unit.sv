
module integer_execution_unit (
    input  logic               i_valid,
    input  execution_command_t i_command,
    output logic               o_done,
    output execution_result_t  o_result
);

alu_input_ifc  in  ();
alu_output_ifc out ();

assign in.valid   = i_valid;
assign in.alu_ctl = i_command.alu_ctl;
assign in.op1     = i_command.op1;
assign in.op2     = i_command.op2;

alu ALU (
    .in,
    .out,
    .mtc0 (o_result.mtc0)
);

assign o_done           = i_valid;
assign o_result.data    = out.result;
assign o_result.outcome = out.branch_outcome;

endmodule
