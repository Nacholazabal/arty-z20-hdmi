# Arty Z7-20 — HDMI Pass-Through

A clean, self-contained repository for the **Arty Z7-20** HDMI pass-through design — hardware and firmware sources for an FPGA-based HDMI capture and re-transmission system running on the Zynq-7000 SoC.

The design captures a live HDMI input signal through the FPGA fabric, buffers the frames in DDR3 memory via the PS7 (ARM) subsystem, and re-transmits the video over HDMI output. A lightweight bare-metal firmware running on the ARM Cortex-A9 manages the video pipeline and exposes a UART control interface.

> **Based on** [Digilent/Arty-Z7-20-hdmi-in](https://github.com/Digilent/Arty-Z7-20-hdmi-in) — heavily modified to fix compatibility issues and extend functionality.

---

## Repository layout

```
arty-z20-hdmi/
├── hw/
│   ├── src/                 VHDL/Verilog top-level wrappers
│   ├── constraints/         Xilinx Design Constraint (.xdc) files
│   ├── bd/                  Vivado block design (.bd)
│   └── export/
│         hdmi_in_wrapper.hdf   Hardware definition file (for SDK/Vitis)
│
├── sw/                      Firmware source (git submodule → arty-z20-hdmi-fw)
│
├── release/
│     hdmi_in_wrapper.bit    Bitstream (pre-built, tracked via Git LFS)
│     Arty-Z7-20-hdmi-in.elf Application ELF (pre-built, tracked via Git LFS)
│
├── scripts/
│     sync_hw.ps1            Copies updated HW sources from Vivado project
│
└── .gitattributes           Git LFS patterns for binary artifacts
```

---

## Quick start — programming the board

Pre-built binaries are included in `release/` so you can try the design without rebuilding anything.

### Requirements
- Arty Z7-20 development board
- Xilinx SDK **2018.2** (or Vitis with legacy SDK support)
- HDMI source connected to the **HDMI In** port
- HDMI display connected to the **HDMI Out** port
- USB cable for UART (115200 baud, 8N1)

### Steps

1. Clone the repository including the firmware submodule and LFS objects:

   ```bash
   git clone --recurse-submodules https://github.com/Nacholazabal/arty-z20-hdmi
   cd arty-z20-hdmi
   git lfs pull
   ```

2. Open Xilinx SDK / Vitis and create a new hardware platform using `release/hdmi_in_wrapper.bit` is not needed here — the ELF already contains the application.

3. Use the **Xilinx SDK Program FPGA** wizard (or `xsdb`) to program both the bitstream and the ELF onto the board:

   ```
   Bitstream : release/hdmi_in_wrapper.bit
   ELF       : release/Arty-Z7-20-hdmi-in.elf
   ```

4. Connect a serial terminal (115200 8N1) to the board's USB-UART port. The firmware will print a menu on boot and respond to single-character commands (see the [firmware README](sw/README.md) for the full command reference).

---

## Editing the hardware

All hardware source files required to reproduce and modify the design are checked in under `hw/`. For full context on the block design, IP cores, and Vivado workflow, the [upstream Digilent repository](https://github.com/Digilent/Arty-Z7-20-hdmi-in) is the best reference — this repo uses the same Vivado project structure.

### Toolchain
- **Vivado 2018.2** (project was created and is tested against this version)
- Git LFS (for committing bitstream and HDF artifacts)

### Workflow

1. Open your Vivado project and make your changes.
2. Run Synthesis → Implementation → Generate Bitstream.
3. Export the hardware definition: **File → Export → Export Hardware** (include bitstream).
4. From a PowerShell terminal at the repo root, run the sync script to copy the updated sources back into the clean repo:

   ```powershell
   .\scripts\sync_hw.ps1
   ```

   The script copies:

   | Source (Vivado project)                        | Destination          |
   |------------------------------------------------|----------------------|
   | `*.srcs/sources_1/imports/hdl/*.vhd, *.v`     | `hw/src/`            |
   | `*.srcs/constrs_1/**/*.xdc`                   | `hw/constraints/`    |
   | `*.srcs/sources_1/bd/**/*.bd`                 | `hw/bd/`             |
   | `*.sdk/hdmi_in_wrapper.hdf`                   | `hw/export/`         |
   | `*.runs/impl_1/*.bit`                         | `release/`           |

5. Review the diff and commit:

   ```bash
   git diff --stat
   git add hw/ release/
   git commit -m "hw: describe your change"
   git push
   ```

---

## Editing the firmware

The firmware lives in `sw/`, which is a standalone git repository ([arty-z20-hdmi-fw](https://github.com/Nacholazabal/arty-z20-hdmi-fw)) tracked here as a submodule. See the [firmware README](sw/README.md) for build instructions and the UART command reference.

After making changes inside `sw/`, commit and push there, then update the submodule pointer in this repo:

```bash
cd sw
git add .
git commit -m "fw: describe your change"
git push

cd ..
git add sw
git commit -m "bump fw submodule"
git push
```

---

## Credits

This project is based on the original **[Digilent Arty-Z7-20-hdmi-in](https://github.com/Digilent/Arty-Z7-20-hdmi-in)** demo by [Digilent, Inc.](https://digilent.com), which demonstrates HDMI input/output and UART control on the Arty Z7-20 board. The hardware design and firmware were substantially reworked to resolve compatibility issues and adapt the project to our specific requirements.

---

## License

Hardware sources and firmware are derived from Digilent's open-source demo. Please refer to the [upstream repository](https://github.com/Digilent/Arty-Z7-20-hdmi-in) for the original license terms.
