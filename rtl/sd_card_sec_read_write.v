// SD initialization and sector read/write sequencer. This is based on the
// official Anlogic EG4S20 SD-card example, with the configured high-speed SPI
// divider preserved after initialization.
module sd_card_sec_read_write
#(
    parameter [15:0] SPI_LOW_SPEED_DIV  = 16'd248,
    parameter [15:0] SPI_HIGH_SPEED_DIV = 16'd8
)(
    input  wire       clk,
    input  wire       rst,
    output reg        sd_init_done,
    input  wire       sd_sec_read,
    input  wire [31:0] sd_sec_read_addr,
    output wire [7:0] sd_sec_read_data,
    output wire       sd_sec_read_data_valid,
    output wire       sd_sec_read_end,
    input  wire       sd_sec_write,
    input  wire [31:0] sd_sec_write_addr,
    input  wire [7:0] sd_sec_write_data,
    output wire       sd_sec_write_data_req,
    output wire       sd_sec_write_end,
    output reg  [15:0] spi_clk_div,
    output reg        cmd_req,
    input  wire       cmd_req_ack,
    input  wire       cmd_req_error,
    output reg  [47:0] cmd,
    output reg  [7:0] cmd_r1,
    output reg  [15:0] cmd_data_len,
    output reg        block_read_req,
    input  wire       block_read_valid,
    input  wire [7:0] block_read_data,
    input  wire       block_read_req_ack,
    output reg        block_write_req,
    output wire [7:0] block_write_data,
    input  wire       block_write_data_rd,
    input  wire       block_write_req_ack
);

    localparam S_IDLE            = 5'd0;
    localparam S_CMD0            = 5'd1;
    localparam S_CMD8            = 5'd2;
    localparam S_CMD55           = 5'd3;
    localparam S_CMD41           = 5'd4;
    localparam S_CMD17           = 5'd5;
    localparam S_READ            = 5'd6;
    localparam S_CMD24           = 5'd7;
    localparam S_WRITE           = 5'd8;
    localparam S_ERR             = 5'd14;
    localparam S_WRITE_END       = 5'd15;
    localparam S_READ_END        = 5'd16;
    localparam S_WAIT_READ_WRITE = 5'd17;
    localparam S_CMD16           = 5'd18;

    reg [4:0]  state;
    reg [31:0] sec_addr;

    assign sd_sec_read_data_valid = (state == S_READ) && block_read_valid;
    assign sd_sec_read_data       = block_read_data;
    assign sd_sec_read_end        = (state == S_READ_END);
    assign sd_sec_write_data_req  = (state == S_WRITE) && block_write_data_rd;
    assign block_write_data       = sd_sec_write_data;
    assign sd_sec_write_end       = (state == S_WRITE_END);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            cmd_req         <= 1'b0;
            cmd_data_len    <= 16'd0;
            cmd_r1          <= 8'd0;
            cmd             <= 48'd0;
            spi_clk_div     <= SPI_LOW_SPEED_DIV;
            block_write_req <= 1'b0;
            block_read_req  <= 1'b0;
            sec_addr        <= 32'd0;
            sd_init_done    <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    state        <= S_CMD0;
                    sd_init_done <= 1'b0;
                    spi_clk_div  <= SPI_LOW_SPEED_DIV;
                end

                S_CMD0: begin
                    if (cmd_req_ack && !cmd_req_error) begin
                        state   <= S_CMD8;
                        cmd_req <= 1'b0;
                    end else begin
                        cmd_req      <= 1'b1;
                        cmd_data_len <= 16'd0;
                        cmd_r1       <= 8'h01;
                        cmd          <= {8'd0, 8'h00, 8'h00, 8'h00, 8'h00, 8'h95};
                    end
                end

                S_CMD8: begin
                    if (cmd_req_ack && !cmd_req_error) begin
                        state   <= S_CMD55;
                        cmd_req <= 1'b0;
                    end else begin
                        cmd_req      <= 1'b1;
                        cmd_data_len <= 16'd4;
                        cmd_r1       <= 8'h01;
                        cmd          <= {8'd8, 8'h00, 8'h00, 8'h01, 8'haa, 8'h87};
                    end
                end

                S_CMD55: begin
                    if (cmd_req_ack && !cmd_req_error) begin
                        state   <= S_CMD41;
                        cmd_req <= 1'b0;
                    end else begin
                        cmd_req      <= 1'b1;
                        cmd_data_len <= 16'd0;
                        cmd_r1       <= 8'h01;
                        cmd          <= {8'd55, 8'h00, 8'h00, 8'h00, 8'h00, 8'hff};
                    end
                end

                S_CMD41: begin
                    if (cmd_req_ack && !cmd_req_error) begin
                        state         <= S_CMD16;
                        cmd_req       <= 1'b0;
                        sd_init_done  <= 1'b1;
                        spi_clk_div   <= SPI_HIGH_SPEED_DIV;
                    end else if (cmd_req_ack) begin
                        state <= S_CMD55;
                    end else begin
                        cmd_req      <= 1'b1;
                        cmd_data_len <= 16'd0;
                        cmd_r1       <= 8'h00;
                        cmd          <= {8'd41, 8'h40, 8'h00, 8'h00, 8'h00, 8'hff};
                    end
                end

                S_CMD16: begin
                    if (cmd_req_ack && !cmd_req_error) begin
                        state        <= S_WAIT_READ_WRITE;
                        cmd_req      <= 1'b0;
                        sd_init_done <= 1'b1;
                        spi_clk_div  <= SPI_HIGH_SPEED_DIV;
                    end else if (cmd_req_ack) begin
                        state <= S_CMD55;
                    end else begin
                        cmd_req      <= 1'b1;
                        cmd_data_len <= 16'd0;
                        cmd_r1       <= 8'h00;
                        cmd          <= {8'd16, 32'd512, 8'hff};
                    end
                end

                S_WAIT_READ_WRITE: begin
                    // Keep SPI_HIGH_SPEED_DIV here. The original example
                    // forced this value to zero, which overrode its parameter.
                    spi_clk_div <= SPI_HIGH_SPEED_DIV;
                    if (sd_sec_write) begin
                        state    <= S_CMD24;
                        sec_addr <= sd_sec_write_addr;
                    end else if (sd_sec_read) begin
                        state    <= S_CMD17;
                        sec_addr <= sd_sec_read_addr;
                    end
                end

                S_CMD24: begin
                    if (cmd_req_ack && !cmd_req_error) begin
                        state   <= S_WRITE;
                        cmd_req <= 1'b0;
                    end else begin
                        cmd_req      <= 1'b1;
                        cmd_data_len <= 16'd0;
                        cmd_r1       <= 8'h00;
                        cmd          <= {8'd24, sec_addr, 8'hff};
                    end
                end

                S_WRITE: begin
                    if (block_write_req_ack) begin
                        block_write_req <= 1'b0;
                        state           <= S_WRITE_END;
                    end else begin
                        block_write_req <= 1'b1;
                    end
                end

                S_CMD17: begin
                    if (cmd_req_ack && !cmd_req_error) begin
                        state   <= S_READ;
                        cmd_req <= 1'b0;
                    end else begin
                        cmd_req      <= 1'b1;
                        cmd_data_len <= 16'd0;
                        cmd_r1       <= 8'h00;
                        cmd          <= {8'd17, sec_addr, 8'hff};
                    end
                end

                S_READ: begin
                    if (block_read_req_ack) begin
                        state           <= S_READ_END;
                        block_read_req  <= 1'b0;
                    end else begin
                        block_read_req <= 1'b1;
                    end
                end

                S_WRITE_END:
                    state <= S_WAIT_READ_WRITE;

                S_READ_END:
                    state <= S_WAIT_READ_WRITE;

                default:
                    state <= S_IDLE;
            endcase
        end
    end

endmodule
