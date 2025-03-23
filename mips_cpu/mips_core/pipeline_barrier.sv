
module pipeline_barrier #(
    parameter WIDTH = 1
)(
    input logic clk,
    input logic rst_n,

    hazard_control_ifc.in i_hc,

    input  logic [WIDTH - 1 : 0] in,
    output logic [WIDTH - 1 : 0] out
);

always_ff @(posedge clk)
begin
    if (~rst_n || i_hc.flush) out <= '0;
    else if (!i_hc.stall)     out <= in;
end

endmodule
