# Hardware Design Document — Arty Z7-20 HDMI Pass-Through

**Project:** `arty-z20-hdmi`
**Board:** Digilent Arty Z7-20 (Xilinx Zynq-7000 XC7Z020-1CLG400C)
**Vivado version:** 2018.2
**Top-level block design:** `hw/bd/hdmi_in.bd`
**Top-level HDL wrapper:** `hw/src/hdmi_in_wrapper.vhd`
**Constraints:** `hw/constraints/ArtyZ7_7020Master.xdc`

---

## 1. Purpose & Scope

This document describes the FPGA hardware design for the Arty Z7-20 HDMI
pass-through platform: what it does, how the blocks are wired, why each IP was
chosen, the memory map exposed to software, the clocking and reset topology,
and the engineering trade-offs that shaped the design.

Firmware behavior is documented separately in `sw/README.md`; this document
focuses on the PL (Programmable Logic) side and the PS↔PL boundary.

### Audience
- Engineers modifying the block design or IP configuration
- Firmware developers writing against the memory map and register set
- Reviewers / instructors evaluating the design

### Related documents
- Top-level repository README: `README.md`
- Firmware README (UART command reference, build): `sw/README.md`
- Upstream reference: [Digilent/Arty-Z7-20-hdmi-in](https://github.com/Digilent/Arty-Z7-20-hdmi-in)

---

## 2. System Overview

### 2.1 What the design does
1. Receives an HDMI/DVI stream on **HDMI IN**.
2. Recovers pixel clock and deserializes TMDS lanes into parallel RGB using
   Digilent's `dvi2rgb` IP.
3. Converts the parallel video into an AXI4-Stream (AXI4S) video bus via
   `v_vid_in_axi4s`, timed by a video timing controller (`v_tc`) operating in
   **detection** mode.
4. Writes full frames into DDR3 (PS DDR) through an AXI VDMA MM2S/S2MM pair
   acting as a frame buffer.
5. Reads frames back out of DDR3 through the same VDMA, re-emits them as AXI4S
   video, and feeds `v_axi4s_vid_out` which is driven by a second `v_tc` in
   **generation** mode.
6. Serializes the output to TMDS using `rgb2dvi` and drives **HDMI OUT**.
7. Provides PS-side control and status through AXI GPIO, a dynamic pixel-clock
   generator (`axi_dynclk`), and the VDMA / V_TC register interfaces.

### 2.2 High-level data path (ASCII block diagram)

```
                    HDMI IN
                       │ (TMDS)
                       ▼
                  ┌──────────┐
                  │ dvi2rgb  │  recovers pixel clock, deserializes
                  └────┬─────┘
                       │ parallel RGB + pix_clk + vsync/hsync/de
                       ▼
                  ┌──────────────┐     ┌────────┐
                  │ v_vid_in_    │◄────│  v_tc  │ (detection)
                  │   axi4s      │     └────────┘
                  └────┬─────────┘
                       │ AXI4-Stream video
                       ▼
                 ┌──────────────┐
                 │  AXI VDMA    │ S2MM  ──► HP0 ──► PS DDR3 (frame buffer)
                 │  (MM2S+S2MM) │ MM2S  ◄── HP0 ◄── PS DDR3
                 └────┬─────────┘
                       │ AXI4-Stream video
                       ▼
                  ┌──────────────┐     ┌────────┐
                  │ v_axi4s_vid_ │◄────│  v_tc  │ (generation)
                  │    out       │     └────────┘
                  └────┬─────────┘      ▲
                       │ parallel RGB   │ pix_clk (axi_dynclk)
                       ▼
                  ┌──────────┐
                  │ rgb2dvi  │
                  └────┬─────┘
                       │ (TMDS)
                       ▼
                    HDMI OUT
```

### 2.3 Control / status path

```
Cortex-A9 (PS7) ── GP0 (M_AXI_GP0) ── axi_periph (AXI-Lite crossbar) ──┬── axi_vdma (control regs)
                                                                       ├── v_tc_0  (out generator)
                                                                       ├── v_tc_1  (in detector)
                                                                       ├── axi_gpio (HPD, status)
                                                                       └── axi_dynclk (pixel clock synth)

PS DDR3 controller ── HP0 (S_AXI_HP0) ── axi_mem_intercon ── axi_vdma M_AXI_* (MM2S/S2MM data)
```

---

## 3. IP Inventory

| Instance               | VLNV                                      | Purpose |
|------------------------|-------------------------------------------|---------|
| `processing_system7_0` | xilinx.com:ip:processing_system7:5.5      | Zynq PS7: Cortex-A9, DDR controller, UART, HP/GP ports |
| `dvi2rgb_0`            | digilentinc.com:ip:dvi2rgb                | TMDS deserializer, recovers pixel clock |
| `rgb2dvi_0`            | digilentinc.com:ip:rgb2dvi:1.3            | RGB → TMDS serializer for HDMI OUT |
| `v_vid_in_axi4s_0`     | xilinx.com:ip:v_vid_in_axi4s:4.0          | Parallel video → AXI4-Stream video |
| `v_axi4s_vid_out_0`    | xilinx.com:ip:v_axi4s_vid_out:4.0         | AXI4-Stream video → parallel video |
| `v_tc_0`               | xilinx.com:ip:v_tc:6.1                    | Video Timing Controller — generation (output) |
| `v_tc_1`               | xilinx.com:ip:v_tc:6.1                    | Video Timing Controller — detection (input) |
| `axi_vdma_0`           | xilinx.com:ip:axi_vdma:6.3                | Frame buffer DMA (MM2S + S2MM) |
| `axi_dynclk_0`         | digilentinc.com:ip:axi_dynclk:1.0         | Runtime-reconfigurable pixel clock |
| `axi_gpio_video`       | xilinx.com:ip:axi_gpio:2.0                | Dual-channel GPIO (HPD, status bits) |
| `axi_mem_intercon`     | xilinx.com:ip:axi_interconnect:2.1        | HP0 data interconnect (VDMA ↔ DDR) |
| `ps7_0_axi_periph`     | xilinx.com:ip:axi_interconnect:2.1        | GP0 AXI-Lite control interconnect |
| `xlconcat_0`           | xilinx.com:ip:xlconcat:2.1                | Interrupt concatenation to PS IRQ_F2P |
| `rst_*` (x3)           | xilinx.com:ip:proc_sys_reset:5.0          | Reset synchronizers per clock domain |

---

## 4. Clocking

| Clock                | Source                          | Freq        | Domain |
|----------------------|---------------------------------|-------------|--------|
| `FCLK_CLK0`          | PS7                             | 100 MHz     | AXI-Lite control, VDMA reg |
| `FCLK_CLK1`          | PS7                             | 150 MHz     | AXI-MM data (HP0) |
| `TMDS_Clk_p/n`       | HDMI IN cable                   | ~25–165 MHz | dvi2rgb input recovery |
| `PixelClk` (RX)      | `dvi2rgb` recovered             | = source    | input video pipeline |
| `pxl_clk_o` (TX)     | `axi_dynclk`                    | runtime set | output video pipeline |
| `pxl_clk_5x_o`       | `axi_dynclk`                    | 5× pxl_clk  | TMDS serializer clock |

### Why a dynamic clock on the TX side?
The output must match the input resolution/timing, which varies by source.
`axi_dynclk` lets firmware reconfigure the MMCM at runtime based on the
detected timing from `v_tc_1` (RX detector), rather than hard-coding a single
resolution.

---

## 5. Reset Topology

Three `proc_sys_reset` blocks, one per clock domain, tied to
`FCLK_RESET0_N` from the PS:

- `rst_processing_system7_0_100M` — AXI-Lite (100 MHz) domain
- `rst_processing_system7_0_150M` — AXI-MM data (150 MHz) domain
- `proc_sys_reset_0` — pixel-clock output domain, held in reset until
  `axi_dynclk` reports `LOCKED_O`

The input pixel domain uses `dvi2rgb`'s internal `pRst` driven by cable
presence / PLL lock.

---

## 6. Memory Map (PS ↔ PL, AXI-Lite GP0)

> These are the canonical base addresses used by firmware. Verify against
> `hw/export/hdmi_in_wrapper.hdf` (or the generated `xparameters.h`) before
> relying on them in new firmware.

| Peripheral       | Base address   | Size   | Notes |
|------------------|----------------|--------|-------|
| `axi_vdma_0`     | `0x43000000`   | 64 KB  | MM2S + S2MM frame DMA |
| `v_tc_0` (OUT)   | `0x43C00000`   | 64 KB  | Output timing generator |
| `v_tc_1` (IN)    | `0x43C10000`   | 64 KB  | Input timing detector |
| `axi_dynclk_0`   | `0x43C20000`   | 64 KB  | Pixel clock MMCM control |
| `axi_gpio_video` | `0x41200000`   | 64 KB  | HPD + status GPIOs |

Frame buffers are allocated by firmware in the PS DDR (`0x00000000` base,
512 MB). Typical layout: N frame buffers of `stride × height × bpp`, aligned
to 4 KB.

---

## 7. Interconnect & Data Flow

### 7.1 HP0 (data) — `axi_mem_intercon`
- 1 master (`axi_vdma_0`, with MM2S and S2MM ports), 1 slave (PS HP0).
- Includes `axi_dwidth_converter` (32→64 bit), `axi_data_fifo`,
  `axi_register_slice`, `axi_protocol_converter` for timing closure and
  bus-width matching to HP0 (64-bit AXI3).
- This is the bandwidth-critical path: HDMI video at e.g. 1080p60 ≈
  ~370 MB/s in + ~370 MB/s out.

### 7.2 GP0 (control) — `ps7_0_axi_periph`
- 1 master (PS M_AXI_GP0), 5 AXI-Lite slaves.
- `axi_protocol_converter` bridges full AXI4 (PS) to AXI4-Lite peripherals.

### 7.3 Interrupts
`xlconcat_0` aggregates interrupts into `IRQ_F2P[]`:
- VDMA MM2S / S2MM frame interrupts
- V_TC detection interrupts (resolution change on input)

---

## 8. PS7 Configuration Highlights

- **CPU frequency:** 650 MHz (APU)
- **DDR:** Enabled, 512 MB
- **Peripherals enabled:** UART1 (console), USB0, SD0, GPIO MIO
- **HP ports:** HP0 enabled (VDMA data path)
- **GP ports:** M_AXI_GP0 enabled (control)
- **FCLKs:** FCLK0=100 MHz, FCLK1=150 MHz

---

## 9. I/O & Constraints

Defined in `hw/constraints/ArtyZ7_7020Master.xdc`. Key pins:

- **HDMI IN:** TMDS diff pairs + HPD + DDC (I²C for EDID)
- **HDMI OUT:** TMDS diff pairs + HPD
- **LEDs / buttons / switches:** optional status and control

Timing constraints are primarily handled by the IP cores (TMDS clock
recovery and the dynamic pixel clock); no additional user clock constraints
are required beyond those emitted by the IP.

---

## 10. Engineering Decisions & Trade-offs

### 10.1 Why VDMA with a ring of frame buffers instead of a line buffer?
A line-buffered passthrough has lower latency but cannot:
- decouple input and output pixel clocks (required for re-timing),
- tolerate resolution changes without a glitch,
- allow PS-side processing / overlay on the video.

Using VDMA with ≥3 frame buffers lets the input and output sides run on
independent pixel clocks and gives firmware a well-defined handoff point.

### 10.2 Why two separate V_TC instances (not one shared)?
`v_tc_1` runs in **detection** mode on the input pixel clock and reports
the source resolution to firmware. `v_tc_0` runs in **generation** mode on
the output pixel clock and drives the TX pipeline. They live in different
clock domains and have opposite roles, so sharing is not practical.

### 10.3 Why `axi_dynclk` for the TX pixel clock?
Fixed MMCM settings would force a single output resolution. `axi_dynclk`
lets firmware reprogram the MMCM whenever `v_tc_1` reports a new input
timing, enabling true multi-resolution pass-through.

### 10.4 Why Digilent `dvi2rgb` / `rgb2dvi` instead of Xilinx HDMI IP?
The Xilinx HDMI 1.4/2.0 IP is licensed and heavyweight. For DVI-compatible
HDMI video (no HDCP, no audio, no InfoFrames) the Digilent IPs are free,
well documented, and proven on this exact board.

### 10.5 AXI data-width conversion placement
The width converter sits on the VDMA → HP0 path (32→64 bit) rather than
inside VDMA. This keeps VDMA on its native 32-bit stream width and pushes
conversion to the interconnect, which simplifies VDMA configuration and
makes it easy to swap in a different DMA later.

### 10.6 Clock rates (100 MHz control / 150 MHz data)
- 100 MHz for AXI-Lite is a comfortable default for all control-plane IPs
  and matches the PS7 default FCLK.
- 150 MHz for AXI-MM data gives headroom for 1080p60 without oversizing
  the design or pulling unnecessary current.

---

## 11. Build & Export

See the top-level `README.md` for the full workflow. In short:

1. Open the Vivado 2018.2 project and modify `hdmi_in.bd` or the HDL wrapper.
2. Synthesize → Implement → Generate Bitstream.
3. `File → Export → Export Hardware` (with bitstream) — produces
   `hdmi_in_wrapper.hdf`.
4. Run `scripts/sync_hw.ps1` from the repo root to sync sources back into
   this repo.
5. Commit `hw/`, `release/hdmi_in_wrapper.bit`, and `hw/export/*.hdf`.

---

## 12. Known Limitations

- DVI mode only — no HDMI audio, no HDCP, no InfoFrame decoding.
- Maximum tested resolution: **1080p60** (8-bit RGB).
- No on-chip video processing (scaler, CSC, overlay) in this revision.
- VDMA requires frame-aligned buffer addresses; unaligned buffers will
  stall the pipeline.

---

## 13. Future Work (suggested)

- Add an OSD/overlay block for on-screen text (subtitles).
- Integrate a scaler (`v_vscaler` / `v_hscaler`) for resolution conversion.
- Move to Vitis / newer Vivado and re-export.
- Add a second HP port for independent MM2S/S2MM bandwidth.

---

## 14. Glossary

| Term      | Meaning |
|-----------|---------|
| PS / PL   | Processing System (ARM) / Programmable Logic (FPGA fabric) |
| TMDS      | Transition-Minimized Differential Signaling (HDMI physical layer) |
| VDMA      | Video Direct Memory Access |
| V_TC      | Video Timing Controller |
| HP / GP   | High-Performance / General-Purpose AXI port (Zynq) |
| MM2S/S2MM | Memory-Mapped to Stream / Stream to Memory-Mapped |

---

## Appendix A — Suggested additions once implemented
- **A.1 Subtitle / OSD hardware block** (mentioned in commit `2d82616`): wire
  diagram, register map, blend position, font ROM layout.
- **A.2 Register-level description** of the AXI GPIO channels (bit-by-bit).
- **A.3 Timing diagrams** for VDMA park/circular modes as used by firmware.
