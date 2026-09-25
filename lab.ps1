#Requires -Version 5.1
<#
.SYNOPSIS
  PurpleForest host orchestrator for Windows + VMware Workstation.

.DESCRIPTION
  Run this on the Windows HOST, in an elevated PowerShell. It installs what
  the lab needs, puts every large file on the drive you choose, and brings
  the VMs up. Provisioning (Ansible) still runs from Kali afterwards.

    .\lab.ps1 setup      interactive: pick drive, Kali choice, install tools
    .\lab.ps1 check      verify prerequisites, change nothing
    .\lab.ps1 up         create VMs (and attach an existing Kali if chosen)
    .\lab.ps1 up dc01    create one VM
    .\lab.ps1 status     vagrant status
    .\lab.ps1 snapshot   snapshot every VM as 'baseline'
    .\lab.ps1 restore    roll every VM back to 'baseline'
    .\lab.ps1 destroy    delete the lab VMs (never touches an existing Kali)

  First run, with no repo yet:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    irm https://raw.githubusercontent.com/zebracherry/PurpleForest/main/lab.ps1 -OutFile lab.ps1
    .\lab.ps1 setup
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'check', 'up', 'status', 'snapshot', 'restore', 'destroy', 'help')]
  [string]$Command = 'help',

  [Parameter(Position = 1)]
  [string]$Target,

  # Non-interactive overrides for setup
  [string]$LabRoot,
  [string]$KaliVmx
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is 10x faster without it

$Repo            = 'zebracherry/PurpleForest'
$VagrantFallback = '2.4.3'     # used only if the releases API is unreachable
$UtilityFallback = '1.0.24'
$LabVMs          = @('dc01', 'ws01', 'siem01', 'kali')
$LabNetPrefix    = '10.10.10'

# ---------------------------------------------------------------- output --
$script:Failed = $false
function Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [fail] $m" -ForegroundColor Red; $script:Failed = $true }
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- config --
# Choices from 'setup' persist here so every later command agrees with them.
# lab.ps1 may be run from the repo or from wherever it was first downloaded,
# so look beside the script first, then at the lab root setup recorded.
function Read-LabConfig {
  $candidates = @(
    (Join-Path $PSScriptRoot '.lab-config.json'),
    $(if ($env:PURPLEFOREST_ROOT) { Join-Path $env:PURPLEFOREST_ROOT '.lab-config.json' }),
    $(if ([Environment]::GetEnvironmentVariable('PURPLEFOREST_ROOT', 'User')) {
        Join-Path ([Environment]::GetEnvironmentVariable('PURPLEFOREST_ROOT', 'User')) '.lab-config.json' })
  ) | Where-Object { $_ }
  foreach ($p in $candidates) {
    if (Test-Path $p) { return Get-Content $p -Raw | ConvertFrom-Json }
  }
  return $null
}

function Save-LabConfig($cfg) {
  $cfg | ConvertTo-Json | Set-Content -Path (Join-Path $cfg.LabRoot '.lab-config.json') -Encoding UTF8
  [Environment]::SetEnvironmentVariable('PURPLEFOREST_ROOT', $cfg.LabRoot, 'User')
  $env:PURPLEFOREST_ROOT = $cfg.LabRoot
}

function Use-LabConfig {
  $cfg = Read-LabConfig
  if (-not $cfg) { throw "No .lab-config.json next to lab.ps1. Run '.\lab.ps1 setup' first." }
  $env:VAGRANT_HOME = $cfg.VagrantHome
  $env:LAB_KALI     = $cfg.KaliMode
  Update-SessionPath
  Set-Location $cfg.LabRoot
  return $cfg
}

# ----------------------------------------------------------------- utils --
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# MSI installers update PATH in the registry, not in this session.
function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user"
}

function Get-VMwareInstallPath {
  foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation',
                 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation') {
    $p = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).InstallPath
    if ($p -and (Test-Path (Join-Path $p 'vmrun.exe'))) { return $p }
  }
  $default = 'C:\Program Files (x86)\VMware\VMware Workstation'
  if (Test-Path (Join-Path $default 'vmrun.exe')) { return $default }
  return $null
}

function Get-Vmrun {
  $p = Get-VMwareInstallPath
  if ($p) { return (Join-Path $p 'vmrun.exe') }
  return $null
}

