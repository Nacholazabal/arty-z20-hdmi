<#
.SYNOPSIS
    Syncs relevant hardware files from the messy Vivado/SDK project into the clean repo.

.DESCRIPTION
    Copies ONLY the source files needed to edit and rebuild the project:
      hw/src/        <- VHDL/Verilog wrappers   (.vhd, .v)
      hw/constraints <- Constraint files         (.xdc from constrs_1 only)
      hw/bd/         <- Block design             (.bd)
      hw/export/     <- Hardware definition file (.hdf)
      release/       <- Bitstream                (.bit)

    Run this script whenever you make changes in Vivado and want to
    commit the updated sources to this repo.

.PARAMETER Source
    Path to the messy passthrough Vivado project folder.
    Default: C:\Users\nacho\Desktop\Postgrado\FPGA\HDMI_overlay

.EXAMPLE
    .\sync_hw.ps1
    .\sync_hw.ps1 -Source "D:\projects\arty-z20-hdmi-passthrough"
#>
param(
    [string]$Source = "C:\Users\nacho\Desktop\Postgrado\FPGA\HDMI_overlay"
)

# Resolve destination to this script's parent folder (repo root)
$Dest = Split-Path -Parent $PSScriptRoot

Write-Host "==> Syncing HW from: $Source"
Write-Host "==>             to:  $Dest"
Write-Host ""

# ── Validate source ──────────────────────────────────────────────────────────
if (-not (Test-Path $Source)) {
    Write-Error "Source directory not found: $Source"
    exit 1
}

$srcSrcs = Join-Path $Source "HDMI_overlay.srcs"
$srcImpl = Join-Path $Source "HDMI_overlay.runs\impl_1"
$srcSdk  = Join-Path $Source "HDMI_overlay.sdk"

foreach ($p in @($srcSrcs, $srcImpl, $srcSdk)) {
    if (-not (Test-Path $p)) {
        Write-Error "Expected subfolder not found: $p"
        exit 1
    }
}

# ── Helper ───────────────────────────────────────────────────────────────────
function Sync-Files {
    param([string[]]$Files, [string]$DestDir, [string]$Label)
    $null = New-Item -ItemType Directory -Force -Path $DestDir
    foreach ($f in $Files) {
        Copy-Item -Path $f -Destination $DestDir -Force
        Write-Host "  [+] $Label -> $(Split-Path -Leaf $f)"
    }
}

# ── 1. HDL wrapper (.vhd / .v from sources_1\imports\hdl) ───────────────────
$hdlFiles = Get-ChildItem -Path "$srcSrcs\sources_1\imports\hdl" `
                          -Include "*.vhd","*.v" -Recurse -File -ErrorAction SilentlyContinue
Sync-Files -Files $hdlFiles.FullName -DestDir "$Dest\hw\src" -Label "hw/src"

# ── 2. Constraints (.xdc from constrs_1 only — NOT generated run XDCs) ──────
$xdcFiles = Get-ChildItem -Path "$srcSrcs\constrs_1" `
                          -Include "*.xdc" -Recurse -File -ErrorAction SilentlyContinue
Sync-Files -Files $xdcFiles.FullName -DestDir "$Dest\hw\constraints" -Label "hw/constraints"

# ── 3. Block design (.bd — top-level only, not generated ip sub-BDs) ─────────
$bdFiles = Get-ChildItem -Path "$srcSrcs\sources_1\bd" `
                         -Include "*.bd" -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Directory.Name -ne "ip" }
Sync-Files -Files $bdFiles.FullName -DestDir "$Dest\hw\bd" -Label "hw/bd"

# ── 4. HDF export (top-level .hdf in sdk root) ───────────────────────────────
$hdfFile = Get-ChildItem -Path "$srcSdk\*" -Include "*.hdf" -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
if ($hdfFile) {
    Sync-Files -Files @($hdfFile.FullName) -DestDir "$Dest\hw\export" -Label "hw/export"
} else {
    Write-Warning "No .hdf file found in $srcSdk"
}

# ── 5. Bitstream (.bit from impl_1) ──────────────────────────────────────────
$bitFile = Get-ChildItem -Path "$srcImpl\*" -Include "*.bit" -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
if ($bitFile) {
    Sync-Files -Files @($bitFile.FullName) -DestDir "$Dest\release" -Label "release"
} else {
    Write-Warning "No .bit file found in $srcImpl"
}

Write-Host ""
Write-Host "==> Sync complete. Review changes with: git -C `"$Dest`" diff --stat"
