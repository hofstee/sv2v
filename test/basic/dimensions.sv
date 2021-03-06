`define EXHAUST(t) \
        $display($size(t), $size(t,1), $size(t,2)); \
        $display($left(t), $left(t,1), $left(t,2)); \
        $display($right(t), $right(t,1), $right(t,2)); \
        $display($high(t), $high(t,1), $high(t,2)); \
        $display($low(t), $low(t,1), $low(t,2)); \
        $display($increment(t), $increment(t,1), $increment(t,2)); \
        $display($dimensions(t)); \
        $display($unpacked_dimensions(t)); \
        $display($bits(t));

module top;
    typedef logic [16:1] Word;
    Word Ram[0:9];
    integer ints [3:0];
    typedef struct packed { logic x, y, z; } T;
    logic [$size(T)-1:0] foo;
    initial begin
        $display($size(Word));
        $display($size(Ram,2));
        $display($size(Ram[0]));
        $display($bits(foo));

        `EXHAUST(Ram);
        `EXHAUST(Word);
        `EXHAUST(integer);
        `EXHAUST(bit);
        `EXHAUST(byte);
        `EXHAUST(ints);
    end
endmodule
