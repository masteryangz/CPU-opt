/*
 * d_cache.sv
 * Author: Zinsser Zhang
 * Revision : Sankara 			
 * Last Revision: 04/04/2023
 *
 * This is a 2-way set associative data cache. Line size and depth (number of lines) are
 * set via INDEX_WIDTH and BLOCK_OFFSET_WIDTH parameters. Notice that line size
 * means number of words (each consist of 32 bit) in a line. Because all
 * addresses in mips_core are 26 byte addresses, so the sum of TAG_WIDTH,
 * INDEX_WIDTH and BLOCK_OFFSET_WIDTH is ADDR_WIDTH - 2.
 * The ASSOCIATIVITY is fixed at 2 because of the replacement policy. The replacement
 * policy also needs changes when changing the ASSOCIATIVITY 
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

`ifdef NON_BLOCKING
module d_cache #(
	parameter INDEX_WIDTH        = 6,
	parameter BLOCK_OFFSET_WIDTH = 2,
	parameter ASSOCIATIVITY      = 2,
	parameter WRITER_COUNT       = 1,
	parameter READER_COUNT       = 8
)(
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	d_cache_input_ifc.in in,

	// Response
	output cache_output_t out,

	// AXI interfaces
	axi_write_address.master  mem_write_address  [WRITER_COUNT],
	axi_write_data.master     mem_write_data     [WRITER_COUNT],
	axi_write_response.master mem_write_response, // what is this??
	axi_read_address.master   mem_read_address   [READER_COUNT],
	axi_read_data.master      mem_read_data      [READER_COUNT]
);

`define DEBUG if ('0) $display
//`define DEBUG $display

localparam TAG_WIDTH = ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
localparam DEPTH     = 1 << INDEX_WIDTH;

// Check if the parameters are set correctly
generate
	if(TAG_WIDTH <= 0 || LINE_SIZE > 16)
	begin
		INVALID_D_CACHE_PARAM invalid_d_cache_param ();
	end
endgenerate

`define GET_INDEX     [BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH]
`define GET_TAG_INDEX [BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH + TAG_WIDTH]

// Reader input
logic [READER_COUNT - 1 : 0] reader_request;
logic [READER_COUNT - 1 : 0] read_clobber;
Address read_addr;

// Writer input
logic   writer_request [WRITER_COUNT];
Address writer_addr    [WRITER_COUNT];
Data    writer_data    [WRITER_COUNT][LINE_SIZE];

// Reader output
logic [READER_COUNT - 1 : 0] reader_ready; 
logic   reader_valid [READER_COUNT];
Data    reader_data  [READER_COUNT][LINE_SIZE];   
Address reader_addr  [READER_COUNT];

// Writer output
Address writer_o_addr [WRITER_COUNT];
logic   writer_ready  [WRITER_COUNT];
logic   writer_valid  [WRITER_COUNT];

// databank signals
logic [LINE_SIZE   - 1 : 0] databank_we[ASSOCIATIVITY];
logic [DATA_WIDTH  - 1 : 0] databank_wdata [LINE_SIZE];
logic [INDEX_WIDTH - 1 : 0] databank_waddr;
logic [INDEX_WIDTH - 1 : 0] databank_raddr;
Data                        databank_rdata [ASSOCIATIVITY][LINE_SIZE];

// tagbank signals
logic                       tagbank_we [ASSOCIATIVITY];
logic [TAG_WIDTH - 1 : 0]   tagbank_wdata;
logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
logic [TAG_WIDTH - 1 : 0]   tagbank_rdata[ASSOCIATIVITY];

logic [DEPTH - 1 : 0] lru_rp;

// Intermediate
logic [TAG_WIDTH - 1 : 0]          i_tag;
logic [INDEX_WIDTH - 1 : 0]        i_index;
logic [INDEX_WIDTH - 1 : 0]        i_index_next;
logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;
logic [READER_COUNT - 1 : 0]       read_shift_register;
logic select_way;
Data selected_reader_data [LINE_SIZE];
assign {i_tag, i_index, i_block_offset} = in.addr[ADDR_WIDTH - 1 : 2];
assign i_index_next = in.addr_next[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
logic reader_has_data;
logic refill;
logic want_read_request;
Address r_debug;
logic r_write_pending;
logic r_write_select_way;
logic [INDEX_WIDTH - 1 : 0] r_write_index;
logic [TAG_WIDTH - 1 : 0]   r_write_tag;

assign mem_write_response.BREADY = '1;

genvar a;
generate
	for (a = 0; a < WRITER_COUNT; a++)
	begin : writers
		memory_writer #(.BLOCK_OFFSET_WIDTH, .LINE_SIZE, .ID(a)) writer (
			.clk, .rst_n,
			.mem_write_address ( mem_write_address [a] ),
			.mem_write_data    ( mem_write_data    [a] ),
			.i_request         ( writer_request    [a] ),
			.i_addr            ( writer_addr       [a] ),
			.i_data            ( writer_data       [a] ),
			.o_ready           ( writer_ready      [a] ),
			.o_valid           ( writer_valid      [a] ),
			.o_addr            ( writer_o_addr     [a] )
		);
	end
endgenerate
	
genvar b;
generate
	for (b = 0; b < READER_COUNT; b++)
	begin : readers
		memory_reader #(.BLOCK_OFFSET_WIDTH, .LINE_SIZE, .ID(1+b)) reader (
			.clk, .rst_n,
			.mem_read_address ( mem_read_address [b] ),
			.mem_read_data    ( mem_read_data    [b] ),
			.i_request        ( reader_request   [b] ),
			.i_addr           ( read_addr            ),
			.i_clobber        ( read_clobber     [b] ),
			.o_ready          ( reader_ready     [b] ),
			.o_done           ( reader_valid     [b] ),
			.o_data           ( reader_data      [b] ),
			.o_addr           ( reader_addr      [b] )
		);
	end
endgenerate

// databanks
genvar g,w;
generate
	for (g = 0; g < LINE_SIZE; g++)
	begin : datasets
		for (w=0; w< ASSOCIATIVITY; w++)
		begin : databanks
			cache_bank #(
				.DATA_WIDTH (DATA_WIDTH),
				.ADDR_WIDTH (INDEX_WIDTH)
			) databank (
				.clk,
				.i_we    ( databank_we[w][g]    ),
				.i_wdata ( databank_wdata[g]    ),
				.i_waddr ( databank_waddr       ),
				.i_raddr ( databank_raddr       ),
				.o_rdata ( databank_rdata[w][g] )
			);
		end
	end
endgenerate

generate
	for (w=0; w< ASSOCIATIVITY; w++)
	begin: tagbanks
		cache_bank #(
			.DATA_WIDTH (TAG_WIDTH),
			.ADDR_WIDTH (INDEX_WIDTH)
		) tagbank (
			.clk,
			.i_we    ( tagbank_we[w]    ),
			.i_wdata ( tagbank_wdata    ),
			.i_waddr ( tagbank_waddr    ),
			.i_raddr ( tagbank_raddr    ),
			.o_rdata ( tagbank_rdata[w] )
		);
	end
endgenerate

	logic [DEPTH - 1 : 0] valid_bits[ASSOCIATIVITY];
	logic [DEPTH - 1 : 0] dirty_bits[ASSOCIATIVITY];

	// Intermediate signals
	logic hit, miss, tag_hit;
	logic evict;

	always_comb
	begin
		tag_hit = ( ((i_tag == tagbank_rdata[0]) & valid_bits[0][i_index])
				  |	((i_tag == tagbank_rdata[1]) & valid_bits[1][i_index]));
		hit = in.valid
			& (tag_hit);
		miss = in.valid & ~hit;
	
		if (hit)
		begin
			if (i_tag == tagbank_rdata[0])
			begin
				select_way = 'b0;
			end
			else 
			begin
				select_way = 'b1;
			end
		end
		else if (miss)
		begin
			select_way = lru_rp[i_index];
		end
		else
		begin
			select_way = 'b0;
		end

		evict = miss & valid_bits[select_way][i_index] & dirty_bits[select_way][i_index];
	end

	// Miss:
	//   case 1: Want to refill into invalid slot
	//      1: look for the address in readers
	//      2: if found ->
	//             if ready -> write to data cache at invalid slot using reader data
	//             else     -> do nothing
	//         else     ->
	//             if next reader is ready -> send read request
	//             else                    -> do nothing
	//   case 2: Want to refill into valid slot
	//      1: same as (case 1) but do NOT write to valid slot, wait to become invalid 
	//
	// Always:
	// 	  look at all writers, select first one that is done, mark corresponding cache slot as invalid

	always_comb
	begin
		reader_has_data = '0;

		// defualt to hit
		for (int i = 0; i < LINE_SIZE; ++i)
			databank_wdata[i] = in.data;

		if (miss)
		begin
			for (int i = 0; i < READER_COUNT; ++i)
			begin
				// reader data is valid
				if (reader_valid[i])
				// reader has a matching tag and index
				if (reader_addr[i] `GET_TAG_INDEX == {i_tag, i_index})
				begin
					databank_wdata = reader_data[i];
					reader_has_data = '1;
					break;
				end
			end
		end

		refill = miss & (~valid_bits[select_way][i_index] | ~dirty_bits[select_way][i_index]) & reader_has_data;
		
		want_read_request = '1;

		for (int i = 0; i < READER_COUNT; ++i)
		begin
			// reader has a matching tag and index
			if (reader_addr[i] `GET_TAG_INDEX == {i_tag, i_index})
			begin
				// If a reader is working on the address that we want
				// -> do not want to request
				want_read_request = '0;
				break;
			end
		end
	end
	
	// Read input
	always_comb
	begin
		read_addr = {in.addr[ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2], {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		reader_request = {READER_COUNT{miss & want_read_request}} & read_shift_register;
		read_clobber = '0;

		for (int i = 0; i < READER_COUNT; ++i)
		begin
			// reader has a matching tag and index
			if (reader_addr[i] `GET_TAG_INDEX == {i_tag, i_index})
			begin
				read_clobber[i] = refill;
			end
		end
	end
	
	// Write input
	always_comb
	begin
		// NOTE(mitch): hard-coded for 1 writer
		writer_request[0] = evict & writer_ready[0] & ~r_write_pending;
		writer_addr[0] = {tagbank_rdata[select_way], i_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		writer_data[0] = databank_rdata[select_way];
	end

	always_comb
	begin
		for (int i=0; i<ASSOCIATIVITY;i++)
			databank_we[i] = '0;

		if (hit & (in.mem_action == WRITE))	// We are storing a word
			databank_we[select_way][i_block_offset] = 1'b1;

		// Refilling from reader, write to entire cacheline
		if (refill)
			databank_we[select_way] = '1;
	end

	always_comb
	begin
		databank_waddr = i_index;
		databank_raddr = i_index_next;
	end

	always_comb 
	begin
		// need to write to the tagbank when we are refilling from memory
		tagbank_we[ select_way] = refill;
		tagbank_we[~select_way] = '0;

		tagbank_wdata = i_tag;
		tagbank_waddr = i_index;
		tagbank_raddr = i_index_next;
	end

	always_comb
	begin
		out.valid = hit;
		out.data = databank_rdata[select_way][i_block_offset];
	end

	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			read_shift_register <= 1;
			for (int i=0; i<ASSOCIATIVITY;i++)
				valid_bits[i] <= '0;
			for (int i=0; i<DEPTH;i++)
				lru_rp[i] <= 0;
			r_write_pending      <= '0;
			r_write_select_way   <= '0;
			r_write_index        <= '0;
			r_write_tag          <= '0;
		end
		else
		begin
			// miss + reader we are requesting is ready to accept
			if (miss & (|reader_request))
			begin
				`DEBUG("%t| (%x) Sending READ request (mask=%b ready=%b)", $time, in.addr, reader_request, reader_ready);
				read_shift_register <= {read_shift_register[READER_COUNT - 2 : 0], read_shift_register[READER_COUNT - 1]};
			end

			// Write has been completed
			if (r_write_pending & writer_valid[0])
			begin
				`DEBUG("%t| (%x) WRITE completed", $time, writer_o_addr[0]);
				// Now we can start another write.
				r_write_pending <= '0;
				// Mark this entry as invalid, ready to be replaced
				valid_bits[r_write_select_way][r_write_index] <= '0;
			end

			// Want to start a write
			if (writer_request[0])
			begin
				`DEBUG("%t| (%x) Sending WRITE request (debug=%x)", $time, writer_addr[0], r_debug);
				r_write_pending    <= '1;
				r_write_select_way <= select_way;
				r_write_index      <= i_index;
				r_write_tag        <= tagbank_rdata[select_way];
			end

			if (refill)
			begin
				`DEBUG("%t| (%x) READ completed", $time, in.addr);
				valid_bits[select_way][i_index] <= '1;
				dirty_bits[select_way][i_index] <= '0;
			end
			else if (miss & reader_has_data)
			begin
				`DEBUG("%t| (%x) Waiting to Flush %b(pending=%x, writer=%x, select=%x)!", $time, in.addr, r_write_pending, {r_write_tag, r_write_index, 4'b0}, writer_o_addr[0], {tagbank_rdata[select_way], i_index, 4'b0});
			end
			
			if (hit)
			begin
				`DEBUG("%t| (%x) HIT (op=%s, data=%x) %x", $time,
					in.addr, in.mem_action == READ? "READ":"WRITE",
					in.mem_action == READ? out.data:in.data,
					databank_we[select_way],
				);
				if (i_index != r_write_index || ~r_write_pending)
					lru_rp[i_index] <= ~select_way;

				if (in.mem_action == WRITE)
					dirty_bits[select_way][i_index] <= 1'b1;
			end

			r_debug <= in.addr;
		end
	end
endmodule

module memory_writer #(
	parameter BLOCK_OFFSET_WIDTH,
	parameter LINE_SIZE,
	parameter ID
) (
	input  logic     clk,
	input  logic     rst_n,

	axi_write_address.master  mem_write_address,
	axi_write_data.master     mem_write_data,
	
	input  logic   i_request,
	input  Address i_addr,
	input  Data    i_data [LINE_SIZE],
	output logic   o_ready,
	output logic   o_valid,
	output Address o_addr
);

// Check if the parameters are set correctly
generate
	if(ID > 16 || LINE_SIZE > 16)
	begin
		INVALID_PARAM invalid_param ();
	end
endgenerate

enum logic [1:0] {
	STATE_READY,    // Ready for incoming requests
	STATE_REQUEST,  // Sending out memory write request
	STATE_FLUSH     // Writes out a dirty cache line
} state, next_state;

logic [LINE_SIZE - 1 : 0] r_select;
Data    r_data [LINE_SIZE];
Address r_address;
logic   last_flush_word;

assign o_ready = state == STATE_READY;
assign o_addr = r_address;
assign last_flush_word = r_select[LINE_SIZE - 1] & mem_write_data.WVALID;

always_comb
begin
	next_state = state;

	unique case (state)
		STATE_READY:
			if (i_request)
				next_state = STATE_REQUEST;

		STATE_REQUEST:
			if (mem_write_address.AWREADY)
				next_state = STATE_FLUSH;

		STATE_FLUSH:
			if (last_flush_word && mem_write_data.WREADY)
				next_state = STATE_READY;
	endcase
end

always_comb
begin
	mem_write_address.AWVALID = state == STATE_REQUEST;
	mem_write_address.AWID    = ID;
	mem_write_address.AWLEN   = LINE_SIZE[3:0];
	mem_write_address.AWADDR  = r_address;

	mem_write_data.WVALID = state == STATE_FLUSH;
	mem_write_data.WID    = ID;
	mem_write_data.WDATA  = r_data[0];
	mem_write_data.WLAST  = last_flush_word;
end

always_ff @(posedge clk)
begin
	if(~rst_n)
	begin
		r_address <= '0;
		for (int i = 0; i < LINE_SIZE; ++i)
			r_data[i] <= '0;
		o_valid <= '0;
		r_select <= 1;
	end
	else
	begin
		state <= next_state;

		case (state)
			default: begin end
			STATE_READY:
			begin
				if (i_request)
				begin
					`DEBUG("%t| (%x) [WRITE %d] GOT REQUEST [%x %x %x %x]", $time, i_addr, ID,
						i_data[0], i_data[1], i_data[2], i_data[3],
					);
					r_address <= i_addr;
					
					for (int i = 0; i < LINE_SIZE; i++)
						r_data[i] <= i_data[i];

					o_valid <= '0;
				end
			end

			STATE_REQUEST:
			begin
				begin
					`DEBUG("(%x) mem_write_address.AWREADY = %b", r_address, mem_write_address.AWREADY);
				end
			end

			STATE_FLUSH:
			begin
				if (mem_write_data.WREADY)
				begin
					`DEBUG("%t| {%x}! SHIFT! %b", $time, r_address, r_select);
					for (int i = 0; i < LINE_SIZE - 1; i++)
						r_data[i] <= r_data[i+1];

					r_select <= {r_select[LINE_SIZE - 2 : 0], r_select[LINE_SIZE - 1]};

					if (last_flush_word)
					begin
						`DEBUG("%t| (%x) [WRITE] DONE", $time, r_address, ID);
						o_valid <= '1;
					end
				end
			end
		endcase
	end
end

endmodule

module memory_reader #(
	parameter BLOCK_OFFSET_WIDTH,
	parameter LINE_SIZE,
	parameter ID
) (
	input  logic     clk,
	input  logic     rst_n,

	axi_read_address.master   mem_read_address,
	axi_read_data.master      mem_read_data,
	
	input  logic   i_request,
	input  Address i_addr,
	input  logic   i_clobber,
	output logic   o_ready,
	output logic   o_done,
	output Data    o_data [LINE_SIZE],
	output Address o_addr
);

// Check if the parameters are set correctly
generate
	if(ID > 16 || LINE_SIZE > 16)
	begin
		INVALID_PARAM invalid_param ();
	end
endgenerate

enum logic [1:0] {
	STATE_READY,     // Ready for incoming requests
	STATE_REQUEST,   // Sending out memory read request
	STATE_REFILL     // Loads a cache line from memory
} state, next_state;

logic   r_valid;
Data    r_data [LINE_SIZE];
Address r_address;

logic last_refill_word;
logic [LINE_SIZE - 1 : 0] word_select;

assign o_done = r_valid;
assign o_addr = r_address;
assign o_data = r_data;
assign o_ready = state == STATE_READY;

always_comb
begin
	next_state = state;

	unique case (state)
		STATE_READY:
			if (i_request)
				next_state = STATE_REQUEST;

		STATE_REQUEST:
			if (mem_read_address.ARREADY)
				next_state = STATE_REFILL;

		STATE_REFILL:
			if (last_refill_word)
				next_state = STATE_READY;
	endcase
end

always_comb
begin
	last_refill_word = word_select[LINE_SIZE - 1] & mem_read_data.RVALID;
end

always_comb begin
	mem_read_address.ARVALID = state == STATE_REQUEST;
	mem_read_address.ARID    = ID[3:0];
	mem_read_address.ARLEN   = LINE_SIZE[3:0];
	mem_read_address.ARADDR  = {r_address[ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2], {BLOCK_OFFSET_WIDTH + 2{1'b0}}};

	// Always ready to consume data
	mem_read_data.RREADY = 1'b1;
end

always_ff @(posedge clk)
begin
	if(~rst_n)
	begin
		state <= STATE_READY;
		r_valid <= '0;
		r_address <= '0;
		word_select <= 1;
		for (int i=0; i<LINE_SIZE; i++)
			r_data[i] <= '0;
	end
	else
	begin
		state <= next_state;

		case (state)
			default: begin end
			
			STATE_READY:
			begin
				if (i_request)
				begin
					`DEBUG("%t| (%x) [%0d] GOT REQUEST", $time, i_addr, ID);
					r_address <= i_addr;
				end

				if (i_clobber)
				begin
					`DEBUG("%t| (%x) [%0d] CLOBBER", $time, r_address, ID);
					r_address <= '0;
				end

				if (i_request | i_clobber)
					r_valid   <= '0;
			end

			STATE_REFILL:
			begin
				if (mem_read_data.RVALID)
				begin
					word_select <= {word_select[LINE_SIZE - 2 : 0], word_select[LINE_SIZE - 1]};
					for (int i = 0; i < LINE_SIZE; ++i)
						if (word_select[i] == 1'b1)
							r_data[i] <= mem_read_data.RDATA;
				end

				if (last_refill_word)
				begin
					`DEBUG("%t| (%x) [%0d] GOT DATA [%x %x %x %x]", $time,
						r_address, ID,
						r_data[0], r_data[1], r_data[2], r_data[3]);
					r_valid <= '1;
				end
			end
		endcase
	end
end

endmodule
`else
module d_cache #(
	parameter INDEX_WIDTH = 6,  // 2 * 1 KB Cache Size 
	parameter BLOCK_OFFSET_WIDTH = 2,
	parameter ASSOCIATIVITY = 2
	)(
	// General signals
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// Request
	d_cache_input_ifc.in in,

	// Response
	output cache_output_t out,

	// AXI interfaces
	axi_write_address.master mem_write_address,
	axi_write_data.master mem_write_data,
	axi_write_response.master mem_write_response,
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
			INVALID_D_CACHE_PARAM invalid_d_cache_param ();
		end
	endgenerate

	// Parsing
	logic [TAG_WIDTH - 1 : 0] i_tag;
	logic [INDEX_WIDTH - 1 : 0] i_index;
	logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;

	logic [INDEX_WIDTH - 1 : 0] i_index_next;

	assign {i_tag, i_index, i_block_offset} = in.addr[ADDR_WIDTH - 1 : 2];
	assign i_index_next = in.addr_next[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
	// Above line uses +: slice, a feature of SystemVerilog
	// See https://stackoverflow.com/questions/18067571

	// States
	enum logic [2:0] {
		STATE_READY,            // Ready for incoming requests
		STATE_FLUSH_REQUEST,    // Sending out memory write request
		STATE_FLUSH_DATA,       // Writes out a dirty cache line
		STATE_REFILL_REQUEST,   // Sending out memory read request
		STATE_REFILL_DATA       // Loads a cache line from memory
	} state, next_state;
	logic pending_write_response;

	// Registers for flushing and refilling
	logic [INDEX_WIDTH - 1:0] r_index;
	logic [TAG_WIDTH - 1:0] r_tag;

	// databank signals
	logic [LINE_SIZE - 1 : 0] databank_select;
	logic [LINE_SIZE - 1 : 0] databank_we[ASSOCIATIVITY];
	logic [DATA_WIDTH - 1 : 0] databank_wdata;
	logic [INDEX_WIDTH - 1 : 0] databank_waddr;
	logic [INDEX_WIDTH - 1 : 0] databank_raddr;
	logic [DATA_WIDTH - 1 : 0] databank_rdata [ASSOCIATIVITY][LINE_SIZE];

	logic select_way;
	logic r_select_way;
	logic [DEPTH - 1 : 0] lru_rp;

	// databanks
	genvar g,w;
	generate
		for (g = 0; g < LINE_SIZE; g++)
		begin : datasets
			for (w=0; w< ASSOCIATIVITY; w++)
			begin : databanks
				cache_bank #(
					.DATA_WIDTH (DATA_WIDTH),
					.ADDR_WIDTH (INDEX_WIDTH)
				) databank (
					.clk,
					.i_we (databank_we[w][g]),
					.i_wdata(databank_wdata),
					.i_waddr(databank_waddr),
					.i_raddr(databank_raddr),

					.o_rdata(databank_rdata[w][g])
				);
			end
		end
	endgenerate

	// tagbank signals
	logic tagbank_we[ASSOCIATIVITY];
	logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
	logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
	logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
	logic [TAG_WIDTH - 1 : 0] tagbank_rdata[ASSOCIATIVITY];

	generate
		for (w=0; w< ASSOCIATIVITY; w++)
		begin: tagbanks
			cache_bank #(
				.DATA_WIDTH (TAG_WIDTH),
				.ADDR_WIDTH (INDEX_WIDTH)
			) tagbank (
				.clk,
				.i_we    (tagbank_we[w]),
				.i_wdata (tagbank_wdata),
				.i_waddr (tagbank_waddr),
				.i_raddr (tagbank_raddr),

				.o_rdata (tagbank_rdata[w])
			);
		end
	endgenerate

	// Valid bits
	logic [DEPTH - 1 : 0] valid_bits[ASSOCIATIVITY];
	// Dirty bits
	logic [DEPTH - 1 : 0] dirty_bits[ASSOCIATIVITY];

	// Shift registers for flushing
	logic [DATA_WIDTH - 1 : 0] shift_rdata[LINE_SIZE];

	// Intermediate signals
	logic hit, miss, tag_hit;
	logic last_flush_word;
	logic last_refill_word;

	always_comb
	begin
		tag_hit = ( ((i_tag == tagbank_rdata[0]) & valid_bits[0][i_index])
				  |	((i_tag == tagbank_rdata[1]) & valid_bits[1][i_index]));
		hit = in.valid
			& (tag_hit)
			& (state == STATE_READY);
		miss = in.valid & ~hit;
		last_flush_word = databank_select[LINE_SIZE - 1] & mem_write_data.WVALID;
		last_refill_word = databank_select[LINE_SIZE - 1] & mem_read_data.RVALID;
	
		if (hit)
		begin
			if (i_tag == tagbank_rdata[0])
			begin
				select_way = 'b0;
			end
			else 
			begin
				select_way = 'b1;
			end
		end
		else if (miss)
		begin
			select_way = lru_rp[i_index];
		end
		else
		begin
			select_way = 'b0;
		end
	
	end

	always_comb
	begin
		mem_write_address.AWVALID = state == STATE_FLUSH_REQUEST;
		mem_write_address.AWID = 0;
		mem_write_address.AWLEN = LINE_SIZE;
		mem_write_address.AWADDR = {tagbank_rdata[r_select_way], i_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		mem_write_data.WVALID = state == STATE_FLUSH_DATA;
		mem_write_data.WID = 0;
		mem_write_data.WDATA = shift_rdata[0];
		mem_write_data.WLAST = last_flush_word;

		// Always ready to consume write response
		mem_write_response.BREADY = 1'b1;
	end

	always_comb begin
		mem_read_address.ARADDR = {r_tag, r_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
		mem_read_address.ARLEN = LINE_SIZE;
		mem_read_address.ARVALID = state == STATE_REFILL_REQUEST;
		mem_read_address.ARID = 4'd1;

		// Always ready to consume data
		mem_read_data.RREADY = 1'b1;
	end

	always_comb
	begin
		for (int i=0; i<ASSOCIATIVITY;i++)
			databank_we[i] = '0;
		if (mem_read_data.RVALID)				// We are refilling data
			databank_we[r_select_way] = databank_select;
		else if (hit & (in.mem_action == WRITE))	// We are storing a word
			databank_we[select_way][i_block_offset] = 1'b1;
	end

	always_comb
	begin
		if (state == STATE_READY)
		begin
			databank_wdata = in.data;
			databank_waddr = i_index;
			if (next_state == STATE_FLUSH_REQUEST)
				databank_raddr = i_index;
			else
				databank_raddr = i_index_next;
		end
		else
		begin
			databank_wdata = mem_read_data.RDATA;
			databank_waddr = r_index;
			if (next_state == STATE_READY)
				databank_raddr = i_index_next;
			else
				databank_raddr = r_index;
		end
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
					if (valid_bits[select_way][i_index] & dirty_bits[select_way][i_index])
						next_state = STATE_FLUSH_REQUEST;
					else
						next_state = STATE_REFILL_REQUEST;

			STATE_FLUSH_REQUEST:
				if (mem_write_address.AWREADY)
					next_state = STATE_FLUSH_DATA;

			STATE_FLUSH_DATA:
				if (last_flush_word && mem_write_data.WREADY)
					next_state = STATE_REFILL_REQUEST;

			STATE_REFILL_REQUEST:
				if (mem_read_address.ARREADY)
					next_state = STATE_REFILL_DATA;

			STATE_REFILL_DATA:
				if (last_refill_word)
					next_state = STATE_READY;
		endcase
	end

	always_ff @(posedge clk) begin
		if (~rst_n)
			pending_write_response <= 1'b0;
		else if (mem_write_address.AWVALID && mem_write_address.AWREADY)
			pending_write_response <= 1'b1;
		else if (mem_write_response.BVALID && mem_write_response.BREADY)
			pending_write_response <= 1'b0;
	end

	always_ff @(posedge clk)
	begin
		if (state == STATE_FLUSH_DATA && mem_write_data.WREADY)
			for (int i = 0; i < LINE_SIZE - 1; i++)
				shift_rdata[i] <= shift_rdata[i+1];

		if (state == STATE_FLUSH_REQUEST && next_state == STATE_FLUSH_DATA)
			for (int i = 0; i < LINE_SIZE; i++)
				shift_rdata[i] <= databank_rdata[r_select_way][i];
	end

	always_ff @(posedge clk)
	begin
		if(~rst_n)
		begin
			state <= STATE_READY;
			databank_select <= 1;
			for (int i=0; i<ASSOCIATIVITY;i++)
				valid_bits[i] <= '0;
			for (int i=0; i<DEPTH;i++)
				lru_rp[i] <= 0;
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
					else if (in.mem_action == WRITE)
						dirty_bits[select_way][i_index] <= 1'b1;
					if (in.valid)
					begin
						lru_rp[i_index] <= ~select_way;
					end
				end

				STATE_FLUSH_DATA:
				begin
					if (mem_write_data.WREADY)
						databank_select <= {databank_select[LINE_SIZE - 2 : 0],
							databank_select[LINE_SIZE - 1]};
				end

				STATE_REFILL_DATA:
				begin
					if (mem_read_data.RVALID)
						databank_select <= {databank_select[LINE_SIZE - 2 : 0],
							databank_select[LINE_SIZE - 1]};

					if (last_refill_word)
					begin
						valid_bits[r_select_way][r_index] <= 1'b1;
						dirty_bits[r_select_way][r_index] <= 1'b0;
					end
				end
			endcase
		end
	end
endmodule
`endif