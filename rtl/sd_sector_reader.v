`timescale 1ns/1ps
// Buffers one 512-byte TF-card sector so higher-level parsers can examine it
// byte by byte without coupling to the SPI transaction timing.
module sd_sector_reader (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] lba,
    output reg         busy,
    output reg         done,
    output reg         timeout,
    input  wire [8:0]  rd_addr,
    output wire [7:0]  rd_data,
    output reg  [9:0]  byte_count,
    output wire        sd_init_done,
    output wire        sd_ncs,
    output wire        sd_dclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);

    reg [7:0]  sector [0:511];
    reg        sd_sec_read;
    reg [31:0] read_lba;
    reg [31:0] wait_count;
    wire [7:0] sd_sec_data;
    wire       sd_sec_valid;
    wire       sd_sec_end;

    assign rd_data = sector[rd_addr];

    sd_card_top #(
        .SPI_LOW_SPEED_DIV (16'd248),
        .SPI_HIGH_SPEED_DIV(16'd8)
    ) u_sd (
        .clk                    (clk),
        .rst                    (rst),
        .SD_nCS                 (sd_ncs),
        .SD_DCLK                (sd_dclk),
        .SD_MOSI                (sd_mosi),
        .SD_MISO                (sd_miso),
        .sd_init_done           (sd_init_done),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (read_lba),
        .sd_sec_read_data       (sd_sec_data),
        .sd_sec_read_data_valid (sd_sec_valid),
        .sd_sec_read_end        (sd_sec_end),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
    );
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            timeout    <= 1'b0;
            sd_sec_read <= 1'b0;
            read_lba   <= 32'd0;
            byte_count <= 10'd0;
            wait_count <= 32'd0;
        end else begin
            done    <= 1'b0;
            timeout <= 1'b0;

            if (start && !busy) begin
                busy       <= 1'b1;
                read_lba   <= lba;
                byte_count <= 10'd0;
                wait_count <= 32'd0;
                sd_sec_read <= 1'b1;
            end else if (busy) begin
                wait_count <= wait_count + 1'b1;

                if (sd_sec_valid && (byte_count < 10'd512)) begin
                    sector[byte_count[8:0]] <= sd_sec_data;
                    byte_count <= byte_count + 1'b1;
                end

                if (sd_sec_end) begin
                    busy        <= 1'b0;
                    done        <= 1'b1;
                    sd_sec_read <= 1'b0;
                end else if (wait_count == 32'd50_000_000) begin
                    busy        <= 1'b0;
                    done        <= 1'b1;
                    timeout     <= 1'b1;
                    sd_sec_read <= 1'b0;
                end
            end
        end
    end

endmodule