function Get-LatestVersion($product, $fallback) {
  try {
    $r = Invoke-RestMethod "https://api.releases.hashicorp.com/v1/releases/$product/latest" -TimeoutSec 15
    if ($r.version) { return $r.version }
  } catch { }
  Warn "releases API unreachable for $product, using pinned $fallback"
  return $fallback
}

# Download a HashiCorp MSI and verify it against the published SHA256SUMS.
function Install-HashiMsi($product, $version) {
  $file = "${product}_${version}_windows_amd64.msi"
  $base = "https://releases.hashicorp.com/$product/$version"
  $dest = Join-Path $env:TEMP $file

  Write-Host "  downloading $file"
  Invoke-WebRequest "$base/$file" -OutFile $dest -UseBasicParsing
  $sums = (Invoke-WebRequest "$base/${product}_${version}_SHA256SUMS" -UseBasicParsing).Content

  $expected = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($file) }) -replace '\s+.*$', ''
  $actual   = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
  if (-not $expected -or $expected.Trim().ToLower() -ne $actual) {
    Remove-Item $dest -Force
    throw "SHA256 mismatch for $file -- refusing to install"
  }
  Ok "checksum verified"

  $log  = Join-Path $env:TEMP "$product-install.log"
  $proc = Start-Process msiexec.exe -Wait -PassThru `
            -ArgumentList "/i `"$dest`" /qn /norestart /l*v `"$log`""
  switch ($proc.ExitCode) {
    0       { Ok "$product $version installed" }
    3010    { Ok "$product $version installed"; $script:RebootNeeded = $true }
    1641    { Ok "$product $version installed"; $script:RebootNeeded = $true }
    default { throw "$product installer exited $($proc.ExitCode) -- see $log" }
  }
  Update-SessionPath
}

