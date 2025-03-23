

module store_buffer #(
    CAPACITY=32
)(
    // (Dispatch stage)
    input  Address i_lookup_addr,
    output logic   o_found,
    output Data    o_data,

    // (Commit stage)
    input logic   i_want_new_entry,
    input Address i_addr,
    input Data    i_data,

    output logic o_full
);

typedef struct packed {
    logic   valid;
    logic   evict; // ready to be evicted
    Address addr;
    Data    data;
} entry_t;

entry_t entries [CAPACITY];

endmodule