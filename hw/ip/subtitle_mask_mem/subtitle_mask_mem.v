`timescale 1ns / 1ps
//-----------------------------------------------------------------------------
// Subtitle Mask Memory - True Dual-Port BRAM, 32-bit packed, 1bpp
//-----------------------------------------------------------------------------
//
// Stores a monochrome subtitle bitmap as 32 pixels per word.
//   MASK_W=256, MASK_H=64  ?  512 words × 32 bits = 2 KB
//
// PORT A - video read side (pixel clock domain, aclk)
//   Synchronous read: one clock after ena+addra, douta carries the 32-bit
//   word containing the requested pixel.  douta HOLDS when ena=0 (no clear),
//   which is essential for correct behaviour during AXI-Stream backpressure.
//   Port A is read-only; no write port is exposed.
//
// PORT B - CPU write/read side (AXI BRAM Controller clock domain, clkb)
//   Xilinx AXI BRAM Controller (PG078) drives this port directly.
//   addrb is a BYTE address (matching the AXI byte-address convention).
//   The two LSBs (byte offset within a 32-bit word) are stripped internally.
//   web[3:0] are byte-enables: web[0]=byte 0 (bits 7:0), etc.
//   Pixel 0 of each 32-pixel group sits in bit 0 of its word.
//   Pixel 31 sits in bit 31.  Memory is laid out row-major:
//     pixel(px,py) ? word = py*WORDS_PER_ROW + px/32, bit = px%32
//
// Parameters:
//   MASK_W  - width of bitmap in pixels (must be a multiple of 32).
//   MASK_H  - height of bitmap in pixels.
//
// Derived (do not override):
//   WORDS_PER_ROW = MASK_W / 32
//   MEM_WORDS     = MASK_H * WORDS_PER_ROW
//   WORD_ADDR_W   = $clog2(MEM_WORDS)          ? Port A address width
//   BYTE_ADDR_W   = $clog2(MEM_WORDS * 4)      ? Port B address width
//-----------------------------------------------------------------------------

module subtitle_mask_mem #(
    parameter integer MASK_W = 256,   // must be divisible by 32
    parameter integer MASK_H = 64
)(
    // ------------------------------------------------------------------
    // Port A - video read (pixel clock domain)
    // ------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clka CLK" *)
    input  wire        clka,

    input  wire        ena,           // read enable (active high)
    input  wire [8:0]  addra,         // word address  (9 bits for 512 words)
    output reg  [31:0] douta,         // 32-bit read data (1-cycle latency)

    // ------------------------------------------------------------------
    // Port B - CPU read/write (AXI BRAM Controller domain)
    // ------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clkb CLK" *)
    input  wire        clkb,

    input  wire        rstb,          // synchronous reset, active HIGH
                                      // (AXI BRAM Controller drives this)
    input  wire        enb,           // port B enable
    input  wire [3:0]  web,           // byte write-enables (one per byte lane)
    input  wire [12:0] addrb,         // BYTE address from AXI BRAM Controller
                                      // bits [10:2] = word index into 512-word
                                      // memory; bits [14:11] always 0 within
                                      // the mapped 4 KB window, safely ignored
    input  wire [31:0] dinb,          // write data
    output reg  [31:0] doutb          // read data (1-cycle latency)
);

    // ------------------------------------------------------------------
    // Derived parameters (informational - do not change)
    // ------------------------------------------------------------------
    localparam integer WORDS_PER_ROW = MASK_W / 32;           // 8 for MASK_W=256
    localparam integer MEM_WORDS     = MASK_H * WORDS_PER_ROW;// 512
    // WORD_ADDR_W = 9, BYTE_ADDR_W = 11 - widths match port declarations above

    // ------------------------------------------------------------------
    // BRAM storage - one 32-bit word per memory location.
    // Vivado will infer this as a true dual-port 18K or 36K BRAM.
    // The separate always blocks on clka / clkb are the key inference hint.
    // ------------------------------------------------------------------
    (* ram_style = "block" *) reg [31:0] mem [0:MEM_WORDS-1];

    // ------------------------------------------------------------------
    // Debug pattern - pre-loaded at synthesis/simulation time.
    // Two horizontal bands that look like subtitle placeholder lines,
    // centred inside the mask area.  Remove or replace once CPU writes work.
    //
    // Pixel (px,py) is set by: mem[py*WORDS_PER_ROW + px/32][px%32] = 1
    // ------------------------------------------------------------------
    integer init_i, init_row, init_col, init_word, init_bit;

    initial begin
        // Clear all words
        for (init_i = 0; init_i < MEM_WORDS; init_i = init_i + 1)
            mem[init_i] = 32'h0000_0000;

        // Band 1: rows 20-27, cols 40-215
        for (init_row = 20; init_row < 28; init_row = init_row + 1) begin
            for (init_col = 40; init_col < 216; init_col = init_col + 1) begin
                init_word = init_row * WORDS_PER_ROW + init_col / 32;
                init_bit  = init_col % 32;
                mem[init_word] = mem[init_word] | (32'b1 << init_bit);
            end
        end

        // Band 2: rows 36-43, cols 60-195
        for (init_row = 36; init_row < 44; init_row = init_row + 1) begin
            for (init_col = 60; init_col < 196; init_col = init_col + 1) begin
                init_word = init_row * WORDS_PER_ROW + init_col / 32;
                init_bit  = init_col % 32;
                mem[init_word] = mem[init_word] | (32'b1 << init_bit);
            end
        end
    end

    // ------------------------------------------------------------------
    // Port A - synchronous read, no write.
    // douta HOLDS its value when ena=0 (no else/reset clause).
    // This is deliberate: the overlay pipeline may stall (AXI backpressure)
    // after a read, and douta must remain valid throughout the stall.
    // Omitting the reset on douta also allows Vivado to map the output
    // register directly into the BRAM primitive's native output register
    // (better timing, lower resource usage).
    // ------------------------------------------------------------------
    always @(posedge clka) begin
        if (ena)
            douta <= mem[addra];
        // else: hold - no assignment
    end

    // ------------------------------------------------------------------
    // Port B - synchronous read+write with byte enables.
    // addrb[10:2] is the 9-bit word address (strips AXI byte-offset bits).
    // READ_FIRST behaviour: doutb reflects the value BEFORE this cycle's
    // write (matches Xilinx BRAM primitive default).
    // rstb is the active-high reset from the AXI BRAM Controller; it
    // clears only the output register, not the stored data.
    // ------------------------------------------------------------------
    always @(posedge clkb) begin
        if (rstb) begin
            doutb <= 32'h0000_0000;
        end else if (enb) begin
            // Byte-enable write - each web bit protects one byte lane
            if (web[0]) mem[addrb[10:2]][ 7: 0] <= dinb[ 7: 0];
            if (web[1]) mem[addrb[10:2]][15: 8] <= dinb[15: 8];
            if (web[2]) mem[addrb[10:2]][23:16] <= dinb[23:16];
            if (web[3]) mem[addrb[10:2]][31:24] <= dinb[31:24];
            // Read (READ_FIRST: captures pre-write value in this same cycle)
            doutb <= mem[addrb[10:2]];
        end
    end

endmodule