# --------------------------------------------------------------- checks ---
function Invoke-Check {
  $script:Failed = $false
  $cfg = Read-LabConfig
  if ($cfg) { $env:VAGRANT_HOME = $cfg.VagrantHome }
  Update-SessionPath

  Step 'Host'
  if (Test-Admin) { Ok 'running elevated' } else { Warn 'not elevated -- setup needs an Administrator PowerShell' }

  $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $need  = if ($cfg -and $cfg.KaliMode -eq 'existing') { 20 } else { 24 }
  if ($ramGB -ge 32)       { Ok "${ramGB} GB RAM" }
  elseif ($ramGB -ge $need) { Warn "${ramGB} GB RAM -- workable, bring VMs up one at a time" }
  else                     { Fail "${ramGB} GB RAM -- lab VMs alone need ~20 GB" }

  if ((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Warn 'Hyper-V / VBS is active. Workstation runs on top of it, but slower,'
    Warn 'and nested virtualisation is unavailable. See docs/windows-11.md.'
  } else {
    Ok 'no Hyper-V hypervisor holding the CPU'
  }

  Step 'VMware Workstation'
  $vmw = Get-VMwareInstallPath
  if ($vmw) {
    $ver = (Get-Item (Join-Path $vmw 'vmware.exe') -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
    if ($ver -and ([version]($ver -replace '[^\d\.].*$', '')) -lt [version]'16.2') {
      Fail "Workstation $ver -- need 16.2+ (Vagrantfile uses virtual hardware 19)"
    } else { Ok "Workstation $ver at $vmw" }
  } else {
    Fail 'VMware Workstation Pro not found. Download it (free for personal use)'
    Fail 'from the Broadcom support portal -- it needs a login, so it cannot be automated.'
  }

  Step 'Vagrant toolchain'
  $vagrant = Get-Command vagrant -ErrorAction SilentlyContinue
  if ($vagrant) {
    $v = (& vagrant --version) -replace 'Vagrant\s+', ''
    if ([version]$v -ge [version]'2.4.0') { Ok "vagrant $v" } else { Fail "vagrant $v -- need 2.4+" }
    if ((& vagrant plugin list) -match 'vagrant-vmware-desktop') { Ok 'vagrant-vmware-desktop plugin' }
    else { Fail 'vagrant-vmware-desktop plugin missing' }
  } else { Fail 'vagrant not installed' }

  $svc = Get-Service -Name 'vagrant-vmware-utility' -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -eq 'Running') { Ok 'Vagrant VMware Utility service running' }
  elseif ($svc) { Fail "Vagrant VMware Utility service is $($svc.Status) -- Start-Service vagrant-vmware-utility" }
  else { Fail 'Vagrant VMware Utility not installed' }

  Step 'Storage'
  if ($cfg) {
    $drive = (Get-Item $cfg.LabRoot).PSDrive
    $free  = [math]::Round($drive.Free / 1GB)
    if ($free -ge 150) { Ok "$($drive.Name): has ${free} GB free (lab root $($cfg.LabRoot))" }
    else { Warn "$($drive.Name): has only ${free} GB free -- budget ~150 GB" }
    Ok "VAGRANT_HOME = $($cfg.VagrantHome)"
    if ($cfg.KaliMode -eq 'existing') { Ok "using existing Kali: $($cfg.KaliVmx)" }
    else { Ok 'Kali will be created by Vagrant' }
  } else {
    Warn 'no .lab-config.json yet -- run .\lab.ps1 setup'
  }

  Write-Host ''
  if ($script:Failed) {
    Write-Host 'Fix the failures above. .\lab.ps1 setup installs everything except Workstation.' -ForegroundColor Red
    return $false
  }
  Write-Host 'Prerequisites look good. Next: .\lab.ps1 up' -ForegroundColor Green
  return $true
}

# ---------------------------------------------------------------- setup ---
function Select-LabRoot {
  if ($LabRoot) { return $LabRoot }
  Write-Host "`nDrives with free space:" -ForegroundColor Cyan
  $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 } |
            Sort-Object Free -Descending
  foreach ($d in $drives) { '  {0}:  {1,6} GB free' -f $d.Name, [math]::Round($d.Free / 1GB) | Write-Host }
  $best = $drives[0].Name
  $pick = Read-Host "Drive for the lab (VMs, boxes, snapshots) [$best]"
  if (-not $pick) { $pick = $best }
  return ('{0}:\PurpleForest' -f $pick.TrimEnd(':', '\'))
}

function Select-Kali {
  if ($KaliVmx) { return @{ Mode = 'existing'; Vmx = $KaliVmx } }
  $ans = Read-Host "`nDo you already have a Kali VM in VMware Workstation? [y/N]"
  if ($ans -notmatch '^[Yy]') { return @{ Mode = 'vagrant'; Vmx = $null } }

  # Look where Workstation normally keeps VMs before asking for a path.
  $roots = @("$env:USERPROFILE\Documents\Virtual Machines") +
           (Get-PSDrive -PSProvider FileSystem | ForEach-Object { "$($_.Root)Virtual Machines" })
  $found = foreach ($r in $roots) {
    if (Test-Path $r) { Get-ChildItem $r -Recurse -Filter *.vmx -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match 'kali' } }
  }
  $found = @($found | Sort-Object FullName -Unique)

  if ($found.Count -gt 0) {
    Write-Host 'Found these Kali VMs:'
    for ($i = 0; $i -lt $found.Count; $i++) { Write-Host "  [$($i + 1)] $($found[$i].FullName)" }
    $n = Read-Host "Pick one, or paste a path to the .vmx [1]"
    if (-not $n) { $n = '1' }
    if ($n -match '^\d+$') { $vmx = $found[[int]$n - 1].FullName } else { $vmx = $n.Trim('"') }
  } else {
    $vmx = (Read-Host 'Path to your Kali .vmx file').Trim('"')
  }
  if (-not (Test-Path $vmx)) { throw "Not found: $vmx" }
  return @{ Mode = 'existing'; Vmx = $vmx }
}

function Get-RepoInto($root) {
  if (Test-Path (Join-Path $root 'Vagrantfile')) { Ok "repo already at $root"; return }
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  if (Get-Command git -ErrorAction SilentlyContinue) {
    & git clone "https://github.com/$Repo.git" $root
  } else {
    # No git on the host is fine -- pull the zip instead.
    $zip = Join-Path $env:TEMP 'purpleforest.zip'
    Invoke-WebRequest "https://codeload.github.com/$Repo/zip/refs/heads/main" -OutFile $zip -UseBasicParsing
    $tmp = Join-Path $env:TEMP 'purpleforest-unzip'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $zip -DestinationPath $tmp
    Copy-Item (Join-Path (Get-ChildItem $tmp -Directory)[0].FullName '*') $root -Recurse -Force
    Warn 'repo downloaded as a zip (no git on host) -- updates will need a re-download'
  }
  Ok "repo at $root"
}

function Invoke-Setup {
  if (-not (Test-Admin)) { throw 'Run setup from an elevated PowerShell (Run as Administrator).' }
  $script:RebootNeeded = $false

  Step 'Choices'
  $root = Select-LabRoot
  $kali = Select-Kali

  Step 'Repository'
  Get-RepoInto $root

  # Boxes (~40 GB) live in VAGRANT_HOME, which defaults to C:\Users\<you>\.vagrant.d.
  # Plugins install there too, so this must be set BEFORE the plugin install.
  Step 'Storage location'
  $vh = Join-Path $root '.vagrant.d'
  New-Item -ItemType Directory -Force -Path $vh | Out-Null
  [Environment]::SetEnvironmentVariable('VAGRANT_HOME', $vh, 'User')
  $env:VAGRANT_HOME = $vh
  Ok "VAGRANT_HOME -> $vh (boxes and plugins)"
  Ok "VM disks -> $root\.vagrant (Vagrant clones VMs into the project folder)"

  [Environment]::SetEnvironmentVariable('LAB_KALI', $kali.Mode, 'User')
  $env:LAB_KALI = $kali.Mode

  $cfg = [pscustomobject]@{
    LabRoot     = $root
    VagrantHome = $vh
    KaliMode    = $kali.Mode
    KaliVmx     = $kali.Vmx
  }
  Save-LabConfig $cfg
  Ok "choices saved to $root\.lab-config.json"

  Step 'VMware Workstation'
  if (Get-VMwareInstallPath) { Ok 'installed' }
  else {
    Fail 'VMware Workstation Pro is not installed. Install it, then re-run setup.'
    Fail 'It is behind a Broadcom login, so this script cannot download it for you.'
    return
  }

  Step 'Vagrant'
  Update-SessionPath
  if (Get-Command vagrant -ErrorAction SilentlyContinue) { Ok "already installed ($(& vagrant --version))" }
  else { Install-HashiMsi 'vagrant' (Get-LatestVersion 'vagrant' $VagrantFallback) }

  Step 'Vagrant VMware Utility'
  if (Get-Service vagrant-vmware-utility -ErrorAction SilentlyContinue) { Ok 'already installed' }
  else { Install-HashiMsi 'vagrant-vmware-utility' (Get-LatestVersion 'vagrant-vmware-utility' $UtilityFallback) }
  Start-Service vagrant-vmware-utility -ErrorAction SilentlyContinue

  if ($script:RebootNeeded) {
    Warn 'An installer asked for a reboot. Reboot, then run .\lab.ps1 setup again --'
    Warn 'it skips anything already done.'
    return
  }

  Step 'vagrant-vmware-desktop plugin'
  if ((& vagrant plugin list) -match 'vagrant-vmware-desktop') { Ok 'already installed' }
  else { & vagrant plugin install vagrant-vmware-desktop; Ok 'installed' }

  Set-Location $root
  Write-Host ''
  if (Invoke-Check) {
    Write-Host "From now on, work from the lab folder:" -ForegroundColor Cyan
    Write-Host "    cd $root"
    Write-Host '    .\lab.ps1 up'
  }
}

# ------------------------------------------------------ existing Kali NIC --
# Vagrant creates (or reuses) a host-only vmnet for 10.10.10.0/24 when it
# builds dc01. Read which vmnet that was from dc01's .vmx, then give the
# existing Kali VM a NIC on the same one.
function Get-LabVmnet {
  $vmx = Get-ChildItem (Join-Path (Get-Location) '.vagrant\machines\dc01\vmware_desktop') `
           -Recurse -Filter *.vmx -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $vmx) { throw 'dc01 has no .vmx yet -- bring dc01 up first.' }
  $lines = Get-Content $vmx.FullName
  foreach ($l in $lines) {
    if ($l -match '^\s*(ethernet\d+)\.vnet\s*=\s*"(vmnet\d+)"') {
      $nic = $Matches[1]; $net = $Matches[2]
      if ($lines -match "^\s*$nic\.connectiontype\s*=\s*`"custom`"") { return $net }
    }
  }
  throw "Could not find the lab vmnet in $($vmx.FullName). Send this file's ethernet lines."
}

