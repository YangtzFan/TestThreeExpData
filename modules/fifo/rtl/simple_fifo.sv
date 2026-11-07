// Teaching DUT: synchronous FIFO with valid/ready handshakes.
// DEPTH=4, DATA_WIDTH=8. Port names match the Chisel twin (SingleChisel).
module SimpleFifo (
    input  wire       clock,
    input  wire       reset,
    input  wire       wr_valid,
    output wire       wr_ready,
    input  wire [7:0] wr_data,
    output wire       rd_valid,
    input  wire       rd_ready,
    output wire [7:0] rd_data
);

    localparam int DEPTH = 4;
    localparam int AW    = 2; // clog2(DEPTH)

    reg [7:0] mem [0:DEPTH-1];
    reg [AW:0] count;
    reg [AW-1:0] wr_ptr;
    reg [AW-1:0] rd_ptr;

    assign wr_ready = (count < DEPTH[AW:0]);
    assign rd_valid = (count != 0);
    assign rd_data  = mem[rd_ptr];

    wire do_push = wr_valid && wr_ready;
    wire do_pop  = rd_valid && rd_ready;

    always @(posedge clock) begin
        if (reset) begin
            count  <= 0;
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (do_push) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= wr_ptr + 1'b1;
            end
            if (do_pop) begin
                rd_ptr <= rd_ptr + 1'b1;
            end

            case ({do_push, do_pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
