
module video_rgb_to_axis_640x480(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

reg        S_vs_1d;
reg        S_frame_arm;
reg [9:0]  S_x_cnt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 10'd0;
        O_video_user  <= 1'b0;
        O_video_valid <= 1'b0;
        O_video_last  <= 1'b0;
        O_video_data  <= 24'd0;
    end
    else begin
        S_vs_1d <= I_vs;

        O_video_user  <= 1'b0;
        O_video_valid <= I_de;
        O_video_last  <= I_de && (S_x_cnt == 10'd639);
        O_video_data  <= I_rgb;

        // Arm SOF on any VS transition. The first pixel of the next active
        // line is then sent with TUSER.
        if (S_vs_1d != I_vs)
            S_frame_arm <= 1'b1;

        if (I_de) begin
            O_video_user <= (S_x_cnt == 10'd0) && S_frame_arm;
            if (S_x_cnt == 10'd639)
                S_x_cnt <= 10'd0;
            else
                S_x_cnt <= S_x_cnt + 10'd1;

            if ((S_x_cnt == 10'd0) && S_frame_arm)
                S_frame_arm <= 1'b0;
        end
        else begin
            S_x_cnt <= 10'd0;
        end
    end
end

endmodule