function Connect-ExistingKali($cfg) {
  Step "Attaching existing Kali to the lab network"
  $vmrun = Get-Vmrun
  $vmnet = Get-LabVmnet
  Ok "lab network is $vmnet"

  if ((& $vmrun -T ws list) -contains $cfg.KaliVmx) {
    Warn 'Kali is running. Shut it down, then run .\lab.ps1 up kali to attach it.'
    return
  }

  $lines = Get-Content $cfg.KaliVmx
  if ($lines -match "^\s*ethernet\d+\.vnet\s*=\s*`"$vmnet`"") {
    Ok "Kali already has a NIC on $vmnet"; return
  }

  Copy-Item $cfg.KaliVmx "$($cfg.KaliVmx).pre-purpleforest.bak" -Force
  $used = $lines | ForEach-Object { if ($_ -match '^\s*ethernet(\d+)\.present\s*=\s*"TRUE"') { [int]$Matches[1] } }
  $n = 0; while ($used -contains $n) { $n++ }
  $nic = "ethernet$n"
  Add-Content -Path $cfg.KaliVmx -Value @(
    "$nic.present = `"TRUE`"",
    "$nic.connectionType = `"custom`"",
    "$nic.vnet = `"$vmnet`"",
    "$nic.virtualDev = `"vmxnet3`"",
    "$nic.addressType = `"generated`""
  )
  Ok "added $nic on $vmnet (backup: .pre-purpleforest.bak next to the .vmx)"
  Write-Host ''
  Write-Host '  Start Kali, then inside it:' -ForegroundColor Cyan
  Write-Host '    git clone https://github.com/zebracherry/PurpleForest.git ~/PurpleForest'
  Write-Host '    sudo ~/PurpleForest/scripts/bootstrap-kali.sh'
  Write-Host '  The bootstrap gives the new NIC 10.10.10.50 and installs Ansible.'
}

