# arty-z20-hdmi

Arty Z7-20 HDMI pass-through demo — clean, minimal repository for editing and rebuilding the hardware and firmware.

## Repository layout

```
arty-z20-hdmi/
├─ hw/
│  ├─ src/              VHDL/Verilog wrappers
│  ├─ constraints/      XDC constraint files
│  ├─ bd/               Vivado block-design (.bd)
│  ├─ ip/               Standalone IP customisation files
│  ├─ tcl/              Helper TCL scripts
│  └─ export/
│        hdmi_in_wrapper.hdf   Hardware definition (for SDK)
│
├─ sw/                  Firmware source (submodule → arty-z20-hdmi-fw)
│
├─ release/
│     hdmi_in_wrapper.bit      Bitstream
│     Arty-Z7-20-hdmi-in.elf   Application ELF
│
├─ scripts/
│     sync_hw.ps1       Copy updated HW sources from Vivado project
│     setup_repos.ps1   One-time repo initialisation (run once)
│
└─ .gitignore
```

## Cloning

```bash
git clone --recurse-submodules https://github.com/Nacholazabal/arty-z20-hdmi
```

The `--recurse-submodules` flag automatically pulls the firmware source into `sw/`.

## Editing hardware (Vivado)

1. Open the messy project in Vivado (still lives at `arty-z20-hdmi-passthrough/`).
2. Make your changes and run implementation.
3. From a PowerShell terminal in the repo root:
   ```powershell
   .\scripts\sync_hw.ps1
   ```
4. Review the diff (`git diff --stat`) and commit.

## Editing firmware (SDK / Vitis)

The firmware lives in `sw/` which is a self-contained git repo (`arty-z20-hdmi-fw`).
Edit files there, commit, and push from inside `sw/`.
Then come back to the root repo and commit the updated submodule pointer:

```bash
cd sw
git add .
git commit -m "your fw change"
git push
cd ..
git add sw
git commit -m "bump fw submodule"
git push
```

## sync_hw.ps1 — what it copies

| Source (passthrough project)               | Destination         |
|--------------------------------------------|---------------------|
| `.srcs/sources_1/imports/hdl/*.vhd,*.v`   | `hw/src/`           |
| `.srcs/constrs_1/**/*.xdc`                | `hw/constraints/`   |
| `.srcs/sources_1/bd/**/*.bd`              | `hw/bd/`            |
| `.sdk/hdmi_in_wrapper.hdf`               | `hw/export/`        |
| `.runs/impl_1/*.bit`                      | `release/`          |

Everything else (cache, runs, logs, SDK metadata) is **not** copied — and is excluded by `.gitignore`.
