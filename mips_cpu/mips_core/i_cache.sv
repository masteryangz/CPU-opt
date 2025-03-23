/*
 * i_cache.sv
 * Author: Zinsser Zhang 
 * Revision : Sankara 			
 * Last Revision: 04/04/2023
 *
 * This is a direct-mapped instruction cache. Line size and depth (number of
 * lines) are set via INDEX_WIDTH and BLOCK_OFFSET_WIDTH parameters. Notice that
 * line size means number of words (each consist of 32 bit) in a line. Because
 * all addresses in mips_core are 26 byte addresses, so the sum of TAG_WIDTH,
 * INDEX_WIDTH and BLOCK_OFFSET_WIDTH is `ADDR_WIDTH - 2.
 *
 * Typical line sizes are from 2 words to 8 words. The memory interfaces only
 * support up to 8 words line size.
 *
 * Because we need a hit latency of 1 cycle, we need an asynchronous read port,
 * i.e. data is ready during the same cycle when address is calculated. However,
 * SRAMs only support synchronous read, i.e. data is ready the cycle after the
 * address is calculated. Due to this conflict, we need to read from the banks
 * on the clock edge at the beginning of the cycle. As a result, we need both
 * the registered version of address and a non-registered version of address
 * (which will effectively be registered in SRAM).
 *
 * See wiki page "Synchronous Caches" for details.
 */
 import mips_core_pkg::*;

// ##############################################################
//   Using baseline with 2bit counter branch prediction

//   1way (direct)    | CPI: 19.9006 IPC: 0.0502496
//   2way             | CPI: 17.5574 IPC: 0.056956
//   1way 7-bit index | CPI: 6.4977  IPC: 0.153901
//   2way 6-bit index | CPI: 5.83342 IPC: 0.171426
//   1way 5-bit index | CPI: 13.8125 IPC: 0.0723983
//        3-bit width
// ##############################################################

//`define USE_ASSOCIATIVE_I_CACHE

