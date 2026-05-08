#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Create a Debian 13 cloud-init VM for the appliance-core blank.

.DESCRIPTION
    Builds a Gen2 single-NIC VM:
      - the lab-LAN NIC, attached to Lab-NAT, MAC pinned so router1's
        dnsmasq hands it the reserved 10.10.10.40 lease.

    The base VHDX is shared across all core test VMs (read-mostly);
    each VM gets its own differencing disk rooted on the base. That
    keeps a fresh test VM tens of MB on disk until prepare-image.sh
    writes a lot.

    MAC reservations on the lab-router (matching dnsmasq):
      core-1   00:15:5D:0A:0A:28   10.10.10.40
      core-2   00:15:5D:0A:0A:29   10.10.10.41
      core-3   00:15:5D:0A:0A:2A   10.10.10.42

.PARAMETER VMName
    Hyper-V VM name. Required.

.PARAMETER BaseVhdxPath
    Path on the Hyper-V host to the staged base VHDX produced by
    stage-core-base.sh. Default 'D:\ISO\debian-13-appliance-core-base.vhdx'.

.PARAMETER SeedIso
    Path on the Hyper-V host to the per-VM cloud-init seed ISO. Defaults
    to 'D:\ISO\<VMName>-seed.iso'.

.PARAMETER SwitchName
    Lab LAN switch (default 'Lab-NAT').

.PARAMETER StaticMacAddress
    Pinned MAC for the lab-LAN NIC, no separators. Default '00155D0A0A28'
    = core-1.

.EXAMPLE
    .\New-CoreTestVM.ps1 -VMName core-1 -Start

.EXAMPLE
    .\New-CoreTestVM.ps1 -VMName core-2 `
        -StaticMacAddress 00155D0A0A29 -Start
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$BaseVhdxPath     = 'D:\ISO\debian-13-appliance-core-base.vhdx',
    [string]$SeedIso          = '',
    [string]$LabPath          = 'D:\Lab',
    [string]$SwitchName       = 'Lab-NAT',
    [int]   $MemoryGB         = 2,
    [int]   $VCpu             = 2,
    [int]   $DiskGB           = 20,
    [string]$StaticMacAddress = '00155D0A0A28',
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    + $m" -ForegroundColor Green }

if (-not $SeedIso) { $SeedIso = "D:\ISO\${VMName}-seed.iso" }

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first: Remove-VM $VMName -Force"
}
if (-not (Test-Path $BaseVhdxPath)) {
    throw "Base VHDX not found: $BaseVhdxPath. Run lab/stage-core-base.sh on the Mac first."
}
if (-not (Test-Path $SeedIso)) {
    throw "Seed ISO not found: $SeedIso. Run lab/stage-core-base.sh on the Mac first."
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$SwitchName' not found. Build the lab router first (New-LabRouter.ps1)."
}

Write-Step "Creating appliance-core test VM: $VMName"
Write-OK   "  NIC -> $SwitchName  (MAC $StaticMacAddress)"

$VmFolder = Join-Path $LabPath $VMName
New-Item -Path $VmFolder -ItemType Directory -Force | Out-Null

# Differencing VHDX rooted on the shared base. Cheap to create, cheap to
# throw away — perfect for "build a fresh test VM" cycles.
$DiffVhdxPath = Join-Path $VmFolder "$VMName.vhdx"
if (Test-Path $DiffVhdxPath) { Remove-Item -Force $DiffVhdxPath }
New-VHD -Path $DiffVhdxPath -ParentPath $BaseVhdxPath -Differencing | Out-Null

# Resize the differencing virtual size so the guest sees room to grow
# beyond the cloud image's stock 2 GB. The on-disk file stays small until
# the workload writes to it.
Resize-VHD -Path $DiffVhdxPath -SizeBytes ($DiskGB * 1GB)

$null = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -SwitchName $SwitchName `
    -VHDPath $DiffVhdxPath `
    -Path $LabPath

Set-VMProcessor -VMName $VMName -Count $VCpu
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# Pin the NIC's MAC so dnsmasq hands out the reserved IP.
$nic = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
$nic | Set-VMNetworkAdapter -StaticMacAddress $StaticMacAddress
$nic | Rename-VMNetworkAdapter -NewName 'Lab'
Write-OK "NIC pinned: $StaticMacAddress"

# Mount the cloud-init seed as a DVD. cloud-init's NoCloud datasource
# discovers it by the CIDATA volume label set by stage-core-base.sh.
Add-VMDvdDrive -VMName $VMName -Path $SeedIso

# Cloud images are signed for normal Debian boot, NOT Microsoft secure
# boot. Disable SecureBoot so the bootloader on the base VHDX can run.
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMHardDiskDrive -VMName $VMName)

Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'
Enable-VMIntegrationService -VMName $VMName -Name 'Heartbeat'
Enable-VMIntegrationService -VMName $VMName -Name 'Time Synchronization'

Write-OK "VM created"
Write-OK "  vCPU: $VCpu | RAM: $MemoryGB GB | Disk virt: $DiskGB GB"
Write-OK "  Base: $BaseVhdxPath"
Write-OK "  Diff: $DiffVhdxPath"
Write-OK "  Seed: $SeedIso"

if ($Start) {
    Write-Step "Starting VM"
    Start-VM -Name $VMName
    Write-OK "Started — cloud-init typically takes ~20s; the appliance is reachable"
    Write-OK "via SSH at the dnsmasq-reserved IP for $StaticMacAddress once cloud-init"
    Write-OK "writes /var/log/appliance-core-base-ready.marker."
}
