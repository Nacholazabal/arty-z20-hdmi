# Custom Verilog Modules

This folder tracks the project-specific Verilog modules developed during the HDMI subtitle overlay work.

## Included IP

- `axis_video_overlay_rect/`
  Verilog source for the AXI4-Stream video overlay block with AXI4-Lite control registers for subtitle placement, colors, enable, and SOF-aware update coordination.
- `subtitle_mask_mem/`
  Verilog source for the true dual-port BRAM subtitle bitmap store. The overlay reads from the video clock domain while software writes through `axi_bram_ctrl`.

## Why Track These Here

Keeping the raw Verilog source in the repository makes the hardware work visible and reviewable without needing the full Vivado workspace.
