`timescale 1ns / 1ps
//-----------------------------------------------------------------------------
// AXI-Stream Video Overlay with Subtitle Bar
// Version 6.0 - 32-bit packed BRAM read, enable + SOF status registers
//-----------------------------------------------------------------------------
//
// PIPELINE OVERVIEW
//   This is a 1-stage AXI-Stream register slice (skid buffer).  The upstream
//   pixel is held in a register for exactly one clock cycle before forwarding
//   to the downstream.  This 1-cycle hold is what aligns the BRAM read result
//   (mask_rd_data, available one clock after mask_rd_en) with the stored pixel.
//
//   INPUT SIDE TRANSACTION (s_axis_fire):
//     - pixel metadata (data, in_bar, in_mask, tlast, tuser, bit_sel) latched
//     - BRAM read issued: ena=1, addra=word address for this pixel
//
//   ONE CYCLE LATER (output side):
//     - pixel_d, in_bar_d, in_mask_d, bit_sel_d all hold the stored pixel
//     - mask_rd_data holds the 32-bit word from BRAM
//     - extract mask bit: mask_rd_data[bit_sel_d]
//     - drive m_axis outputs
//
// BACKPRESSURE
//   s_axis_tready = m_axis_tready || !tvalid_d
//   The register empties (tvalid_d ? 0) when the downstream consumes the
//   held pixel and no new upstream pixel is available.  This makes
//   m_axis_tvalid deassert correctly during blanking - the bug that caused
//   a black screen in the earlier version (tvalid_d was stuck HIGH).
//
// AXI4-LITE REGISTER MAP (base address 0x43C30000 on this design)
//   Offset 0x00  reg0[15:0]  = x_start       reg0[31:16] = y_start
//   Offset 0x04  reg1[15:0]  = bar width      reg1[31:16] = bar height
//   Offset 0x08  reg2[23:0]  = bar colour     (default 0x000000 = black)
//   Offset 0x0C  reg3[23:0]  = text colour    (default 0xFFFFFF = white)
//   Offset 0x10  reg4[0]     = subtitle_enable (1 = overlay active, 0 = passthrough)
//                reg4[1]     = sof_flag (sticky; HW sets on each SOF; CPU writes 0 to clear)
//                              Poll this before writing a new bitmap to avoid tearing.
//
// MASK MEMORY INTERFACE
//   The mask memory is 32-bit packed (32 pixels per word).
//   Pixel (px, py) relative to the mask window:
//     word_addr = py * (MASK_W/32) + px/32
//     bit_sel   = px % 32
//   The overlay drives mask_rd_en + mask_rd_addr on the INPUT side.
//   mask_rd_data (32 bits) is read on the OUTPUT side one cycle later.
//   The correct bit is mask_rd_data[bit_sel_d].
//
// CLOCK DOMAINS
//   aclk       - pixel clock (~148.5 MHz for 1080p60).  Video path runs here.
//   s_axi_aclk - PS AXI bus clock (~100 MHz).  Control registers live here.
//   Two CDCs are implemented:
//     subtitle_enable  : AXI ? video   (2-FF synchroniser)
//     sof_flag         : video ? AXI   (toggle synchroniser + edge detect)
//-----------------------------------------------------------------------------

module axis_video_overlay_rect #(
    parameter DATA_WIDTH     = 24,    // pixel width (24 = RGB888)
    parameter AXI_DATA_WIDTH = 32,
    parameter AXI_ADDR_WIDTH = 6,     // 6 bits ? 16 word-aligned registers
    parameter MASK_W         = 256,   // subtitle bitmap width  (multiple of 32)
    parameter MASK_H         = 64     // subtitle bitmap height
)(
    // ---- video clock / reset ---------------------------------------------
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME video_clk, ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 video_clk CLK" *)
    input  wire                          aclk,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME video_reset, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 video_reset RST" *)
    input  wire                          aresetn,

    // ---- AXI-Stream slave (incoming video) --------------------------------
    input  wire [DATA_WIDTH-1:0]         s_axis_tdata,
    input  wire                          s_axis_tvalid,
    output wire                          s_axis_tready,
    input  wire                          s_axis_tlast,
    input  wire                          s_axis_tuser,

    // ---- AXI-Stream master (outgoing video) --------------------------------
    output wire [DATA_WIDTH-1:0]         m_axis_tdata,
    output wire                          m_axis_tvalid,
    input  wire                          m_axis_tready,
    output wire                          m_axis_tlast,
    output wire                          m_axis_tuser,

    // ---- Subtitle mask memory - Port A interface ---------------------------
    // Word-addressed (9 bits for 512-word memory).  32 pixels per word.
    // Connect to subtitle_mask_mem_0 / ena + addra + douta.
    output wire                          mask_rd_en,
    output wire [8:0]                    mask_rd_addr,
    input  wire [31:0]                   mask_rd_data,

    // ---- AXI4-Lite slave (control registers) ------------------------------
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi_ctrl, ASSOCIATED_RESET s_axi_aresetn" *)
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    input  wire                          s_axi_aclk,

    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    input  wire                          s_axi_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl AWADDR" *)
    input  wire [AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl AWVALID" *)
    input  wire                          s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl AWREADY" *)
    output wire                          s_axi_awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WDATA" *)
    input  wire [AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WSTRB" *)
    input  wire [(AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WVALID" *)
    input  wire                          s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl WREADY" *)
    output wire                          s_axi_wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl BRESP" *)
    output wire [1:0]                    s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl BVALID" *)
    output wire                          s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl BREADY" *)
    input  wire                          s_axi_bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl ARADDR" *)
    input  wire [AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl ARVALID" *)
    input  wire                          s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl ARREADY" *)
    output wire                          s_axi_arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RDATA" *)
    output wire [AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RRESP" *)
    output wire [1:0]                    s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RVALID" *)
    output wire                          s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi_ctrl RREADY" *)
    input  wire                          s_axi_rready
);

    // =========================================================================
    // Mask geometry constants
    // =========================================================================
    localparam integer WORDS_PER_ROW = MASK_W / 32;            // 8  for 256-wide
    localparam integer MEM_WORDS     = MASK_H * WORDS_PER_ROW; // 512 for 64-tall
    // WORD_ADDR_W = 9 (= $clog2(512)), matching the 9-bit mask_rd_addr port.

    // =========================================================================
    // AXI4-Lite registers (s_axi_aclk domain)
    // =========================================================================
    reg [AXI_DATA_WIDTH-1:0] reg0, reg1, reg2, reg3, reg4;

    reg axi_awready_r, axi_wready_r, axi_bvalid_r;
    reg [1:0] axi_bresp_r;
    reg axi_arready_r, axi_rvalid_r;
    reg [AXI_DATA_WIDTH-1:0] axi_rdata_r;

    assign s_axi_awready = axi_awready_r;
    assign s_axi_wready  = axi_wready_r;
    assign s_axi_bvalid  = axi_bvalid_r;
    assign s_axi_bresp   = axi_bresp_r;
    assign s_axi_arready = axi_arready_r;
    assign s_axi_rvalid  = axi_rvalid_r;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rdata   = axi_rdata_r;

    wire axi_wr_en = (!axi_awready_r) && s_axi_awvalid && s_axi_wvalid;

    // SOF pulse in AXI domain (wired in later - forward declaration)
    wire sof_pulse_axi;

    // ---- Write path --------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_awready_r <= 1'b0;
            axi_wready_r  <= 1'b0;
            axi_bvalid_r  <= 1'b0;
            axi_bresp_r   <= 2'b00;
            // Default bar: 1600×120 black bar at (x=160, y=900) for 1080p
            reg0 <= {16'd900,  16'd160};   // y_start=900,  x_start=160
            reg1 <= {16'd120,  16'd1600};  // height=120,   width=1600
            reg2 <= 32'h00000000;          // bar colour:  black
            reg3 <= 32'h00FFFFFF;          // text colour: white
            reg4 <= 32'h00000001;          // subtitle_enable=1, sof_flag=0
        end else begin
            axi_awready_r <= axi_wr_en ? 1'b1 : 1'b0;
            axi_wready_r  <= axi_wr_en ? 1'b1 : 1'b0;

            if (axi_wr_en) begin
                axi_bvalid_r <= 1'b1;
                axi_bresp_r  <= 2'b00;

                // AXI_ADDR_WIDTH=6: bits [5:2] select one of 16 word regs
                case (s_axi_awaddr[AXI_ADDR_WIDTH-1:2])
                    4'b0000: begin  // reg0: x_start / y_start
                        if (s_axi_wstrb[0]) reg0[ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) reg0[15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) reg0[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg0[31:24] <= s_axi_wdata[31:24];
                    end
                    4'b0001: begin  // reg1: width / height
                        if (s_axi_wstrb[0]) reg1[ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) reg1[15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) reg1[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg1[31:24] <= s_axi_wdata[31:24];
                    end
                    4'b0010: begin  // reg2: bar colour
                        if (s_axi_wstrb[0]) reg2[ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) reg2[15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) reg2[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg2[31:24] <= s_axi_wdata[31:24];
                    end
                    4'b0011: begin  // reg3: text colour
                        if (s_axi_wstrb[0]) reg3[ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) reg3[15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) reg3[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg3[31:24] <= s_axi_wdata[31:24];
                    end
                    4'b0100: begin  // reg4: control / status
                        // bit 0 - subtitle_enable: normal R/W
                        if (s_axi_wstrb[0] && s_axi_wdata[0] !== 1'bx)
                            reg4[0] <= s_axi_wdata[0];
                        // bit 1 - sof_flag: write-0-to-clear (HW sets it)
                        // Writing 1 here is ignored; only writing 0 clears it.
                        // HW set (below) takes priority if both happen in the
                        // same cycle.
                        if (s_axi_wstrb[0] && !s_axi_wdata[1])
                            reg4[1] <= 1'b0;
                        // bits [31:2] reserved, normal R/W for future use
                        if (s_axi_wstrb[1]) reg4[15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) reg4[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) reg4[31:24] <= s_axi_wdata[31:24];
                    end
                    default: ; // writes to unmapped addresses are dropped
                endcase
            end else if (axi_bvalid_r && s_axi_bready) begin
                axi_bvalid_r <= 1'b0;
            end

            // HW set of sof_flag - takes priority over CPU write-0-clear
            // above because this non-blocking assignment executes last in the
            // always block (Verilog semantics: last assignment wins).
            if (sof_pulse_axi)
                reg4[1] <= 1'b1;
        end
    end

    // ---- Read path ---------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_arready_r <= 1'b0;
            axi_rvalid_r  <= 1'b0;
            axi_rdata_r   <= {AXI_DATA_WIDTH{1'b0}};
        end else begin
            axi_arready_r <= (!axi_arready_r && s_axi_arvalid) ? 1'b1 : 1'b0;

            if (!axi_rvalid_r && s_axi_arvalid && axi_arready_r) begin
                case (s_axi_araddr[AXI_ADDR_WIDTH-1:2])
                    4'b0000: axi_rdata_r <= reg0;
                    4'b0001: axi_rdata_r <= reg1;
                    4'b0010: axi_rdata_r <= reg2;
                    4'b0011: axi_rdata_r <= reg3;
                    4'b0100: axi_rdata_r <= reg4;
                    default: axi_rdata_r <= {AXI_DATA_WIDTH{1'b0}};
                endcase
                axi_rvalid_r <= 1'b1;
            end else if (axi_rvalid_r && s_axi_rready) begin
                axi_rvalid_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Clock domain crossing
    // =========================================================================

    // --- subtitle_enable: AXI domain ? video domain (2-FF synchroniser) ----
    // Changes slowly (only on explicit CPU write), so a 2-FF sync is safe.
    reg [1:0] enable_sync_v;
    always @(posedge aclk) begin
        if (!aresetn) enable_sync_v <= 2'b11;  // default: enabled
        else          enable_sync_v <= {enable_sync_v[0], reg4[0]};
    end
    wire subtitle_enable = enable_sync_v[1];

    // --- sof_flag: video domain ? AXI domain (toggle synchroniser) ---------
    // A toggle register flips on every SOF in the video domain.
    // Three FFs in the AXI domain: sync2 is the stable synced value,
    // edge-detect on sync2 ^ sync1 produces a one-cycle pulse per SOF.
    reg        sof_toggle_v;
    reg [2:0]  sof_sync_a;   // 3-bit shift register in AXI domain

    always @(posedge aclk) begin
        if (!aresetn) sof_toggle_v <= 1'b0;
        else if (s_axis_tuser && s_axis_tvalid && s_axis_tready)
            sof_toggle_v <= ~sof_toggle_v;
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) sof_sync_a <= 3'b000;
        else                sof_sync_a <= {sof_sync_a[1:0], sof_toggle_v};
    end

    // One pulse per SOF in the AXI clock domain
    assign sof_pulse_axi = sof_sync_a[2] ^ sof_sync_a[1];

    // =========================================================================
    // Bar / mask geometry (combinatorial, video clock domain)
    // =========================================================================
    wire [12:0] x_start_r  = reg0[15:0];
    wire [12:0] y_start_r  = reg0[31:16];
    wire [12:0] rect_w_r   = reg1[15:0];
    wire [12:0] rect_h_r   = reg1[31:16];
    wire [12:0] x_end_r    = x_start_r + rect_w_r;
    wire [12:0] y_end_r    = y_start_r + rect_h_r;
    wire [23:0] bar_color_r  = reg2[23:0];
    wire [23:0] text_color_r = reg3[23:0];

    // =========================================================================
    // Pixel position counters (track INPUT-side transaction position)
    // =========================================================================
    reg [12:0] x;
    reg [12:0] y;

    // INPUT side handshake - pixel accepted into register
    wire s_axis_fire;

    always @(posedge aclk) begin
        if (!aresetn) begin
            x <= 13'd0;
            y <= 13'd0;
        end else if (s_axis_fire) begin
            if (s_axis_tuser) begin
                x <= 13'd0;
                y <= 13'd0;
            end else if (s_axis_tlast) begin
                x <= 13'd0;
                y <= y + 13'd1;
            end else begin
                x <= x + 13'd1;
            end
        end
    end

    // =========================================================================
    // Bar / mask window tests (combinatorial on current x, y)
    // =========================================================================
    wire in_bar_comb = (x >= x_start_r) && (x < x_end_r) &&
                       (y >= y_start_r) && (y < y_end_r);

    wire [12:0] mask_x_off   = (rect_w_r > MASK_W) ? ((rect_w_r - MASK_W) >> 1) : 13'd0;
    wire [12:0] mask_y_off   = (rect_h_r > MASK_H) ? ((rect_h_r - MASK_H) >> 1) : 13'd0;
    wire [12:0] mask_x_start = x_start_r + mask_x_off;
    wire [12:0] mask_y_start = y_start_r + mask_y_off;
    wire [12:0] mask_x_end   = mask_x_start + MASK_W;
    wire [12:0] mask_y_end   = mask_y_start + MASK_H;

    wire in_mask_comb = (x >= mask_x_start) && (x < mask_x_end) &&
                        (y >= mask_y_start) && (y < mask_y_end);

    wire [12:0] local_x = x - mask_x_start;  // pixel column within mask window
    wire [12:0] local_y = y - mask_y_start;  // pixel row    within mask window

    // 32-bit word address and bit-select for this pixel
    // word = row * words_per_row + col / 32
    // bit  = col % 32
    wire [8:0] calc_word_addr = (local_y * WORDS_PER_ROW) + (local_x >> 5);
    wire [4:0] calc_bit_sel   = local_x[4:0];

    // =========================================================================
    // BRAM read - issued on INPUT side fire, result aligned with pixel_d
    // =========================================================================
    // ena and addra are driven here; mask_rd_data comes back from the BRAM
    // one cycle after ena is asserted.  By that time the pixel has been
    // registered into pixel_d and the correct bit index sits in bit_sel_d.
    assign mask_rd_en   = s_axis_fire && in_mask_comb;
    assign mask_rd_addr = calc_word_addr;

    // =========================================================================
    // 1-stage AXI-Stream register slice (skid buffer)
    //
    // HANDSHAKE RULE:
    //   s_axis_tready = m_axis_tready || !tvalid_d
    //
    // The register updates whenever the downstream is ready to consume
    // the held pixel (m_axis_tready=1) OR the register is empty (!tvalid_d).
    // Both conditions mean the current register contents can be replaced.
    //
    // tvalid_d correctly goes LOW when the downstream consumes the held
    // pixel and no new upstream pixel is available at the same time.
    // This is what prevents the stuck-tvalid black-screen bug.
    // =========================================================================
    reg                  tvalid_d;
    reg [DATA_WIDTH-1:0] pixel_d;
    reg                  in_bar_d;
    reg                  in_mask_d;
    reg [4:0]            bit_sel_d;   // which bit in mask_rd_data is ours
    reg                  tlast_d;
    reg                  tuser_d;

    assign s_axis_tready = m_axis_tready || !tvalid_d;
    assign s_axis_fire   = s_axis_tvalid && s_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            tvalid_d  <= 1'b0;
            pixel_d   <= {DATA_WIDTH{1'b0}};
            in_bar_d  <= 1'b0;
            in_mask_d <= 1'b0;
            bit_sel_d <= 5'd0;
            tlast_d   <= 1'b0;
            tuser_d   <= 1'b0;
        end else if (m_axis_tready || !tvalid_d) begin
            // Register is available - latch tvalid and, if a new pixel
            // arrived, latch its data too.
            tvalid_d <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                pixel_d   <= s_axis_tdata;
                in_bar_d  <= in_bar_comb;
                in_mask_d <= in_mask_comb;
                bit_sel_d <= calc_bit_sel;
                tlast_d   <= s_axis_tlast;
                tuser_d   <= s_axis_tuser;
            end
        end
        // else: downstream stall - hold everything until tready goes high
    end

    // =========================================================================
    // Output pixel mux
    //   subtitle_enable gated: if disabled, pure passthrough.
    //   mask_rd_data[bit_sel_d] extracts the single pixel bit from the
    //   32-bit BRAM word; this bit arrived aligned with pixel_d/in_mask_d.
    // =========================================================================
    wire mask_bit = mask_rd_data[bit_sel_d];

    wire [DATA_WIDTH-1:0] overlay_pixel =
        (in_mask_d && mask_bit) ? text_color_r :
        (in_bar_d)              ? bar_color_r  :
                                  pixel_d;

    assign m_axis_tdata  = subtitle_enable ? overlay_pixel : pixel_d;
    assign m_axis_tvalid = tvalid_d;
    assign m_axis_tlast  = tlast_d;
    assign m_axis_tuser  = tuser_d;

endmodule