# ------------------------------------------------------------------- up ---
function Invoke-UpOne($vm) {
  for ($a = 1; $a -le 3; $a++) {
    Write-Host "==> ${vm}: attempt $a/3" -ForegroundColor Yellow
    & vagrant up $vm --provider vmware_desktop
    if ($LASTEXITCODE -eq 0) { Ok "$vm is up"; return $true }
    Warn "$vm failed on attempt $a"
    Start-Sleep 10
  }
  Fail "$vm would not come up after 3 attempts"
  return $false
}

function Invoke-Up {
  $cfg = Use-LabConfig
  if (-not (Invoke-Check)) { return }

  $targets = if ($Target) { @($Target) } else { $LabVMs }
  foreach ($vm in $targets) {
    if ($vm -eq 'kali' -and $cfg.KaliMode -eq 'existing') { Connect-ExistingKali $cfg; continue }
    if (-not (Invoke-UpOne $vm)) { return }
  }
  Write-Host "`nVMs are up. Provision from Kali:" -ForegroundColor Green
  Write-Host '    cd ~/PurpleForest/ansible && ansible-playbook site.yml'
}

# ------------------------------------------------------------ snapshots ---
function Invoke-Snapshots($action) {
  $cfg = Use-LabConfig
  foreach ($vm in $LabVMs) {
    if ($vm -eq 'kali' -and $cfg.KaliMode -eq 'existing') {
      $vmrun = Get-Vmrun
      if ($action -eq 'save') { & $vmrun -T ws snapshot $cfg.KaliVmx purpleforest-baseline }
      else                    { & $vmrun -T ws revertToSnapshot $cfg.KaliVmx purpleforest-baseline }
      continue
    }
    if ($action -eq 'save') { & vagrant snapshot save $vm baseline --force }
    else                    { & vagrant snapshot restore $vm baseline }
  }
}

# ----------------------------------------------------------------- main ---
switch ($Command) {
  'setup'    { Invoke-Setup }
  'check'    { if (Read-LabConfig) { Use-LabConfig | Out-Null }; Invoke-Check | Out-Null }
  'up'       { Invoke-Up }
  'status'   { Use-LabConfig | Out-Null; & vagrant status }
  'snapshot' { Invoke-Snapshots 'save' }
  'restore'  { Invoke-Snapshots 'restore' }
  'destroy'  { Use-LabConfig | Out-Null; & vagrant destroy -f }   # LAB_KALI=existing hides kali from Vagrant
  default    { Get-Help $PSCommandPath -Detailed }
}
