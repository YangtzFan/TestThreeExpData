// Simple up-counter: increments when incr=1.
module Counter (
    input  wire       clock,
    input  wire       reset,
    input  wire       incr,
    output wire [7:0] value
);

    reg [7:0] value_reg;

    always @(posedge clock) begin
        if (reset) begin
            value_reg <= 8'd0;
        end else if (incr) begin
            value_reg <= value_reg + 8'd1;
        end
    end

    assign value = value_reg;

endmodule
