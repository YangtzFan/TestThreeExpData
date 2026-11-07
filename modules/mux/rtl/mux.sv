// 1-bit select 8-bit mux: out = sel ? b : a
module Mux (
    input  wire       clock,
    input  wire       reset,
    input  wire       sel,
    input  wire [7:0] a,
    input  wire [7:0] b,
    output wire [7:0] out
);

    // clock/reset unused (kept so tb_gen finds standard ports)
    assign out = sel ? b : a;

endmodule
