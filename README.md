# Arty Z7-20 HDMI Subtitle Overlay

FPGA and firmware sources for a thesis platform that captures HDMI video on the **Arty Z7-20**, stores frames in PS DDR, and overlays subtitles in real time before retransmitting the processed stream over HDMI.

This repository showcases the hardware and system-integration work behind the project: extending the original HDMI pass-through pipeline into a subtitle-capable video path with custom AXI-Stream logic, BRAM-backed subtitle storage, and software-visible control registers.

## Hardware Focus

The hardware side of this project goes beyond a simple pass-through demo. The current design includes:

- A custom `axis_video_overlay_rect` AXI4-Stream video IP that inserts a subtitle bar and glyph pixels into the outgoing stream.
- A custom `subtitle_mask_mem` true dual-port BRAM IP used as a 1 bpp subtitle bitmap store, readable from the pixel domain and writable from the PS through AXI.
- An `axi_bram_ctrl` integration that exposes subtitle bitmap memory to software at a dedicated address range.
- A revised block design that places the overlay in the live HDMI pipeline between frame-buffer readout and HDMI output.
- Exported hardware artifacts and the custom Verilog modules so the design can be inspected and extended from this repository.

## Repository Layout

```text
arty-z20-hdmi/
|-- hw/
|   |-- bd/                  Vivado block design export
|   |-- constraints/         Board constraints
|   |-- export/              Hardware definition export (.hdf)
|   |-- ip/                  Custom IP created for this project
|   |-- src/                 Top-level HDL wrapper
|   `-- tcl/                 Reserved for reproducible HW scripts
|-- sw/                      Firmware source (submodule)
|-- docs/                    Design notes and project documentation
|-- release/                 Prebuilt bitstream / ELF artifacts
```

## Custom IP Included In This Repo

- `hw/ip/axis_video_overlay_rect/`
  Verilog source for the AXI4-Stream overlay engine with AXI4-Lite control registers for subtitle position, bar size, bar color, text color, enable, and SOF-safe update status.
- `hw/ip/subtitle_mask_mem/`
  Verilog source for the dual-port subtitle bitmap memory. Port A is read by the overlay in the pixel clock domain, while Port B is exposed to software through `axi_bram_ctrl`.

## Hardware Architecture

The active hardware pipeline is:

```text
HDMI IN
  -> dvi2rgb
  -> v_vid_in_axi4s
  -> AXI VDMA (write to DDR)
  -> AXI VDMA (read from DDR)
  -> axis_video_overlay_rect
  -> v_axi4s_vid_out
  -> rgb2dvi
  -> HDMI OUT
```

The overlay block reads subtitle pixels from BRAM-backed mask memory and blends them over a configurable subtitle bar. The PS can update both the overlay registers and the subtitle bitmap through memory-mapped interfaces, which makes the platform suitable for experimenting with subtitle generation, placement, and synchronization.

## Memory-Mapped Hardware Interfaces

From the exported block design currently tracked in `hw/`:

- `0x40000000` - subtitle bitmap BRAM window via `axi_bram_ctrl_0`
- `0x41200000` - `axi_gpio_video`
- `0x43000000` - `axi_vdma_0`
- `0x43C00000` - `axi_dynclk_0`
- `0x43C10000` - `v_tc_0`
- `0x43C20000` - `v_tc_1`
- `0x43C30000` - `axis_video_overlay_rect` control registers

## Working With The Hardware

### Toolchain

- Vivado 2018.2/2018.3-era project flow
- Arty Z7-20 board
- Git LFS for tracked binary outputs in `release/`

## Documentation

- Hardware design notes: [docs/HARDWARE_DESIGN.md](docs/HARDWARE_DESIGN.md)
- Firmware notes: [sw/README.md](sw/README.md)

## Credits

This work builds on Digilent's **[Arty-Z7-20 HDMI In demo](https://github.com/Digilent/Arty-Z7-20-hdmi-in)** as an initial reference for HDMI capture/output on the board. The repository here tracks the thesis-specific hardware evolution on top of that foundation, especially the subtitle overlay pipeline, custom IP blocks, BRAM integration, and associated control path.
