
module physical_registers #(
    parameter WIDTH = 1
)(
	input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // From Hazard Controller
    input logic i_flush,

    // From (Commit stage)
    input         i_we,
    input PhysReg i_windex,
    input Data    i_wdata,

    // From (Issue stage)
    input logic   i_set_invalid_en,
    input PhysReg i_set_invalid_index,

    // (Dispatch stage) Async register reads
    input  PhysReg   i_rindex1 [WIDTH],
    input  PhysReg   i_rindex2 [WIDTH],
    output Data      o_rdata1  [WIDTH],
    output Data      o_rdata2  [WIDTH],
    output logic [PHYS_REG_COUNT-1:0] o_valid
);

    // VALID BITS
    logic [PHYS_REG_COUNT-1:0] valid;

    // PHYSICAL REGISTERS
    Data data [PHYS_REG_COUNT];


    always_comb
    begin
        o_valid  = valid;
        for (int i = 0; i < WIDTH; ++i)
        begin
            o_rdata1[i] = data[i_rindex1[i]];
            o_rdata2[i] = data[i_rindex2[i]];
        end
    end


    always_ff @(posedge clk)
    begin
        if (~rst_n)
        begin
            // Start off with every register being valid,
            //  to be able to jump start the execution,
            //  but registers will become invalid once
            //  we pick it for writing
            valid <= '1;
            for (int i = 0; i < PHYS_REG_COUNT; ++i)
                data[i] <= '0;
        end
        else if (i_flush)
        begin
            // Why do we make every physical register valid
            //  on a flush? Well, think about why a register
            //  would be invalid. A register is only invalid
            //  if there is a pending instruction that wants
            //  to write to that register. If we are flushing
            //  then all these instructions will be thrown out
            //  so making the registers valid is the same as
            //  restoring it's old value that was previously
            //  valid!
            valid <= '1;

            // From commit stage, so this must always be valid
            if (i_we) data[i_windex] <= i_wdata;
        end
        else
        begin
            // Commit stage (writing to register)
            if (i_we)
            begin
                 data[i_windex] <= i_wdata;
                valid[i_windex] <= 1'b1;

                //if (debug_level() >= 4)
                //$display("made p%0d valid!", i_windex);
            end

            // Issue stage (on dst register allocation)
            if (i_set_invalid_en)
            begin
                valid[i_set_invalid_index] <= 1'b0;

                //if (debug_level() >= 4)
                //$display("made p%0d invalid!", i_set_invalid_index);
            end
        end
    end
endmodule
