// -----------------------------------------------------------------------------
// pll_hdmi.v - 50 MHz -> 125 MHz (0 deg, feedback), 25 MHz, 125 MHz (180 deg)
// Same VCO plan as clk_wize (125 / 25) plus the 180 deg SDRAM clock.
// -----------------------------------------------------------------------------
`timescale 1 ns / 100 fs
module pll_hdmi (
    input  refclk,
    input  reset,
    output clk0_out,   // 125 MHz
    output clk1_out,   // 25 MHz
    output clk2_out,   // 125 MHz, 180 deg
    output locked
);

    wire clk0_buf;

    EG_LOGIC_BUFG bufg_feedback (
        .i (clk0_buf),
        .o (clk0_out)
    );

    EG_PHY_PLL #(
        .DPHASE_SOURCE   ("DISABLE"),
        .DYNCFG          ("DISABLE"),
        .FIN             ("50.000"),
        .FEEDBK_MODE     ("NORMAL"),
        .FEEDBK_PATH     ("CLKC0_EXT"),
        .STDBY_ENABLE    ("DISABLE"),
        .PLLRST_ENA      ("ENABLE"),
        .SYNC_ENABLE     ("DISABLE"),
        .GMC_GAIN        (2),
        .ICP_CURRENT     (9),
        .KVCO            (2),
        .LPF_CAPACITOR   (1),
        .LPF_RESISTOR    (8),
        .REFCLK_DIV      (2),
        .FBCLK_DIV       (5),
        .CLKC0_ENABLE    ("ENABLE"),
        .CLKC0_DIV       (8),
        .CLKC0_CPHASE    (7),
        .CLKC0_FPHASE    (0),
        .CLKC1_ENABLE    ("ENABLE"),
        .CLKC1_DIV       (40),
        .CLKC1_CPHASE    (39),
        .CLKC1_FPHASE    (0),
        .CLKC2_ENABLE    ("ENABLE"),
        .CLKC2_DIV       (8),
        .CLKC2_CPHASE    (3),
        .CLKC2_FPHASE    (0)
    ) pll_inst (
        .refclk   (refclk),
        .reset    (reset),
        .stdby    (1'b0),
        .extlock  (locked),
        .load_reg (1'b0),
        .psclk    (1'b0),
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (open),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'b00000000),
        .daddr    (6'b000000),
        .do       ({open, open, open, open, open, open, open, open}),
        .fbclk    (clk0_out),
        .clkc     ({open, open, clk2_out, clk1_out, clk0_buf})
    );

endmodule
