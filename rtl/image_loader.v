`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// FAT32 root-directory + uncompressed BMP loader for the HX4S20 HDMI project.
//
// It reads IMAGEn.BMP (n = image_index, 0..3) from the card root directory,
// decodes 24-bit or 32-bit uncompressed BMP rows, and writes a 640x480 frame
// to SDRAM. Smaller images are centered with black borders.
// -----------------------------------------------------------------------------
module image_loader (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  image_index,
    input  wire        sdr_init_done,

    output reg         wr_en,
    output reg  [20:0] wr_addr,
    output reg  [31:0] wr_data,
    output reg  [3:0]  wr_dm,

    output reg         busy,
    output reg         done,
    output reg         image_error,
    output reg  [7:0]  error_code,

    output wire        sd_ncs,
    output wire        sd_dclk,
    output wire        sd_mosi,
    input  wire        sd_miso
);

    localparam integer WIDTH  = 640;
    localparam integer HEIGHT = 480;

    localparam [5:0] S_IDLE       = 6'd0;
    localparam [5:0] S_CLEAR      = 6'd1;
    localparam [5:0] S_WAIT_SD    = 6'd2;
    localparam [5:0] S_MBR_REQ    = 6'd3;
    localparam [5:0] S_MBR_WAIT   = 6'd4;
    localparam [5:0] S_MBR_LBA    = 6'd5;
    localparam [5:0] S_BPB_REQ    = 6'd6;
    localparam [5:0] S_BPB_WAIT   = 6'd7;
    localparam [5:0] S_BPB_SCAN   = 6'd8;
    localparam [5:0] S_BPB_PARSE  = 6'd9;
    localparam [5:0] S_DIR_REQ    = 6'd10;
    localparam [5:0] S_DIR_WAIT   = 6'd11;
    localparam [5:0] S_DIR_BEGIN  = 6'd12;
    localparam [5:0] S_DIR_NAME   = 6'd13;
    localparam [5:0] S_DIR_ATTR   = 6'd14;
    localparam [5:0] S_DIR_META   = 6'd15;
    localparam [5:0] S_DIR_NEXT   = 6'd16;
    localparam [5:0] S_FAT_REQ    = 6'd17;
    localparam [5:0] S_FAT_WAIT   = 6'd18;
    localparam [5:0] S_FAT_READ   = 6'd19;
    localparam [5:0] S_FAT_NEXT   = 6'd20;
    localparam [5:0] S_BMP_REQ    = 6'd21;
    localparam [5:0] S_BMP_WAIT   = 6'd22;
    localparam [5:0] S_HDR_SCAN   = 6'd23;
    localparam [5:0] S_HDR_PARSE  = 6'd24;
    localparam [5:0] S_PROCESS    = 6'd25;
    localparam [5:0] S_NEXT_SEC   = 6'd26;
    localparam [5:0] S_SUCCESS    = 6'd27;
    localparam [5:0] S_FAIL       = 6'd28;
    localparam [5:0] S_ERROR_DONE = 6'd29;

    reg [5:0]  state;
    reg        clear_on_error;
    reg [1:0]  clear_phase;
    reg [18:0] clear_addr;
    reg [8:0]  clear_burst;
    reg [4:0]  clear_gap;

    reg [26:0] sd_wait_timer;
    reg [15:0] sd_init_stable;
    reg [4:0]  sd_reset_count;
    reg        sd_controller_rst;

    reg        fetch_start;
    reg [31:0] fetch_lba;
    wire       fetch_busy;
    wire       fetch_done;
    wire       fetch_timeout;
    reg  [8:0] peek_addr;
    wire [7:0] peek_data;
    wire [9:0] sector_byte_count;
    wire       sd_init_done;

    reg [3:0]  mbr_i;
    reg [31:0] part_lba;

    reg [4:0]  bpb_i;
    reg [15:0] bytes_per_sector;
    reg [7:0]  sectors_per_cluster;
    reg [15:0] reserved_sectors;
    reg [7:0]  number_of_fats;
    reg [15:0] root_entries;
    reg [31:0] fat_size;
    reg [31:0] root_cluster;
    reg [31:0] fat_start;
    reg [31:0] data_start;

    reg [31:0] dir_cluster;
    reg [7:0]  dir_sector;
    reg [3:0]  dir_entry;
    reg [3:0]  name_index;
    reg        name_match;
    reg [3:0]  bmp_match_count;
    reg [2:0]  meta_index;
    reg [15:0] file_cluster_hi;
    reg [15:0] file_cluster_lo;
    reg [31:0] file_size;
    reg [31:0] file_cluster;
    reg [7:0]  file_sec_in_cluster;
    reg [31:0] file_sector_base;

    reg        fat_context; // 0 = directory chain, 1 = image file chain
    reg [31:0] fat_cluster;
    reg [1:0]  fat_byte;
    reg [31:0] fat_value;

    reg [7:0]  bmp_header [0:53];
    reg [5:0]  header_index;
    reg        bmp_header_ready;
    reg [31:0] bmp_data_offset;
    reg [15:0] bmp_width;
    reg [15:0] bmp_height;
    reg [15:0] bmp_bpp;
    reg [7:0]  bmp_bytes_per_pixel;
    reg [11:0] bmp_row_stride;
    reg [11:0] bmp_active_row_bytes;
    reg [9:0]  bmp_x_base;
    reg [9:0]  bmp_y_base;
    reg        bmp_top_down;

    reg [8:0]  process_index;
    reg [11:0] row_byte_index;
    reg [9:0]  pixel_x;
    reg [1:0]  component_index;
    reg [9:0]  image_file_row;
    reg [7:0]  pixel_r;
    reg [7:0]  pixel_g;
    reg [7:0]  pixel_b;

    wire [31:0] hdr_width_raw = {
        bmp_header[21], bmp_header[20], bmp_header[19], bmp_header[18]
    };
    wire [31:0] hdr_height_raw = {
        bmp_header[25], bmp_header[24], bmp_header[23], bmp_header[22]
    };
    wire [31:0] hdr_pixel_offset = {
        bmp_header[13], bmp_header[12], bmp_header[11], bmp_header[10]
    };
    wire [15:0] hdr_bpp = {bmp_header[29], bmp_header[28]};
    wire [15:0] hdr_planes = {bmp_header[27], bmp_header[26]};
    wire [31:0] hdr_compression = {
        bmp_header[33], bmp_header[32], bmp_header[31], bmp_header[30]
    };
    wire [15:0] hdr_abs_height = hdr_height_raw[31]
                               ? (~hdr_height_raw[15:0] + 1'b1)
                               : hdr_height_raw[15:0];

    sd_sector_reader u_sector (
        .clk             (clk),
        .rst             (rst || sd_controller_rst),
        .start           (fetch_start),
        .lba             (fetch_lba),
        .busy            (fetch_busy),
        .done            (fetch_done),
        .timeout         (fetch_timeout),
        .rd_addr         (peek_addr),
        .rd_data         (peek_data),
        .byte_count      (sector_byte_count),
        .sd_init_done    (sd_init_done),
        .sd_ncs          (sd_ncs),
        .sd_dclk         (sd_dclk),
        .sd_mosi         (sd_mosi),
        .sd_miso         (sd_miso)
    );

    reg [31:0] cluster_lba;
    always @(*) begin
        case (state)
            S_BMP_REQ:
                cluster_lba = data_start + ((file_cluster - 32'd2) *
                              {24'd0, sectors_per_cluster}) + file_sec_in_cluster;
            S_DIR_REQ:
                cluster_lba = data_start + ((dir_cluster - 32'd2) *
                              {24'd0, sectors_per_cluster}) + dir_sector;
            default:
                cluster_lba = 32'd0;
        endcase
    end

    // A single asynchronous byte port into the sector buffer is shared by all
    // FAT, directory and BMP parsing states.
    always @(*) begin
        peek_addr = 9'd0;
        case (state)
            S_MBR_LBA:  peek_addr = 9'd454 + {5'd0, mbr_i};
            S_BPB_SCAN: begin
                case (bpb_i)
                    4'd0:  peek_addr = 9'd11;
                    4'd1:  peek_addr = 9'd12;
                    4'd2:  peek_addr = 9'd13;
                    4'd3:  peek_addr = 9'd14;
                    4'd4:  peek_addr = 9'd15;
                    4'd5:  peek_addr = 9'd16;
                    4'd6:  peek_addr = 9'd17;
                    4'd7:  peek_addr = 9'd18;
                    4'd8:  peek_addr = 9'd36;
                    4'd9:  peek_addr = 9'd37;
                    4'd10: peek_addr = 9'd38;
                    4'd11: peek_addr = 9'd39;
                    4'd12: peek_addr = 9'd44;
                    4'd13: peek_addr = 9'd45;
                    4'd14: peek_addr = 9'd46;
                    default: peek_addr = 9'd47;
                endcase
            end
            S_DIR_BEGIN:
                peek_addr = ({5'd0, dir_entry} << 5);
            S_DIR_NAME:
                peek_addr = ({5'd0, dir_entry} << 5) + 9'd8 +
                            {7'd0, name_index};
            S_DIR_ATTR:
                peek_addr = ({5'd0, dir_entry} << 5) + 9'd11;
            S_DIR_META: begin
                case (meta_index)
                    3'd0: peek_addr = ({5'd0, dir_entry} << 5) + 9'd20;
                    3'd1: peek_addr = ({5'd0, dir_entry} << 5) + 9'd21;
                    3'd2: peek_addr = ({5'd0, dir_entry} << 5) + 9'd26;
                    3'd3: peek_addr = ({5'd0, dir_entry} << 5) + 9'd27;
                    3'd4: peek_addr = ({5'd0, dir_entry} << 5) + 9'd28;
                    3'd5: peek_addr = ({5'd0, dir_entry} << 5) + 9'd29;
                    3'd6: peek_addr = ({5'd0, dir_entry} << 5) + 9'd30;
                    default: peek_addr = ({5'd0, dir_entry} << 5) + 9'd31;
                endcase
            end
            S_FAT_READ:
                peek_addr = (({5'd0, fat_cluster[6:0]} << 2) +
                             {7'd0, fat_byte});
            S_HDR_SCAN:
                peek_addr = {3'd0, header_index};
            S_PROCESS:
                peek_addr = {1'b0, process_index};
            default:
                peek_addr = 9'd0;
        endcase
    end

    // Standard 8.3 names store the extension in bytes 8..10. Accept any BMP
    // base name (for example 1.BMP or IMAGE0.BMP).
    reg [7:0] expected_name;
    always @(*) begin
        case (name_index)
            4'd0: expected_name = "B";
            4'd1: expected_name = "M";
            default: expected_name = "P";
        endcase
    end

    wire [31:0] file_pos = file_sector_base + {23'd0, process_index};
    wire [9:0] dst_x = bmp_x_base + pixel_x;
    wire [9:0] dst_y = bmp_top_down
                     ? (bmp_y_base + image_file_row)
                     : (bmp_y_base + bmp_height - 10'd1 - image_file_row);
    wire [20:0] pixel_addr = ({11'd0, dst_y} << 9) +
                             ({11'd0, dst_y} << 7) + {11'd0, dst_x};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state              <= S_IDLE;
            wr_en              <= 1'b0;
            wr_addr            <= 21'd0;
            wr_data            <= 32'd0;
            wr_dm              <= 4'd0;
            busy               <= 1'b0;
            done               <= 1'b0;
            image_error        <= 1'b0;
            error_code         <= 8'd0;
            clear_on_error     <= 1'b0;
            clear_phase        <= 2'd0;
            clear_addr         <= 19'd0;
            clear_burst        <= 9'd0;
            clear_gap          <= 5'd0;
            sd_wait_timer      <= 27'd0;
            sd_init_stable     <= 16'd0;
            sd_reset_count     <= 5'd0;
            sd_controller_rst  <= 1'b0;
            fetch_start        <= 1'b0;
            fetch_lba          <= 32'd0;
            mbr_i              <= 4'd0;
            part_lba           <= 32'd0;
            bpb_i              <= 5'd0;
            bytes_per_sector   <= 16'd0;
            sectors_per_cluster<= 8'd0;
            reserved_sectors   <= 16'd0;
            number_of_fats     <= 8'd0;
            root_entries       <= 16'd0;
            fat_size           <= 32'd0;
            root_cluster       <= 32'd0;
            fat_start          <= 32'd0;
            data_start         <= 32'd0;
            dir_cluster        <= 32'd0;
            dir_sector         <= 8'd0;
            dir_entry          <= 4'd0;
            name_index         <= 4'd0;
            name_match         <= 1'b1;
            bmp_match_count    <= 4'd0;
            meta_index         <= 3'd0;
            file_cluster_hi    <= 16'd0;
            file_cluster_lo    <= 16'd0;
            file_size          <= 32'd0;
            file_cluster       <= 32'd0;
            file_sec_in_cluster<= 8'd0;
            file_sector_base   <= 32'd0;
            fat_context        <= 1'b0;
            fat_cluster        <= 32'd0;
            fat_byte           <= 2'd0;
            fat_value          <= 32'd0;
            header_index       <= 6'd0;
            bmp_header_ready   <= 1'b0;
            bmp_data_offset    <= 32'd0;
            bmp_width          <= 16'd0;
            bmp_height         <= 16'd0;
            bmp_bpp            <= 16'd0;
            bmp_bytes_per_pixel<= 8'd0;
            bmp_row_stride     <= 12'd0;
            bmp_active_row_bytes<=12'd0;
            bmp_x_base         <= 10'd0;
            bmp_y_base         <= 10'd0;
            bmp_top_down       <= 1'b0;
            process_index      <= 9'd0;
            row_byte_index     <= 12'd0;
            pixel_x            <= 10'd0;
            component_index    <= 2'd0;
            image_file_row     <= 10'd0;
            pixel_r            <= 8'd0;
            pixel_g            <= 8'd0;
            pixel_b            <= 8'd0;
        end else begin
            fetch_start <= 1'b0;
            wr_en       <= 1'b0;
            wr_dm       <= 4'h0;

            if (sd_reset_count != 5'd0) begin
                sd_reset_count <= sd_reset_count - 1'b1;
                if (sd_reset_count == 5'd1)
                    sd_controller_rst <= 1'b0;
            end

            if (start && !busy) begin
                busy             <= 1'b1;
                done             <= 1'b0;
                image_error      <= 1'b0;
                error_code       <= 8'd0;
                clear_on_error   <= 1'b0;
                clear_phase      <= 2'd0;
                clear_addr       <= 19'd0;
                clear_burst      <= 9'd0;
                clear_gap        <= 5'd0;
                sd_wait_timer    <= 27'd0;
                sd_init_stable   <= 16'd0;
                sd_reset_count   <= 5'd31;
                sd_controller_rst<= 1'b1;
                bmp_header_ready <= 1'b0;
                fat_value        <= 32'd0;
                state            <= S_CLEAR;
            end else begin
                case (state)
                    S_IDLE: begin
                        busy <= 1'b0;
                    end

                    S_CLEAR: begin
                        if (clear_phase == 2'd0) begin
                            wr_en    <= 1'b1;
                            wr_addr  <= clear_addr;
                            wr_data  <= 32'h00000000;
                            clear_addr <= clear_addr + 1'b1;
                            if (clear_addr == (WIDTH * HEIGHT - 1)) begin
                                clear_addr <= 19'd0;
                                clear_burst<= 9'd0;
                                clear_gap  <= 5'd0;
                                clear_phase<= 2'd0;
                                if (clear_on_error)
                                    state <= S_ERROR_DONE;
                                else
                                    state <= S_WAIT_SD;
                            end else if (clear_burst == 9'd255) begin
                                clear_burst <= 9'd0;
                                clear_gap   <= 5'd24;
                                clear_phase <= 2'd1;
                            end else begin
                                clear_burst <= clear_burst + 1'b1;
                            end
                        end else begin
                            wr_en <= 1'b0;
                            if (clear_gap == 5'd0)
                                clear_phase <= 2'd0;
                            else
                                clear_gap <= clear_gap - 1'b1;
                        end
                    end

                    S_WAIT_SD: begin
                        sd_wait_timer <= sd_wait_timer + 1'b1;
                        if (sd_init_done && sdr_init_done) begin
                            if (sd_init_stable == 16'hFFFF) begin
                                sd_init_stable <= 16'd0;
                                state <= S_MBR_REQ;
                            end else begin
                                sd_init_stable <= sd_init_stable + 1'b1;
                            end
                        end else begin
                            sd_init_stable <= 16'd0;
                            if (sd_wait_timer == 27'd125_000_000) begin
                                error_code <= 8'd1;
                                state <= S_FAIL;
                            end
                        end
                    end

                    S_MBR_REQ: begin
                        fetch_lba   <= 32'd0;
                        fetch_start <= 1'b1;
                        mbr_i       <= 4'd0;
                        state       <= S_MBR_WAIT;
                    end

                    S_MBR_WAIT: begin
                        if (fetch_done) begin
                            if (fetch_timeout) begin
                                error_code <= 8'd2;
                                state <= S_FAIL;
                            end else begin
                                state <= S_MBR_LBA;
                            end
                        end
                    end

                    S_MBR_LBA: begin
                        case (mbr_i)
                            4'd0: part_lba[7:0]   <= peek_data;
                            4'd1: part_lba[15:8]  <= peek_data;
                            4'd2: part_lba[23:16] <= peek_data;
                            default: part_lba[31:24] <= peek_data;
                        endcase
                        if (mbr_i == 4'd3) begin
                            mbr_i <= 4'd0;
                            bpb_i <= 5'd0;
                            state <= S_BPB_REQ;
                        end else begin
                            mbr_i <= mbr_i + 1'b1;
                        end
                    end

                    S_BPB_REQ: begin
                        fetch_lba   <= part_lba;
                        fetch_start <= 1'b1;
                        bpb_i       <= 5'd0;
                        state       <= S_BPB_WAIT;
                    end

                    S_BPB_WAIT: begin
                        if (fetch_done) begin
                            if (fetch_timeout) begin
                                error_code <= 8'd3;
                                state <= S_FAIL;
                            end else begin
                                state <= S_BPB_SCAN;
                            end
                        end
                    end

                    S_BPB_SCAN: begin
                        case (bpb_i)
                            5'd0:  bytes_per_sector[7:0]    <= peek_data;
                            5'd1:  bytes_per_sector[15:8]   <= peek_data;
                            5'd2:  sectors_per_cluster      <= peek_data;
                            5'd3:  reserved_sectors[7:0]    <= peek_data;
                            5'd4:  reserved_sectors[15:8]   <= peek_data;
                            5'd5:  number_of_fats           <= peek_data;
                            5'd6:  root_entries[7:0]        <= peek_data;
                            5'd7:  root_entries[15:8]       <= peek_data;
                            4'd8:  fat_size[7:0]            <= peek_data;
                            4'd9:  fat_size[15:8]           <= peek_data;
                            4'd10: fat_size[23:16]          <= peek_data;
                            4'd11: fat_size[31:24]          <= peek_data;
                            4'd12: root_cluster[7:0]        <= peek_data;
                            4'd13: root_cluster[15:8]       <= peek_data;
                            4'd14: root_cluster[23:16]      <= peek_data;
                            default: root_cluster[31:24]    <= peek_data;
                        endcase
                        if (bpb_i == 5'd15) begin
                            bpb_i <= 5'd0;
                            state <= S_BPB_PARSE;
                        end else begin
                            bpb_i <= bpb_i + 1'b1;
                        end
                    end

                    S_BPB_PARSE: begin
                        if ((bytes_per_sector != 16'd512) ||
                            (sectors_per_cluster == 8'd0) ||
                            (reserved_sectors == 16'd0) ||
                            (number_of_fats == 8'd0) ||
                            (fat_size == 32'd0) ||
                            (root_cluster < 32'd2)) begin
                            error_code <= 8'd4;
                            state <= S_FAIL;
                        end else begin
                            fat_start  <= part_lba + {16'd0, reserved_sectors};
                            data_start <= part_lba +
                                          {16'd0, reserved_sectors} +
                                          ({24'd0, number_of_fats} * fat_size) +
                                          (({16'd0, root_entries} * 16'd32 + 16'd511) >> 9);
                            dir_cluster <= root_cluster;
                            dir_sector  <= 8'd0;
                            dir_entry   <= 4'd0;
                            bmp_match_count <= 4'd0;
                            state       <= S_DIR_REQ;
                        end
                    end

                    S_DIR_REQ: begin
                        fetch_lba   <= cluster_lba;
                        fetch_start <= 1'b1;
                        dir_entry   <= 4'd0;
                        state       <= S_DIR_WAIT;
                    end

                    S_DIR_WAIT: begin
                        if (fetch_done) begin
                            if (fetch_timeout) begin
                                error_code <= 8'd5;
                                state <= S_FAIL;
                            end else begin
                                state <= S_DIR_BEGIN;
                            end
                        end
                    end

                    S_DIR_BEGIN: begin
                        if (peek_data == 8'h00) begin
                            error_code <= 8'd6;
                            state <= S_FAIL;
                        end else if ((peek_data == 8'hE5) || (peek_data == 8'h0F)) begin
                            state <= S_DIR_NEXT;
                        end else begin
                            name_index <= 4'd0;
                            name_match <= 1'b1;
                            state      <= S_DIR_NAME;
                        end
                    end

                    S_DIR_NAME: begin
                        if ((peek_data == expected_name) ||
                            ((expected_name >= "A") && (expected_name <= "Z") &&
                             (peek_data == (expected_name + 8'h20))))
                            name_match <= name_match;
                        else
                            name_match <= 1'b0;

                        if (name_index == 4'd2) begin
                            state <= S_DIR_ATTR;
                        end else begin
                            name_index <= name_index + 1'b1;
                        end
                    end

                    S_DIR_ATTR: begin
                        if (name_match && !peek_data[4] && !peek_data[3]) begin
                            if (bmp_match_count == {2'd0, image_index}) begin
                                meta_index <= 3'd0;
                                file_cluster_hi <= 16'd0;
                                file_cluster_lo <= 16'd0;
                                file_size <= 32'd0;
                                state <= S_DIR_META;
                            end else begin
                                bmp_match_count <= bmp_match_count + 1'b1;
                                state <= S_DIR_NEXT;
                            end
                        end else begin
                            state <= S_DIR_NEXT;
                        end
                    end

                    S_DIR_META: begin
                        case (meta_index)
                            3'd0: file_cluster_hi[7:0]  <= peek_data;
                            3'd1: file_cluster_hi[15:8] <= peek_data;
                            3'd2: file_cluster_lo[7:0]  <= peek_data;
                            3'd3: file_cluster_lo[15:8] <= peek_data;
                            3'd4: file_size[7:0]        <= peek_data;
                            3'd5: file_size[15:8]       <= peek_data;
                            3'd6: file_size[23:16]      <= peek_data;
                            default: file_size[31:24]   <= peek_data;
                        endcase
                        if (meta_index == 3'd7) begin
                            meta_index <= 3'd0;
                            if ({file_cluster_hi, file_cluster_lo} < 32'd2) begin
                                error_code <= 8'd6;
                                state <= S_FAIL;
                            end else begin
                                file_cluster <= {file_cluster_hi,
                                                 file_cluster_lo};
                                file_sec_in_cluster <= 8'd0;
                                file_sector_base <= 32'd0;
                                bmp_header_ready <= 1'b0;
                                state <= S_BMP_REQ;
                            end
                        end else begin
                            meta_index <= meta_index + 1'b1;
                        end
                    end

                    S_DIR_NEXT: begin
                        if (dir_entry == 4'd15) begin
                            if ((dir_sector + 1'b1) < sectors_per_cluster) begin
                                dir_sector <= dir_sector + 1'b1;
                                dir_entry  <= 4'd0;
                                state      <= S_DIR_REQ;
                            end else begin
                                fat_context <= 1'b0;
                                fat_cluster <= dir_cluster;
                                fat_byte    <= 2'd0;
                                fat_value   <= 32'd0;
                                state       <= S_FAT_REQ;
                            end
                        end else begin
                            dir_entry <= dir_entry + 1'b1;
                            state     <= S_DIR_BEGIN;
                        end
                    end

                    S_FAT_REQ: begin
                        fetch_lba   <= fat_start + (fat_cluster >> 7);
                        fetch_start <= 1'b1;
                        fat_byte    <= 2'd0;
                        fat_value   <= 32'd0;
                        state       <= S_FAT_WAIT;
                    end

                    S_FAT_WAIT: begin
                        if (fetch_done) begin
                            if (fetch_timeout) begin
                                error_code <= 8'd7;
                                state <= S_FAIL;
                            end else begin
                                state <= S_FAT_READ;
                            end
                        end
                    end

                    S_FAT_READ: begin
                        fat_value <= {fat_value[23:0], peek_data};
                        if (fat_byte == 2'd3) begin
                            fat_byte <= 2'd0;
                            state    <= S_FAT_NEXT;
                        end else begin
                            fat_byte <= fat_byte + 1'b1;
                        end
                    end

                    S_FAT_NEXT: begin
                        if ((fat_value[27:0] < 28'd2) ||
                            (fat_value[27:0] >= 28'h0FFFFFF7)) begin
                            error_code <= 8'd8;
                            state <= S_FAIL;
                        end else if (!fat_context) begin
                            dir_cluster <= {4'd0, fat_value[27:0]};
                            dir_sector  <= 8'd0;
                            dir_entry   <= 4'd0;
                            state       <= S_DIR_REQ;
                        end else begin
                            file_cluster <= {4'd0, fat_value[27:0]};
                            file_sec_in_cluster <= 8'd0;
                            state        <= S_BMP_REQ;
                        end
                    end

                    S_BMP_REQ: begin
                        fetch_lba   <= cluster_lba;
                        fetch_start <= 1'b1;
                        state       <= S_BMP_WAIT;
                    end

                    S_BMP_WAIT: begin
                        if (fetch_done) begin
                            if (fetch_timeout) begin
                                error_code <= 8'd9;
                                state <= S_FAIL;
                            end else if (!bmp_header_ready) begin
                                header_index <= 6'd0;
                                state <= S_HDR_SCAN;
                            end else begin
                                process_index <= 9'd0;
                                state <= S_PROCESS;
                            end
                        end
                    end

                    S_HDR_SCAN: begin
                        bmp_header[header_index] <= peek_data;
                        if (header_index == 6'd53) begin
                            header_index <= 6'd0;
                            state <= S_HDR_PARSE;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end

                    S_HDR_PARSE: begin
                        if ((bmp_header[0] != "B") || (bmp_header[1] != "M") ||
                            (hdr_pixel_offset < 32'd54) ||
                            (hdr_width_raw[31:16] != 16'd0) ||
                            (hdr_width_raw == 32'd0) ||
                            ({hdr_width_raw[15:0]} > 16'd640) ||
                            ((hdr_height_raw[31:16] != 16'd0) &&
                             (hdr_height_raw[31:16] != 16'hFFFF)) ||
                            (hdr_height_raw == 32'd0) ||
                            (hdr_abs_height == 16'd0) ||
                            (hdr_abs_height > 16'd480) ||
                            (hdr_planes != 16'd1) ||
                            ((hdr_bpp != 16'd24) && (hdr_bpp != 16'd32)) ||
                            (hdr_compression != 32'd0) ||
                            (file_size <= hdr_pixel_offset)) begin
                            error_code <= 8'd10;
                            state <= S_FAIL;
                        end else begin
                            bmp_data_offset    <= hdr_pixel_offset;
                            bmp_width          <= hdr_width_raw[15:0];
                            bmp_top_down       <= hdr_height_raw[31];
                            bmp_height         <= hdr_height_raw[31]
                                                ? (~hdr_height_raw[15:0] + 1'b1)
                                                : hdr_height_raw[15:0];
                            bmp_bpp            <= hdr_bpp;
                            bmp_bytes_per_pixel<= hdr_bpp[4] ? 8'd4 : 8'd3;
                            bmp_active_row_bytes <= hdr_width_raw[10:0] *
                                                  (hdr_bpp[4] ? 12'd4 : 12'd3);
                            bmp_row_stride     <= ((hdr_width_raw[10:0] *
                                                  (hdr_bpp[4] ? 12'd4 : 12'd3) +
                                                  12'd3) >> 2) << 2;
                            bmp_x_base         <= (16'd640 - hdr_width_raw[15:0]) >> 1;
                            bmp_y_base         <= (16'd480 - hdr_abs_height) >> 1;
                            row_byte_index     <= 12'd0;
                            pixel_x            <= 10'd0;
                            component_index    <= 2'd0;
                            image_file_row     <= 10'd0;
                            pixel_r            <= 8'd0;
                            pixel_g            <= 8'd0;
                            pixel_b            <= 8'd0;
                            bmp_header_ready   <= 1'b1;
                            process_index      <= 9'd0;
                            state              <= S_PROCESS;
                        end
                    end

                    S_PROCESS: begin
                        if (file_pos >= bmp_data_offset) begin
                            if (row_byte_index < bmp_active_row_bytes) begin
                                if (component_index == 2'd0)
                                    pixel_b <= peek_data;
                                else if (component_index == 2'd1)
                                    pixel_g <= peek_data;
                                else if (component_index == 2'd2)
                                    pixel_r <= peek_data;

                                if (component_index == (bmp_bytes_per_pixel[1:0] - 1'b1)) begin
                                    wr_en   <= 1'b1;
                                    wr_addr <= pixel_addr;
                                    wr_data <= {8'h00,
                                                ((bmp_bytes_per_pixel == 8'd3) ?
                                                 peek_data : pixel_r),
                                                pixel_g,
                                                pixel_b};
                                    pixel_x <= pixel_x + 1'b1;
                                    component_index <= 2'd0;
                                end else begin
                                    component_index <= component_index + 1'b1;
                                end
                            end

                            if ((row_byte_index == (bmp_row_stride - 1'b1)) &&
                                (image_file_row == (bmp_height - 10'd1))) begin
                                row_byte_index <= 12'd0;
                                pixel_x        <= 10'd0;
                                component_index<= 2'd0;
                                process_index  <= 9'd0;
                                state <= S_SUCCESS;
                            end else if (row_byte_index == (bmp_row_stride - 1'b1)) begin
                                row_byte_index <= 12'd0;
                                pixel_x        <= 10'd0;
                                component_index<= 2'd0;
                                image_file_row <= image_file_row + 1'b1;
                            end else begin
                                row_byte_index <= row_byte_index + 1'b1;
                            end
                        end

                        if (!((file_pos >= bmp_data_offset) &&
                              (row_byte_index == (bmp_row_stride - 1'b1)) &&
                              (image_file_row == (bmp_height - 10'd1))) &&
                            (process_index == 9'd511)) begin
                            process_index <= 9'd0;
                            state <= S_NEXT_SEC;
                        end else begin
                            process_index <= process_index + 1'b1;
                        end
                    end

                    S_NEXT_SEC: begin
                        if ((file_sector_base + 32'd512) >= file_size) begin
                            error_code <= 8'd11;
                            state <= S_FAIL;
                        end else if ((file_sec_in_cluster + 1'b1) <
                                     sectors_per_cluster) begin
                            file_sec_in_cluster <= file_sec_in_cluster + 1'b1;
                            file_sector_base    <= file_sector_base + 32'd512;
                            state <= S_BMP_REQ;
                        end else begin
                            fat_context <= 1'b1;
                            fat_cluster <= file_cluster;
                            fat_byte    <= 2'd0;
                            fat_value   <= 32'd0;
                            file_sector_base <= file_sector_base + 32'd512;
                            state <= S_FAT_REQ;
                        end
                    end

                    S_SUCCESS: begin
                        busy        <= 1'b0;
                        done        <= 1'b1;
                        image_error <= 1'b0;
                    end

                    S_FAIL: begin
                        clear_on_error <= 1'b1;
                        clear_phase    <= 2'd0;
                        clear_addr     <= 19'd0;
                        clear_burst    <= 9'd0;
                        clear_gap      <= 5'd0;
                        state          <= S_CLEAR;
                    end

                    S_ERROR_DONE: begin
                        busy        <= 1'b0;
                        done        <= 1'b1;
                        image_error <= 1'b1;
                    end

                    default:
                        state <= S_FAIL;
                endcase
            end
        end
    end

endmodule
