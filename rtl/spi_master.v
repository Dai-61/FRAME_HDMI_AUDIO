// SPI byte master from the official Anlogic EG4S20 SD-card example.
module spi_master
(
    input  wire       sys_clk,
    input  wire       rst,
    output wire       nCS,
    output wire       DCLK,
    output wire       MOSI,
    input  wire       MISO,
    input  wire       CPOL,
    input  wire       CPHA,
    input  wire       nCS_ctrl,
    input  wire [15:0] clk_div,
    input  wire       wr_req,
    output wire       wr_ack,
    input  wire [7:0] data_in,
    output wire [7:0] data_out
);

    localparam IDLE            = 3'd0;
    localparam DCLK_EDGE       = 3'd1;
    localparam DCLK_IDLE       = 3'd2;
    localparam ACK             = 3'd3;
    localparam LAST_HALF_CYCLE = 3'd4;
    localparam ACK_WAIT        = 3'd5;

    reg       dclk_reg;
    reg [7:0] mosi_shift;
    reg [7:0] miso_shift;
    reg [2:0] state;
    reg [2:0] next_state;
    reg [15:0] clk_cnt;
    reg [4:0] clk_edge_cnt;

    assign MOSI     = mosi_shift[7];
    assign DCLK     = dclk_reg;
    assign data_out = miso_shift;
    assign wr_ack   = (state == ACK);
    assign nCS      = nCS_ctrl;

    always @(posedge sys_clk or posedge rst) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        case (state)
            IDLE:
                next_state = wr_req ? DCLK_IDLE : IDLE;
            DCLK_IDLE:
                next_state = (clk_cnt == clk_div) ? DCLK_EDGE : DCLK_IDLE;
            DCLK_EDGE:
                next_state = (clk_edge_cnt == 5'd15) ? LAST_HALF_CYCLE : DCLK_IDLE;
            LAST_HALF_CYCLE:
                next_state = (clk_cnt == clk_div) ? ACK : LAST_HALF_CYCLE;
            ACK:
                next_state = ACK_WAIT;
            ACK_WAIT:
                next_state = IDLE;
            default:
                next_state = IDLE;
        endcase
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst)
            dclk_reg <= 1'b0;
        else if (state == IDLE)
            dclk_reg <= CPOL;
        else if (state == DCLK_EDGE)
            dclk_reg <= ~dclk_reg;
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst)
            clk_cnt <= 16'd0;
        else if ((state == DCLK_IDLE) || (state == LAST_HALF_CYCLE))
            clk_cnt <= clk_cnt + 16'd1;
        else
            clk_cnt <= 16'd0;
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst)
            clk_edge_cnt <= 5'd0;
        else if (state == DCLK_EDGE)
            clk_edge_cnt <= clk_edge_cnt + 5'd1;
        else if (state == IDLE)
            clk_edge_cnt <= 5'd0;
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst)
            mosi_shift <= 8'd0;
        else if ((state == IDLE) && wr_req)
            mosi_shift <= data_in;
        else if (state == DCLK_EDGE) begin
            if ((CPHA == 1'b0) && clk_edge_cnt[0])
                mosi_shift <= {mosi_shift[6:0], mosi_shift[7]};
            else if ((CPHA == 1'b1) && (clk_edge_cnt != 5'd0) && !clk_edge_cnt[0])
                mosi_shift <= {mosi_shift[6:0], mosi_shift[7]};
        end
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst)
            miso_shift <= 8'd0;
        else if ((state == IDLE) && wr_req)
            miso_shift <= 8'h00;
        else if (state == DCLK_EDGE) begin
            if ((CPHA == 1'b0) && !clk_edge_cnt[0])
                miso_shift <= {miso_shift[6:0], MISO};
            else if ((CPHA == 1'b1) && clk_edge_cnt[0])
                miso_shift <= {miso_shift[6:0], MISO};
        end
    end

endmodule