`ifdef USE_ASSOCIATIVE_I_CACHE
module i_cache #(
    parameter INDEX_WIDTH = 5, // 1 KB Cahe size 
    parameter BLOCK_OFFSET_WIDTH = 2,
    parameter ASSOCIATIVITY = 2
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    input Address i_pc_current,
    input Address i_pc_next,

    // Response
    output cache_output_t out,

    // Memory interface
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);
    localparam TAG_WIDTH = ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
    localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
    localparam DEPTH = 1 << INDEX_WIDTH;

    // Check if the parameters are set correctly
    generate
        if(TAG_WIDTH <= 0 || LINE_SIZE > 16)
        begin
            INVALID_I_CACHE_PARAM invalid_i_cache_param ();
        end
    endgenerate

    // Parsing
    logic [TAG_WIDTH - 1 : 0] i_tag;
    logic [INDEX_WIDTH - 1 : 0] i_index;
    logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;

    logic [INDEX_WIDTH - 1 : 0] i_index_next;

    assign {i_tag, i_index, i_block_offset} = i_pc_current[ADDR_WIDTH - 1 : 2];
    assign i_index_next = i_pc_next[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
    // Above line uses +: slice, a feature of SystemVerilog
    // See https://stackoverflow.com/questions/18067571

    // States
    enum logic[1:0] {
        STATE_READY,            // Ready for incoming requests
        STATE_REFILL_REQUEST,   // Sending out a memory read request
        STATE_REFILL_DATA       // Missing on a read
    } state, next_state;

    // Registers for refilling
    logic [INDEX_WIDTH - 1:0] r_index;
    logic [TAG_WIDTH - 1:0] r_tag;

    // databank signals
    logic [LINE_SIZE - 1 : 0] databank_select;
    logic [LINE_SIZE - 1 : 0] databank_we [ASSOCIATIVITY];
    logic [DATA_WIDTH - 1 : 0] databank_wdata;
    logic [INDEX_WIDTH - 1 : 0] databank_waddr;
    logic [INDEX_WIDTH - 1 : 0] databank_raddr;
    logic [DATA_WIDTH - 1 : 0] databank_rdata [ASSOCIATIVITY][LINE_SIZE];

    // databanks
    genvar g,s;
    generate
        for (g = 0; g < LINE_SIZE; g++)
        begin : datasets
            for (s = 0; s < ASSOCIATIVITY; s++)
            begin : databanks
                cache_bank #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .ADDR_WIDTH (INDEX_WIDTH)
                ) databank (
                    .clk,
                    .i_we (databank_we[s][g]),
                    .i_wdata(databank_wdata),
                    .i_waddr(databank_waddr),
                    .i_raddr(databank_raddr),

                    .o_rdata(databank_rdata[s][g])
                );
            end
        end
    endgenerate

    // tagbank signals
    logic tagbank_we [ASSOCIATIVITY];
    logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
    logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
    logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
    logic [TAG_WIDTH - 1 : 0] tagbank_rdata [ASSOCIATIVITY];

    // tagbanks
    generate
        for (s = 0; s < ASSOCIATIVITY; ++s)
        begin : tagsets
            cache_bank #(
                .DATA_WIDTH (TAG_WIDTH),
                .ADDR_WIDTH (INDEX_WIDTH)
            ) tagbank (
                .clk,
                .i_we    (tagbank_we[s]),
                .i_wdata (tagbank_wdata),
                .i_waddr (tagbank_waddr),
                .i_raddr (tagbank_raddr),

                .o_rdata (tagbank_rdata[s])
            );
        end
    endgenerate

    // Valid bits
    logic [DEPTH - 1 : 0] valid_bits [ASSOCIATIVITY];

    // Intermediate signals
    logic hit, miss, tag_hit;
    logic last_refill_word;
    logic block_select [ASSOCIATIVITY];
    
    localparam ASSOCIATIVITY_DEPTH = $clog2(ASSOCIATIVITY); 

    logic [ASSOCIATIVITY_DEPTH - 1:0] select_way;
    logic r_select_way;
    logic [DEPTH - 1 : 0] lru_rp;

    always_comb
    begin

        tag_hit = 0;

        for (int i = 0; i < ASSOCIATIVITY; ++i)
            tag_hit = tag_hit | (valid_bits[i][i_index] & (i_tag == tagbank_rdata[i]));

        hit = (tag_hit)
            & (state == STATE_READY);
        miss = ~hit;
        last_refill_word = databank_select[LINE_SIZE - 1]
            & mem_read_data.RVALID;
            
        if (hit)
        begin
            select_way = 'b0;
            
            if (i_tag == tagbank_rdata[0])
            begin
                select_way = 'b0;
            end
            else
            begin
                select_way = 'b1;
            end
        end
        else
        begin
            select_way = lru_rp[i_index]; // way is whichever was least recently used
        end
    end

    always_comb
    begin
        mem_read_address.ARADDR = {r_tag, r_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
        mem_read_address.ARLEN = LINE_SIZE;
        mem_read_address.ARVALID = state == STATE_REFILL_REQUEST;
        mem_read_address.ARID = 4'd0;

        // Always ready to consume data
        mem_read_data.RREADY = 1'b1;
    end

    always_comb
    begin
        // start with all writing disabled
        for (int i=0; i<ASSOCIATIVITY;i++)
            databank_we[i] = '0;

        if (mem_read_data.RVALID) // We are refilling data
            databank_we[r_select_way] = databank_select;

        databank_wdata = mem_read_data.RDATA;
        databank_waddr = r_index;
        databank_raddr = i_index_next;
    end

    always_comb
    begin
        tagbank_we[r_select_way] = last_refill_word;
        tagbank_we[~r_select_way] = '0;
        tagbank_wdata = r_tag;
        tagbank_waddr = r_index;
        tagbank_raddr = i_index_next;
    end

    always_comb
    begin
        out.valid = hit;
        out.data = databank_rdata[select_way][i_block_offset];
    end

    always_comb
    begin
        next_state = state;
        unique case (state)
            STATE_READY:
                if (miss)
                    next_state = STATE_REFILL_REQUEST;
            STATE_REFILL_REQUEST:
                if (mem_read_address.ARREADY)
                    next_state = STATE_REFILL_DATA;
            STATE_REFILL_DATA:
                if (last_refill_word)
                    next_state = STATE_READY;
        endcase
    end

    always_ff @(posedge clk)
    begin
        if(~rst_n)
        begin
            state <= STATE_READY;
            databank_select <= 1;

            for (int i = 0; i < ASSOCIATIVITY; ++i)
                valid_bits[i] <= '0;
        end
        else
        begin
            state <= next_state;

            case (state)
                default: begin end
                STATE_READY:
                begin
                    if (miss)
                    begin
                        r_tag <= i_tag;
                        r_index <= i_index;
                        r_select_way <= select_way;
                    end

                    // Need to set the way we did not select, as the one Least Recently Used
                    lru_rp[i_index] <= ~select_way;
                end
                STATE_REFILL_REQUEST:
                begin
                end
                STATE_REFILL_DATA:
                begin
                    if (mem_read_data.RVALID)
                    begin
                        databank_select <= {databank_select[LINE_SIZE - 2 : 0],
                            databank_select[LINE_SIZE - 1]};
                        valid_bits[r_select_way][r_index] <= last_refill_word;
                    end
                end
            endcase
        end
    end
endmodule

module i_cache_prefetch #(
    parameter INDEX_WIDTH = 6,
    parameter BLOCK_OFFSET_WIDTH = 3,
    parameter TAG_WIDTH = 16,
    parameter ADDR_WIDTH = 32
) (
    input logic clk,
    input logic rst,
    input logic [ADDR_WIDTH-1:0] addr,
    input logic read_req,
    output Address instr,
    output logic hit,
    output logic prefetch_valid
);

    localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;

    logic Address cache_mem [0:(1 << INDEX_WIDTH)-1][0:LINE_SIZE-1];
    logic [TAG_WIDTH-1:0] tags [0:(1 << INDEX_WIDTH)-1];
    logic valid_bits [0:(1 << INDEX_WIDTH)-1];

    logic Address prefetch_buffer [0:1]; // Prefetch buffer for next instruction
    logic [ADDR_WIDTH-1:0] prefetch_addr;
    logic prefetch_ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            prefetch_ready <= 0;
        end else if (read_req) begin
            logic [TAG_WIDTH-1:0] tag = addr[ADDR_WIDTH-1:INDEX_WIDTH + BLOCK_OFFSET_WIDTH];
            logic [INDEX_WIDTH-1:0] index = addr[INDEX_WIDTH + BLOCK_OFFSET_WIDTH - 1:BLOCK_OFFSET_WIDTH];
            logic [BLOCK_OFFSET_WIDTH-1:0] offset = addr[BLOCK_OFFSET_WIDTH-1:0];

            if (valid_bits[index] && tags[index] == tag) begin
                instr <= cache_mem[index][offset];
                hit <= 1;
            end else begin
                instr <= prefetch_buffer[0]; // Use prefetched instruction if available
                hit <= prefetch_ready;
            end
            
            // Update prefetch logic
            prefetch_addr <= addr + 4; // Sequential prefetch
            prefetch_ready <= 1;
        end
    end

    // Branch Target Buffer (BTB) based Prefetch
    logic [ADDR_WIDTH-1:0] branch_targets [0:15]; // Small BTB
    logic [3:0] branch_index;

    always_ff @(posedge clk) begin
        if (read_req) begin
            // Check BTB for branch prediction
            branch_index = addr[4:1]; // Simple indexing scheme
            if (branch_targets[branch_index] != 0) begin
                prefetch_addr <= branch_targets[branch_index]; // Prefetch from predicted branch target
            end
        end
    end

    assign prefetch_valid = prefetch_ready;

endmodule

`else

