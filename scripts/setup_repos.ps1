#Requires -Version 5
<#
.SYNOPSIS
    One-time setup: initialises the firmware sub-repo, enables Git LFS in the
    main repo, wires fw as a submodule, and pushes both to GitHub.

.DESCRIPTION
    Run ONCE from PowerShell after cloning / creating both repo folders.
    Requires: git  +  git-lfs  (https://git-lfs.com  or  winget install GitHub.GitLFS)

.NOTES
    Adjust FwDir and MainDir below if your paths differ.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Paths -------------------------------------------------------------------
$FwDir   = "C:\Users\nacho\Desktop\Postgrado\FPGA\arty-z20-hdmi-passthrough\arty-z20-hdmi-passthrough.sdk\Arty-Z7-20-hdmi-in"
$MainDir = "C:\Users\nacho\Desktop\Postgrado\FPGA\arty-z20-hdmi"

$FwRemote   = "https://github.com/Nacholazabal/arty-z20-hdmi-fw.git"
$MainRemote = "https://github.com/Nacholazabal/arty-z20-hdmi.git"
# ----------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host "   arty-z20-hdmi  -  First-time repo setup"
Write-Host "============================================================"
Write-Host ""

# -- STEP 0: Verify git-lfs is available -------------------------------------
Write-Host "Step 0/6  Checking prerequisites..."
$lfsCmd = Get-Command "git-lfs" -ErrorAction SilentlyContinue
if (-not $lfsCmd) {
    Write-Host ""
    Write-Host "ERROR: git-lfs not found."
    Write-Host "Install it with:  winget install GitHub.GitLFS"
    Write-Host "Then re-run this script."
    exit 1
}
$lfsVer = & git lfs version
Write-Host "  git-lfs found: $lfsVer"

# -- STEP 1: Remove stale .git left by Linux tooling -------------------------
Write-Host "Step 1/6  Cleaning firmware directory..."
$staleGit = Join-Path $FwDir ".git"
if (Test-Path $staleGit) {
    Write-Host "  Removing stale .git folder..."
    Remove-Item -Recurse -Force $staleGit
}
Write-Host "  OK"

# -- STEP 2: Initialise firmware repo (plain git, no LFS needed) -------------
Write-Host "Step 2/6  Initialising firmware repo..."
Push-Location $FwDir
    git init
    git branch -M main
    git remote add origin $FwRemote
    git add .gitignore src/
    git commit -m "Initial firmware source commit" -m "ARM/PS7 bare-metal firmware for the Arty Z7-20 HDMI-In demo."
    Write-Host "  Pushing firmware to GitHub..."
    git push -u origin main
Pop-Location
Write-Host "  OK - arty-z20-hdmi-fw pushed."
Write-Host ""

# -- STEP 3: Enable Git LFS in the main repo ---------------------------------
Write-Host "Step 3/6  Enabling Git LFS in main repo..."
Push-Location $MainDir
    git lfs install --local
    Write-Host "  LFS hooks installed."
    Write-Host "  LFS patterns (from .gitattributes): *.bit  *.hdf  *.elf  *.dcp"

# -- STEP 4: Verify main repo remote -----------------------------------------
Write-Host "Step 4/6  Checking main repo remote..."
    $cur = git remote get-url origin 2>$null
    if ($cur -ne $MainRemote) {
        git remote set-url origin $MainRemote
        Write-Host "  Remote updated to $MainRemote"
    } else {
        Write-Host "  Remote OK: $MainRemote"
    }

# -- STEP 5: Add firmware as submodule ---------------------------------------
Write-Host "Step 5/6  Adding fw as submodule at sw/..."
    $swGit = Join-Path $MainDir "sw\.git"
    if (Test-Path $swGit) {
        Write-Host "  Submodule already registered, skipping."
    } else {
        git submodule add $FwRemote sw
        git submodule update --init --recursive
    }

# -- STEP 6: Commit and push main repo ---------------------------------------
Write-Host "Step 6/6  Committing and pushing main repo..."
    git add .
    git commit -m "Initial commit: hw sources, LFS artifacts, fw submodule" -m "- hw/src:         hdmi_in_wrapper.vhd`n- hw/constraints: ArtyZ7_7020Master.xdc`n- hw/bd:          hdmi_in.bd`n- hw/export:      hdmi_in_wrapper.hdf  [LFS]`n- release:        hdmi_in_wrapper.bit  [LFS]`n- release:        Arty-Z7-20-hdmi-in.elf  [LFS]`n- sw:             firmware submodule (arty-z20-hdmi-fw)`n- scripts:        sync_hw.ps1`n- .gitattributes: Git LFS patterns"
    Write-Host "  Pushing (LFS objects upload first, then refs)..."
    git push -u origin main
Pop-Location

Write-Host ""
Write-Host "============================================================"
Write-Host "  Done! Both repos are live on GitHub."
Write-Host "  Main : https://github.com/Nacholazabal/arty-z20-hdmi"
Write-Host "  FW   : https://github.com/Nacholazabal/arty-z20-hdmi-fw"
Write-Host "============================================================"
Write-Host ""
Write-Host "Clone with submodules + LFS:"
Write-Host "  git clone --recurse-submodules https://github.com/Nacholazabal/arty-z20-hdmi"
