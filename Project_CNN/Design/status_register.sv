module status_register (
    input  logic clk,
    input  logic rst_n,
    input  logic relu0_done,
    input  logic pool0_done,
    input  logic relu1_done,
    input  logic pool1_done,
    input  logic fc0_done,
    input  logic fc1_done,
    output logic relu_en,
    output logic pool_en,
    output logic fc_en,

    output logic frame_done
);

typedef enum logic [3:0] {
    IDLE  = 4'd0,
    RELU1 = 4'd1,
    POOL1 = 4'd2,
    RELU2 = 4'd3,
    POOL2 = 4'd4,
    FC1   = 4'd5,
    FC2   = 4'd6,
    DONE  = 4'd7
} state_t;

state_t state, next_state;


///////////////////////////////////////////////////////
// STATE REGISTER
///////////////////////////////////////////////////////
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

///////////////////////////////////////////////////////
// NEXT STATE LOGIC
///////////////////////////////////////////////////////
logic relu0_done_latched, pool0_done_latched;
logic relu1_done_latched, pool1_done_latched;
always_comb begin
    next_state = state;

    case (state)
        IDLE:  next_state = RELU1;

        RELU1: if (relu0_done_latched) next_state = POOL1;

        POOL1: if (pool0_done_latched) next_state = RELU2;

        RELU2: if (relu1_done_latched) next_state = POOL2;

        POOL2: if (pool1_done_latched) next_state = FC1;

        FC1:   if (fc0_done)   next_state = FC2;

        FC2:   if (fc1_done)   next_state = DONE;

        DONE:  next_state = DONE;

        default: next_state = IDLE;
    endcase
end

///////////////////////////////////////////////////////
// LATCHED DONE FLAGS — guards against eop pulses that
// arrive on a cycle other than the one the FSM expects
// them on (e.g. a stage finishing before the FSM has even
// reached the corresponding state on a "cold" first frame).
// Each flag is set as soon as its pulse fires, regardless
// of current state, and cleared once consumed by the
// matching state transition above.
///////////////////////////////////////////////////////

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        relu0_done_latched <= 1'b0;
        pool0_done_latched <= 1'b0;
        relu1_done_latched <= 1'b0;
        pool1_done_latched <= 1'b0;
    end else begin
        if (relu0_done) relu0_done_latched <= 1'b1;
        else if (state == RELU1 && next_state == POOL1) relu0_done_latched <= 1'b0;

        if (pool0_done) pool0_done_latched <= 1'b1;
        else if (state == POOL1 && next_state == RELU2) pool0_done_latched <= 1'b0;

        if (relu1_done) relu1_done_latched <= 1'b1;
        else if (state == RELU2 && next_state == POOL2) relu1_done_latched <= 1'b0;

        if (pool1_done) pool1_done_latched <= 1'b1;
        else if (state == POOL2 && next_state == FC1) pool1_done_latched <= 1'b0;
    end
end

///////////////////////////////////////////////////////
// OUTPUT LOGIC
///////////////////////////////////////////////////////
always_comb begin
    relu_en    = 0;
    pool_en    = 0;
    fc_en      = 0;
    frame_done = 0;

    case (state)
        RELU1, RELU2: relu_en    = 1;

        POOL1, POOL2: pool_en    = 1;

        FC1, FC2:     fc_en      = 1;

        DONE:         frame_done = 1;
    endcase
end

endmodule