module i_cache #(
    parameter INDEX_WIDTH = 6, // 1 KB Cahe size 
    parameter BLOCK_OFFSET_WIDTH = 2
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    input Address i_pc_current,
    input Address i_pc_next,

    // Response
    output cache_output_t out,

    // Memory interface
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);
    localparam TAG_WIDTH = ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
    localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
    localparam DEPTH = 1 << INDEX_WIDTH;

    // Check if the parameters are set correctly
    generate
        if(TAG_WIDTH <= 0 || LINE_SIZE > 16)
        begin
            INVALID_I_CACHE_PARAM invalid_i_cache_param ();
        end
    endgenerate

    // Parsing
    logic [TAG_WIDTH - 1 : 0] i_tag;
    logic [INDEX_WIDTH - 1 : 0] i_index;
    logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;

    logic [INDEX_WIDTH - 1 : 0] i_index_next;

    assign {i_tag, i_index, i_block_offset} = i_pc_current[ADDR_WIDTH - 1 : 2];
    assign i_index_next = i_pc_next[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
    // Above line uses +: slice, a feature of SystemVerilog
    // See https://stackoverflow.com/questions/18067571

    // States
    enum logic[1:0] {
        STATE_READY,            // Ready for incoming requests
        STATE_REFILL_REQUEST,   // Sending out a memory read request
        STATE_REFILL_DATA       // Missing on a read
    } state, next_state;

    // Registers for refilling
    logic [INDEX_WIDTH - 1:0] r_index;
    logic [TAG_WIDTH - 1:0] r_tag;

    // databank signals
    logic [LINE_SIZE - 1 : 0] databank_select;
    logic [LINE_SIZE - 1 : 0] databank_we;
    logic [DATA_WIDTH - 1 : 0] databank_wdata;
    logic [INDEX_WIDTH - 1 : 0] databank_waddr;
    logic [INDEX_WIDTH - 1 : 0] databank_raddr;
    logic [DATA_WIDTH - 1 : 0] databank_rdata [LINE_SIZE];

    // databanks
    genvar g;
    generate
        for (g = 0; g < LINE_SIZE; g++)
        begin : databanks
            cache_bank #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (INDEX_WIDTH)
            ) databank (
                .clk,
                .i_we (databank_we[g]),
                .i_wdata(databank_wdata),
                .i_waddr(databank_waddr),
                .i_raddr(databank_raddr),

                .o_rdata(databank_rdata[g])
            );
        end
    endgenerate

    // tagbank signals
    logic tagbank_we;
    logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
    logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
    logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
    logic [TAG_WIDTH - 1 : 0] tagbank_rdata;

    cache_bank #(
        .DATA_WIDTH (TAG_WIDTH),
        .ADDR_WIDTH (INDEX_WIDTH)
    ) tagbank (
        .clk,
        .i_we    (tagbank_we),
        .i_wdata (tagbank_wdata),
        .i_waddr (tagbank_waddr),
        .i_raddr (tagbank_raddr),

        .o_rdata (tagbank_rdata)
    );

    // Valid bits
    logic [DEPTH - 1 : 0] valid_bits;

    // Intermediate signals
    logic hit, miss;
    logic last_refill_word;


    always_comb
    begin
        hit = valid_bits[i_index]
            & (i_tag == tagbank_rdata)
            & (state == STATE_READY);
        miss = ~hit;
        last_refill_word = databank_select[LINE_SIZE - 1]
            & mem_read_data.RVALID;
    end

    always_comb
    begin
        mem_read_address.ARADDR = {r_tag, r_index,
            {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
        mem_read_address.ARLEN = LINE_SIZE;
        mem_read_address.ARVALID = state == STATE_REFILL_REQUEST;
        mem_read_address.ARID = 4'd0;

        // Always ready to consume data
        mem_read_data.RREADY = 1'b1;
    end

    always_comb
    begin
        if (mem_read_data.RVALID)
            databank_we = databank_select;
        else
            databank_we = '0;

        databank_wdata = mem_read_data.RDATA;
        databank_waddr = r_index;
        databank_raddr = i_index_next;
    end

    always_comb
    begin
        tagbank_we = last_refill_word;
        tagbank_wdata = r_tag;
        tagbank_waddr = r_index;
        tagbank_raddr = i_index_next;
    end

    always_comb
    begin
        out.valid = hit;
        out.data = databank_rdata[i_block_offset];
    end

    always_comb
    begin
        next_state = state;
        unique case (state)
            STATE_READY:
                if (miss)
                    next_state = STATE_REFILL_REQUEST;
            STATE_REFILL_REQUEST:
                if (mem_read_address.ARREADY)
                    next_state = STATE_REFILL_DATA;
            STATE_REFILL_DATA:
                if (last_refill_word)
                    next_state = STATE_READY;
        endcase
    end

    always_ff @(posedge clk)
    begin
        if(~rst_n)
        begin
            state <= STATE_READY;
            databank_select <= 1;
            valid_bits <= '0;
        end
        else
        begin
            state <= next_state;

            unique case (state)
                STATE_READY:
                begin
                    if (miss)
                    begin
                        r_tag <= i_tag;
                        r_index <= i_index;
                    end
                end
                STATE_REFILL_REQUEST:
                begin
                end
                STATE_REFILL_DATA:
                begin
                    if (mem_read_data.RVALID)
                    begin
                        databank_select <= {databank_select[LINE_SIZE - 2 : 0],
                            databank_select[LINE_SIZE - 1]};
                        valid_bits[r_index] <= last_refill_word;
                    end
                end
            endcase
        end
    end
endmodule
`endif