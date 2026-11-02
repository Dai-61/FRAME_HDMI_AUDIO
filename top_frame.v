`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// HX4S20: TF-card BMP image -> SDRAM frame buffer -> 640x480 HDMI
//
// Data path:
//   1. image_loader finds IMAGEn.BMP on a FAT32 card and decodes it into SDRAM.
//   2. line_loader reads one line into a ping-pong line buffer while the
//      previous line is being displayed.
//   3. 640x480 video timing reads the line buffer at 25MHz.
//   4. official HDMI TX sends TMDS.
// -----------------------------------------------------------------------------
module top_frame (
    input  wire       clk,
    input  wire       rst_n,

    output wire       hdmi_clk_p,
    output wire       hdmi_d0_p,
    output wire       hdmi_d1_p,
    output wire       hdmi_d2_p,

    output wire       vga_hs,
    output wire       vga_vs,
    output wire [4:0] vga_r,
    output wire [5:0] vga_g,
    output wire [4:0] vga_b,

    output wire [3:0] key_row,
    input  wire [3:0] key_col,

    output wire       sd_ncs,
    output wire       sd_dclk,
    output wire       sd_mosi,
    input  wire       sd_miso,

    output wire       led
);

    localparam integer H_ACTIVE = 640;
    localparam integer H_FP     = 16;
    localparam integer H_SYNC   = 96;
    localparam integer H_BP     = 48;
    localparam integer H_TOTAL  = 800;

    localparam integer V_ACTIVE = 480;
    localparam integer V_FP     = 10;
    localparam integer V_SYNC   = 2;
    localparam integer V_BP     = 33;
    localparam integer V_TOTAL  = 525;

    wire clk125;
    wire clk25;
    wire clk125_180;
    wire locked;

    pll_hdmi u_pll (
        .refclk  (clk),
        .reset   (!rst_n),
        .clk0_out(clk125),
        .clk1_out(clk25),
        .clk2_out(clk125_180),
        .locked  (locked)
    );

    wire rst = !rst_n || !locked;

    // ---------------- SDRAM ----------------
    wire        sdr_init_done;
    wire        sdr_init_ref_vld;
    wire        sdr_busy;

    wire        wr_en;
    wire [20:0] wr_addr;
    wire [31:0] wr_data;
    wire [3:0]  wr_dm;

    wire        rd_en;
    wire [20:0] rd_addr;
    wire        rd_valid;
    wire [31:0] rd_data;

    wire        sdram_clk;
    wire        sdram_ras_n;
    wire        sdram_cas_n;
    wire        sdram_we_n;
    wire [10:0] sdram_addr;
    wire [1:0]  sdram_ba;
    wire [3:0]  sdram_dm;
    wire [31:0] sdram_dq;

    // Refresh: 4096 rows must be refreshed within 64 ms, i.e. one every
    // ~15.6 us. Frames that are not being read would otherwise decay.
    // App_ref_req must be a one-clock pulse; holding it high can issue
    // overlapping refresh commands.
    reg [10:0] ref_cnt;
    always @(posedge clk125 or posedge rst) begin
        if (rst)
            ref_cnt <= 11'd0;
        else if (!sdr_init_done)
            ref_cnt <= 11'd0;
        else if (ref_cnt == 11'd1949)
            ref_cnt <= 11'd0;
        else
            ref_cnt <= ref_cnt + 1'b1;
    end
    wire ref_req = (ref_cnt == 11'd1949);

    sdr_as_ram #(
        // Refresh is issued explicitly above so the app interface owns the
        // cadence and there is no overlap with the controller's timer.
        .self_refresh_open (1'b0)
    ) u_sdr (
        .Sdr_clk          (clk125),
        .Sdr_clk_sft      (clk125_180),
        .Rst              (rst),
        .Sdr_init_done    (sdr_init_done),
        .Sdr_init_ref_vld (sdr_init_ref_vld),
        .Sdr_busy         (sdr_busy),
        .App_ref_req      (ref_req),
        .App_wr_en        (wr_en),
        .App_wr_addr      (wr_addr),
        .App_wr_dm        (wr_dm),
        .App_wr_din       (wr_data),
        .App_rd_en        (rd_en),
        .App_rd_addr      (rd_addr),
        .Sdr_rd_en        (rd_valid),
        .Sdr_rd_dout      (rd_data),
        .SDRAM_CLK        (sdram_clk),
        .SDR_RAS          (sdram_ras_n),
        .SDR_CAS          (sdram_cas_n),
        .SDR_WE           (sdram_we_n),
        .SDR_BA           (sdram_ba),
        .SDR_ADDR         (sdram_addr),
        .SDR_DM           (sdram_dm),
        .SDR_DQ           (sdram_dq)
    );

    EG_PHY_SDRAM_2M_32 u_sdram (
        .clk   (sdram_clk),
        .ras_n (sdram_ras_n),
        .cas_n (sdram_cas_n),
        .we_n  (sdram_we_n),
        .addr  (sdram_addr[10:0]),
        .ba    (sdram_ba),
        .dq    (sdram_dq),
        .cs_n  (1'b0),
        .dm0   (sdram_dm[0]),
        .dm1   (sdram_dm[1]),
        .dm2   (sdram_dm[2]),
        .dm3   (sdram_dm[3]),
        .cke   (1'b1)
    );

    // ---------------- TF-card image loader ----------------
    wire       frame_written;
    wire       image_busy;
    wire       image_error;
    wire [7:0] image_error_code;
    reg        image_start;
    reg        image_start_pending;
    reg        start_req;
    reg  [1:0] load_image_index;

    image_loader u_image (
        .clk             (clk125),
        .rst             (rst),
        .start           (image_start),
        .image_index     (load_image_index),
        .sdr_init_done   (sdr_init_done),
        .wr_en           (wr_en),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .wr_dm           (wr_dm),
        .busy            (image_busy),
        .done            (frame_written),
        .image_error     (image_error),
        .error_code      (image_error_code),
        .sd_ncs          (sd_ncs),
        .sd_dclk         (sd_dclk),
        .sd_mosi         (sd_mosi),
        .sd_miso         (sd_miso)
    );

    // ---------------- ping-pong line buffers ----------------
    reg [23:0] lb0 [0:639];
    reg [23:0] lb1 [0:639];

    wire        lb_we;
    wire [9:0]  lb_waddr;
    wire [23:0] lb_wdata;
    reg         load_page;

    always @(posedge clk125) begin
        if (lb_we) begin
            if (load_page)
                lb1[lb_waddr] <= lb_wdata;
            else
                lb0[lb_waddr] <= lb_wdata;
        end
    end

    // ---------------- line loader ----------------
    wire        ll_rd_en;
    wire [20:0] ll_rd_addr;
    wire        ll_done;
    wire        ll_busy;

    reg         load_start;
    reg  [8:0]  load_line_r;
    reg  [8:0]  load_line_sel;
    reg         load_page_sel;

    wire        key_press;
    wire [3:0]  key_code;

    keypad_ctrl #(
        .SCAN_CNT (25_000)
    ) u_keys (
        .clk       (clk25),
        .rst_n     (~rst),
        .row       (key_row),
        .col       (key_col),
        .key_press (key_press),
        .key_code  (key_code)
    );

    reg [1:0] desired_image;
    reg       image_request_t;

    always @(posedge clk25 or posedge rst) begin
        if (rst) begin
            desired_image    <= 2'd0;
            image_request_t  <= 1'b0;
        end else if (key_press) begin
            if (key_code <= 4'd3)
                desired_image <= key_code[1:0];
            else if (key_code == 4'd13)
                desired_image <= desired_image - 1'b1;
            else if (key_code == 4'd14)
                desired_image <= desired_image + 1'b1;

            if ((key_code <= 4'd3) || (key_code == 4'd13) ||
                (key_code == 4'd14) || (key_code == 4'd15))
                image_request_t <= ~image_request_t;
        end
    end

    reg [1:0] image_index_meta;
    reg [1:0] image_index_sync;
    reg [1:0] image_req_sync;
    wire image_req_edge = image_req_sync[1] ^ image_req_sync[0];

    always @(posedge clk125 or posedge rst) begin
        if (rst) begin
            image_start         <= 1'b0;
            image_start_pending <= 1'b1;
            load_image_index    <= 2'd0;
            image_index_meta    <= 2'd0;
            image_index_sync    <= 2'd0;
            image_req_sync      <= 2'd0;
        end else begin
            image_start      <= 1'b0;
            image_index_meta <= desired_image;
            image_index_sync <= image_index_meta;
            image_req_sync   <= {image_req_sync[0], image_request_t};

            if (!sdr_init_done)
                image_start_pending <= 1'b1;
            else if (image_req_edge)
                image_start_pending <= 1'b1;

            if (image_start_pending && sdr_init_done &&
                !image_busy && !ll_busy && !start_req) begin
                load_image_index    <= image_index_sync;
                image_start         <= 1'b1;
                image_start_pending <= 1'b0;
            end
        end
    end

    assign rd_en   = ll_rd_en;
    assign rd_addr = ll_rd_addr;

    line_loader u_ll (
        .clk        (clk125),
        .rst        (rst),
        .start      (load_start),
        .line       (load_line_r),
        .frame_base (21'd0),
        .rd_en      (ll_rd_en),
        .rd_addr    (ll_rd_addr),
        .rd_valid   (rd_valid),
        .rd_data    (rd_data),
        .done       (ll_done),
        .busy       (ll_busy),
        .wr_en      (lb_we),
        .wr_addr    (lb_waddr),
        .wr_data    (lb_wdata)
    );

    // ---------------- load control ----------------
    reg        startup_phase;
    reg        startup_done;

    reg [1:0]  req_sync;
    reg        req_t;

    wire req_edge = req_sync[1] ^ req_sync[0];

    always @(posedge clk125 or posedge rst) begin
        if (rst) begin
            req_sync      <= 2'd0;
            load_start    <= 1'b0;
            start_req     <= 1'b0;
            startup_phase <= 1'b1;
            startup_done  <= 1'b0;
            load_line_r   <= 9'd0;
            load_page     <= 1'b0;
        end else begin
            req_sync  <= {req_sync[0], req_t};
            load_start <= 1'b0;

            if (!frame_written) begin
                startup_phase <= 1'b1;
                startup_done  <= 1'b0;
                start_req     <= 1'b0;
            end else if (startup_phase && !start_req && !ll_busy &&
                         !image_start && !image_busy) begin
                load_line_r <= 9'd0;
                load_page   <= 1'b0;
                start_req   <= 1'b1;
            end else if (req_edge && !start_req && !ll_busy &&
                         !image_start && !image_busy) begin
                load_line_r <= load_line_sel;
                load_page   <= load_page_sel;
                start_req   <= 1'b1;
            end

            if (start_req && frame_written && !ll_busy &&
                !image_start && !image_busy) begin
                load_start <= 1'b1;
                start_req  <= 1'b0;
            end

            if (ll_done && startup_phase) begin
                startup_phase <= 1'b0;
                startup_done  <= 1'b1;
            end
        end
    end

    // ---------------- video timing ----------------
    reg [10:0] hcnt;
    reg [10:0] vcnt;
    reg        video_en;

    reg [1:0]  done_sync;
    reg [1:0]  busy_sync;
    reg [1:0]  frame_ready_sync;

    always @(posedge clk25 or posedge rst) begin
        if (rst) begin
            hcnt       <= 11'd0;
            vcnt       <= 11'd0;
            video_en   <= 1'b0;
            req_t      <= 1'b0;
            done_sync  <= 2'd0;
            busy_sync  <= 2'd0;
            frame_ready_sync <= 2'd0;
            load_line_sel <= 9'd0;
            load_page_sel <= 1'b0;
        end else begin
            done_sync <= {done_sync[0], startup_done};
            busy_sync <= {busy_sync[0], ll_busy};
            frame_ready_sync <= {frame_ready_sync[0], frame_written};

            if (!frame_ready_sync[1]) begin
                hcnt     <= 11'd0;
                vcnt     <= 11'd0;
                video_en <= 1'b0;
                req_t    <= 1'b0;
            end else if (!video_en) begin
                if (done_sync[1])
                    video_en <= 1'b1;
            end else if (hcnt == H_TOTAL - 1) begin
                hcnt <= 11'd0;
                if (vcnt == V_TOTAL - 1)
                    vcnt <= 11'd0;
                else
                    vcnt <= vcnt + 1'b1;
            end else begin
                hcnt <= hcnt + 1'b1;
            end

            // Start loading the next line while the current line is displayed.
            if (video_en && (vcnt < V_ACTIVE) &&
                (hcnt == 11'd512) && !busy_sync[1]) begin
                req_t         <= ~req_t;
                load_line_sel <= (vcnt == V_ACTIVE - 1) ? 9'd0 : (vcnt + 1'b1);
                load_page_sel <= ~vcnt[0];
            end
        end
    end

    wire hs = ~((hcnt >= H_ACTIVE + H_FP) &&
                (hcnt <  H_ACTIVE + H_FP + H_SYNC));

    wire vs = ~((vcnt >= V_ACTIVE + V_FP) &&
                (vcnt <  V_ACTIVE + V_FP + V_SYNC));

    wire de = video_en && (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

    reg [23:0] pixel;
    wire [9:0] pix_addr = (hcnt < H_ACTIVE) ? hcnt[9:0] : 10'd0;

    always @(posedge clk25) begin
        if (vcnt[0])
            pixel <= lb1[pix_addr];
        else
            pixel <= lb0[pix_addr];
    end

    // The line buffer has one clock of read latency. Delay the stream
    // controls by exactly one clock so all 640 pixels stay in one line.
    reg de_d, vs_d;
    always @(posedge clk25 or posedge rst) begin
        if (rst) begin
            de_d <= 1'b0;
            vs_d <= 1'b0;
        end else begin
            de_d <= de;
            vs_d <= vs;
        end
    end

    wire [23:0] rgb = de ? pixel : 24'h000000;

    assign vga_hs = hs;
    assign vga_vs = vs;
    assign vga_r  = rgb[23:19];
    assign vga_g  = rgb[15:10];
    assign vga_b  = rgb[7:3];

    // ---------------- AXI-Stream video packer ----------------
    wire        axis_user, axis_valid, axis_last, axis_ready;
    wire [23:0] axis_data;

    video_rgb_to_axis_640x480 u_axis (
        .I_clk(clk25), .I_rst(rst),
        .I_vs(vs_d), .I_de(de_d), .I_rgb(pixel),
        .O_video_user(axis_user), .O_video_valid(axis_valid),
        .O_video_last(axis_last), .O_video_data(axis_data)
    );

    // ---------------- audio tone + ACR ----------------
    wire        audio_valid, acr_valid;
    wire [23:0] audio_l, audio_r;
    wire [19:0] acr_cts, acr_n;

    hdmi_audio_tone_pcm_scale #(
        .CLK_FREQ_HZ(25_000_000), .SAMPLE_RATE_HZ(48_000)
    ) u_tone (
        .I_clk(clk25), .I_rst(rst),
        .O_audio_valid(audio_valid),
        .O_audio_left_data(audio_l), .O_audio_right_data(audio_r)
    );

    audio_arc_calculate #(.ACR_N(6144)) u_arc (
        .I_clk(clk25), .I_rst(rst), .I_audio_valid(audio_valid),
        .O_acr_valid(acr_valid), .O_acr_cts(acr_cts), .O_acr_n(acr_n)
    );

    // ---------------- HDMI 1.4b core with audio ----------------
    wire [9:0] tmds0, tmds1, tmds2, tmdsc;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),
        .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
        .VIDEO_VIC(1), .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"),
        .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
    ) u_hdmi_core (
        .I_pixel_clk(clk25), .I_rst(rst),
        .I_edid_read_trig(1'b0),
        .O_edid_read_valid(), .O_edid_read_data(),
        .I_axis_s_user(axis_user), .I_axis_s_valid(axis_valid),
        .I_axis_s_last(axis_last), .I_axis_s_data(axis_data),
        .O_axis_s_ready(axis_ready),
        .I_audio_valid(audio_valid),
        .I_audio_left_data(audio_l), .I_audio_right_data(audio_r),
        .I_acr_valid(acr_valid), .I_acr_cts(acr_cts), .I_acr_n(acr_n),
        .O_video_locked(),
        .O_ddc_scl(), .IO_ddc_sda(),
        .O_ch0_tmds_data(tmds0), .O_ch1_tmds_data(tmds1),
        .O_ch2_tmds_data(tmds2), .O_clk_tmds_data(tmdsc)
    );

    hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy (
        .I_pixel_clk(clk25), .I_serial_clk(clk125), .I_rst(rst),
        .I_tmds_channel_0(tmds0), .I_tmds_channel_1(tmds1),
        .I_tmds_channel_2(tmds2), .I_tmds_channel_clk(tmdsc),
        .O_tmds_ch0_p(hdmi_d0_p), .O_tmds_ch1_p(hdmi_d1_p),
        .O_tmds_ch2_p(hdmi_d2_p), .O_tmds_clk_p(hdmi_clk_p)
    );

    reg [24:0] hb;

    always @(posedge clk25 or posedge rst) begin
        if (rst)
            hb <= 25'd0;
        else
            hb <= hb + 1'b1;
    end

    // Slow blink while loading, fast blink after an image/FAT error, and a
    // steady on LED after a successful image load.
    assign led = !frame_written ? hb[23] :
                 image_error    ? hb[22] :
                                  1'b1;

endmodule

`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// frame_wr.v : write FOUR 640x480 test frames into SDRAM once.
// frame 0: red-green gradient
// frame 1: green-blue gradient
// frame 2: blue-red gradient
// frame 3: 8 colour bars
// Pixel word = {8'h00, R[7:0], G[7:0], B[7:0]}, low 24 bits valid.
// -----------------------------------------------------------------------------
module frame_wr #(
    parameter integer WIDTH     = 640,
    parameter integer HEIGHT    = 480,
    parameter integer FRAMES    = 4,
    parameter [8:0]   BURST_END = 9'd255,
    parameter [15:0]  BURST_GAP = 16'd24,
    parameter [15:0]  DRAIN_CYC = 16'd511
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        init_done,
    output wire        wr_en,
    output wire [20:0] wr_addr,
    output wire [31:0] wr_data,
    output wire [3:0]  wr_dm,
    output reg         done
);

    localparam [20:0] TOTAL = FRAMES * WIDTH * HEIGHT;
    localparam [1:0] S_IDLE = 2'd0, S_WR = 2'd1, S_GAP = 2'd2, S_DRAIN = 2'd3;

    reg [1:0]  state;
    reg [9:0]  x;
    reg [8:0]  y;
    reg [1:0]  f;
    reg [20:0] addr;
    reg [8:0]  burst;
    reg [15:0] gap;
    reg        last;

    reg [23:0] rgb;

    always @(*) begin
        case (f)
            2'd0: rgb = {x[9:2], y[8:1], 8'h00};
            2'd1: rgb = {8'h00, x[9:2], y[8:1]};
            2'd2: rgb = {y[8:1], 8'h00, x[9:2]};
            default: begin
                if      (x < 10'd80)  rgb = 24'hFFFFFF;
                else if (x < 10'd160) rgb = 24'hFFFF00;
                else if (x < 10'd240) rgb = 24'h00FFFF;
                else if (x < 10'd320) rgb = 24'h00FF00;
                else if (x < 10'd400) rgb = 24'hFF00FF;
                else if (x < 10'd480) rgb = 24'hFF0000;
                else if (x < 10'd560) rgb = 24'h0000FF;
                else                  rgb = 24'h000000;
            end
        endcase
    end

    assign wr_en   = (state == S_WR);
    assign wr_addr = addr;
    assign wr_data = {8'h00, rgb};
    assign wr_dm   = 4'h0;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            x     <= 10'd0;
            y     <= 9'd0;
            f     <= 2'd0;
            addr  <= 21'd0;
            burst <= 9'd0;
            gap   <= 16'd0;
            last  <= 1'b0;
            done  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (init_done && !done) begin
                        x     <= 10'd0;
                        y     <= 9'd0;
                        f     <= 2'd0;
                        addr  <= 21'd0;
                        burst <= 9'd0;
                        last  <= 1'b0;
                        state <= S_WR;
                    end
                end

                S_WR: begin
                    if (x == WIDTH - 1) begin
                        x <= 10'd0;
                        if (y == HEIGHT - 1) begin
                            y <= 9'd0;
                            f <= f + 1'b1;
                        end else begin
                            y <= y + 1'b1;
                        end
                    end else begin
                        x <= x + 1'b1;
                    end

                    if (addr == TOTAL - 1) begin
                        last  <= 1'b1;
                        gap   <= BURST_GAP;
                        state <= S_GAP;
                    end else if (burst == BURST_END) begin
                        addr  <= addr + 1'b1;
                        burst <= 9'd0;
                        gap   <= BURST_GAP;
                        state <= S_GAP;
                    end else begin
                        addr  <= addr + 1'b1;
                        burst <= burst + 1'b1;
                    end
                end

                S_GAP: begin
                    if (gap != 16'd0)
                        gap <= gap - 1'b1;
                    else if (last) begin
                        gap   <= DRAIN_CYC;
                        state <= S_DRAIN;
                    end else begin
                        state <= S_WR;
                    end
                end

                S_DRAIN: begin
                    if (gap != 16'd0)
                        gap <= gap - 1'b1;
                    else begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// line_loader.v
// Reads one 640-pixel line from SDRAM and writes it into a line buffer.
// Control is in the 125 MHz SDRAM clock domain.
// -----------------------------------------------------------------------------
module line_loader #(
    parameter integer WIDTH = 640
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [8:0]  line,
    input  wire [20:0] frame_base,

    output reg         rd_en,
    output wire [20:0] rd_addr,
    input  wire        rd_valid,
    input  wire [31:0] rd_data,

    output reg         done,
    output reg         busy,

    output reg         wr_en,
    output reg  [9:0]  wr_addr,
    output reg  [23:0] wr_data
);

    reg [9:0]  issue_cnt;
    reg [9:0]  valid_cnt;
    reg [8:0]  line_r;
    reg [20:0] base_r;

    // line * 640 = (line << 9) + (line << 7)
    wire [20:0] line_off = ({12'd0, line_r} << 9) + ({12'd0, line_r} << 7);

    assign rd_addr = base_r + line_off + issue_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_en     <= 1'b0;
            done      <= 1'b0;
            busy      <= 1'b0;
            wr_en     <= 1'b0;
            wr_addr   <= 10'd0;
            wr_data   <= 24'd0;
            issue_cnt <= 10'd0;
            valid_cnt <= 10'd0;
            line_r    <= 9'd0;
            base_r    <= 21'd0;
        end else if (start && !busy) begin
            line_r    <= line;
            base_r    <= frame_base;
            issue_cnt <= 10'd0;
            valid_cnt <= 10'd0;
            rd_en     <= 1'b1;
            busy      <= 1'b1;
            done      <= 1'b0;
            wr_en     <= 1'b0;
        end else if (busy) begin
            if (rd_en) begin
                if (issue_cnt == WIDTH - 1)
                    rd_en <= 1'b0;
                else
                    issue_cnt <= issue_cnt + 1'b1;
            end

            if (rd_valid) begin
                wr_en   <= 1'b1;
                wr_addr <= valid_cnt;
                wr_data <= rd_data[23:0];

                if (valid_cnt == WIDTH - 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    wr_en <= 1'b0;
                end else begin
                    valid_cnt <= valid_cnt + 1'b1;
                end
            end else begin
                wr_en <= 1'b0;
            end
        end
    end
endmodule

`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// keypad_ctrl.v : 4x4 matrix keypad scan + debounce
//
// row[3:0] drives one row low at a time.
// col[3:0] has pull-ups; a pressed key pulls its column low.
// key_code = row*4 + col, 0..15.
// key_press is a one-clock pulse when a new stable key is pressed.
// -----------------------------------------------------------------------------
module keypad_ctrl #(
    parameter integer SCAN_CNT        = 25_000, // 1ms per row at 25MHz
    parameter integer DEBOUNCE_FRAMES = 5       // 5 frames * 4ms = 20ms
)(
    input  wire       clk,
    input  wire       rst_n,

    output reg  [3:0] row,
    input  wire [3:0] col,

    output reg        key_press,
    output reg  [3:0] key_code
);

    localparam integer DCW = (DEBOUNCE_FRAMES <= 2) ? 1 : $clog2(DEBOUNCE_FRAMES);

    reg [15:0] scan_cnt;
    reg [1:0]  scan_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt <= 16'd0;
            scan_idx <= 2'd0;
        end else if (scan_cnt == SCAN_CNT - 1) begin
            scan_cnt <= 16'd0;
            scan_idx <= scan_idx + 1'b1;
        end else begin
            scan_cnt <= scan_cnt + 1'b1;
        end
    end

    always @(*) begin
        case (scan_idx)
            2'd0: row = 4'b1110;
            2'd1: row = 4'b1101;
            2'd2: row = 4'b1011;
            2'd3: row = 4'b0111;
            default: row = 4'b1111;
        endcase
    end

    reg [3:0] col_meta;
    reg [3:0] col_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_meta <= 4'b1111;
            col_sync <= 4'b1111;
        end else begin
            col_meta <= col;
            col_sync <= col_meta;
        end
    end

    wire row_tick = (scan_cnt == SCAN_CNT - 1);

    reg        found;
    reg [3:0]  code;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            found <= 1'b0;
            code  <= 4'd0;
        end else if (row_tick) begin
            if (col_sync != 4'b1111) begin
                found <= 1'b1;
                if      (!col_sync[0]) code <= {scan_idx, 2'd0};
                else if (!col_sync[1]) code <= {scan_idx, 2'd1};
                else if (!col_sync[2]) code <= {scan_idx, 2'd2};
                else                   code <= {scan_idx, 2'd3};
            end
        end else if ((scan_idx == 2'd0) && (scan_cnt == 16'd0)) begin
            found <= 1'b0;
            code  <= 4'd0;
        end
    end

    reg       frame_tick;
    reg [4:0] scan_code;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_tick <= 1'b0;
            scan_code  <= 5'h1F;
        end else begin
            frame_tick <= (scan_idx == 2'd3) && row_tick;
            if (frame_tick)
                scan_code <= found ? {1'b0, code} : 5'h1F;
        end
    end

    reg [4:0]   stable_code;
    reg [4:0]   stable_code_d;
    reg [DCW-1:0] same_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_code   <= 5'h1F;
            stable_code_d <= 5'h1F;
            same_cnt      <= {DCW{1'b0}};
        end else begin
            stable_code_d <= stable_code;
            if (frame_tick) begin
                if (scan_code == stable_code) begin
                    same_cnt <= {DCW{1'b0}};
                end else if (same_cnt == DEBOUNCE_FRAMES - 1) begin
                    stable_code <= scan_code;
                    same_cnt    <= {DCW{1'b0}};
                end else begin
                    same_cnt <= same_cnt + 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_press <= 1'b0;
            key_code  <= 4'd0;
        end else begin
            key_press <= (stable_code != 5'h1F) && (stable_code_d == 5'h1F);
            if ((stable_code != 5'h1F) && (stable_code_d == 5'h1F))
                key_code <= stable_code[3:0];
        end
    end

endmodule
