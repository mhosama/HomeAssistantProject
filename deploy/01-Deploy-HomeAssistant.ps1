#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Home Assistant OS - Hyper-V Deployment Script

.DESCRIPTION
    One-click deployment of HAOS on Hyper-V. Downloads the latest HAOS VHDX image,
    creates a Gen2 VM with correct settings, and starts it.

    Run this script on the Hyper-V host server (192.168.0.156) as Administrator.

.EXAMPLE
    .\Deploy-HomeAssistant.ps1

.NOTES
    - Requires Hyper-V to be enabled
    - Requires internet access to download HAOS image
    - Will create VM files at C:\VMs\HomeAssistant\
#>

$ErrorActionPreference = "Stop"

# Load shared config
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

$VMName      = $Config.VMName
$VMPath      = $Config.VMPath
$HAOSVersion = $Config.HAOSVersion
$CPUCount    = $Config.CPUCount
$MemoryBytes = $Config.MemoryBytes
$SwitchName  = $Config.SwitchName

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [..] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================

Write-Step "Step 0: Pre-flight checks"

# Check admin
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "This script must be run as Administrator. Right-click PowerShell > Run as Administrator."
    exit 1
}
Write-Success "Running as Administrator"

# Check Hyper-V
$hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
if ($hyperv.State -ne "Enabled") {
    Write-Info "Hyper-V is not enabled. Enabling now (will require a reboot)..."
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
    Write-Fail "Hyper-V has been enabled but a REBOOT IS REQUIRED."
    Write-Fail "Please reboot the server and run this script again."
    exit 2
}
Write-Success "Hyper-V is enabled"

# Check if VM already exists
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Fail "A VM named '$VMName' already exists (State: $($existingVM.State))."
    Write-Fail "To re-deploy, first remove it:  Remove-VM -Name '$VMName' -Force"
    exit 3
}
Write-Success "No conflicting VM found"

# ============================================================
# STEP 1: FIX NETWORK PROFILE (if Public)
# ============================================================

Write-Step "Step 1: Checking network profile"

$publicProfiles = Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' }
if ($publicProfiles) {
    Write-Info "Found Public network profile(s). Setting to Private..."
    $publicProfiles | Set-NetConnectionProfile -NetworkCategory Private
    Write-Success "Network profile set to Private"
} else {
    Write-Success "Network profile is already Private or Domain"
}

# ============================================================
# STEP 2: ENABLE PS REMOTING (for future remote management)
# ============================================================

Write-Step "Step 2: Enabling PowerShell Remoting"

try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck 2>$null
    Write-Success "PowerShell Remoting enabled"
} catch {
    Write-Info "Could not enable PS Remoting (non-fatal): $($_.Exception.Message)"
}

# ============================================================
# STEP 3: CREATE VM DIRECTORY
# ============================================================

Write-Step "Step 3: Creating VM directory"

if (-not (Test-Path $VMPath)) {
    New-Item -Path $VMPath -ItemType Directory -Force | Out-Null
}
Write-Success "VM directory: $VMPath"

# ============================================================
# STEP 4: DOWNLOAD HAOS VHDX IMAGE
# ============================================================

Write-Step "Step 4: Downloading HAOS $HAOSVersion VHDX image"

$haosUrl = "https://github.com/home-assistant/operating-system/releases/download/$HAOSVersion/haos_ova-$HAOSVersion.vhdx.zip"
$zipPath = "$VMPath\haos_ova-$HAOSVersion.vhdx.zip"
$vhdxPath = "$VMPath\haos_ova-$HAOSVersion.vhdx"

if (Test-Path $vhdxPath) {
    Write-Success "VHDX already exists at $vhdxPath - skipping download"
} else {
    Write-Info "Downloading from: $haosUrl"
    Write-Info "This may take a few minutes..."

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Use BITS for more reliable download, fall back to WebClient
        try {
            Start-BitsTransfer -Source $haosUrl -Destination $zipPath -Description "Downloading HAOS $HAOSVersion"
        } catch {
            Write-Info "BITS transfer failed, trying direct download..."
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($haosUrl, $zipPath)
        }

        Write-Success "Downloaded to $zipPath"

        Write-Info "Extracting VHDX..."
        Expand-Archive -Path $zipPath -DestinationPath $VMPath -Force
        Remove-Item $zipPath -Force

        if (-not (Test-Path $vhdxPath)) {
            # The extracted file might be in a subfolder or have a different name
            $foundVhdx = Get-ChildItem -Path $VMPath -Filter "*.vhdx" -Recurse | Select-Object -First 1
            if ($foundVhdx) {
                Move-Item -Path $foundVhdx.FullName -Destination $vhdxPath -Force
                Write-Success "VHDX extracted to $vhdxPath"
            } else {
                Write-Fail "Could not find VHDX file after extraction"
                Write-Info "Contents of $VMPath :"
                Get-ChildItem -Path $VMPath -Recurse | ForEach-Object { Write-Host "    $($_.FullName)" }
                exit 4
            }
        } else {
            Write-Success "VHDX extracted to $vhdxPath"
        }
    } catch {
        Write-Fail "Download failed: $($_.Exception.Message)"
        Write-Info "You can manually download the VHDX from:"
        Write-Info "  https://www.home-assistant.io/installation/windows"
        Write-Info "Place the .vhdx file at: $vhdxPath"
        exit 4
    }
}

# Resize VHDX to 64GB (HAOS default is small)
Write-Info "Resizing VHDX to 64GB..."
try {
    Resize-VHD -Path $vhdxPath -SizeBytes 64GB
    Write-Success "VHDX resized to 64GB"
} catch {
    Write-Info "Could not resize VHDX (non-fatal - HA can expand storage later): $($_.Exception.Message)"
}

# ============================================================
# STEP 5: CREATE EXTERNAL VIRTUAL SWITCH
# ============================================================

Write-Step "Step 5: Creating external virtual switch"

$existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($existingSwitch) {
    Write-Success "Switch '$SwitchName' already exists"
} else {
    # Check if any external switch already exists (reuse it instead of creating a new one)
    $anyExternal = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' } | Select-Object -First 1
    if ($anyExternal) {
        Write-Info "Found existing external switch: '$($anyExternal.Name)' - reusing it"
        $SwitchName = $anyExternal.Name
    } else {
        # Find the best physical adapter (connected, fastest)
        $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property LinkSpeed -Descending

        if (-not $adapters) {
            Write-Fail "No active physical network adapters found!"
            Write-Info "Available adapters:"
            Get-NetAdapter | ForEach-Object { Write-Host "    $($_.Name) - Status: $($_.Status) - Physical: $($_.Physical)" }
            exit 5
        }

        $selectedAdapter = $adapters[0]
        $adapterName = $selectedAdapter.Name
        Write-Info "Using adapter: $adapterName ($($selectedAdapter.LinkSpeed))"
        Write-Info "Interface: $($selectedAdapter.InterfaceDescription)"

        # Check if adapter is already bound to another switch
        $boundSwitch = Get-VMSwitch | Where-Object { $_.NetAdapterInterfaceDescription -eq $selectedAdapter.InterfaceDescription }
        if ($boundSwitch) {
            Write-Info "Adapter '$adapterName' is already bound to switch '$($boundSwitch.Name)' - reusing it"
            $SwitchName = $boundSwitch.Name
        } else {
            # Try using InterfaceDescription first (more reliable than Name)
            try {
                Write-Info "Creating external switch using InterfaceDescription..."
                New-VMSwitch -Name $SwitchName `
                    -NetAdapterInterfaceDescription $selectedAdapter.InterfaceDescription `
                    -AllowManagementOS $true `
                    -ErrorAction Stop
                Write-Success "External switch '$SwitchName' created"
            } catch {
                Write-Info "InterfaceDescription method failed: $($_.Exception.Message)"
                Write-Info "Trying with adapter Name..."
                try {
                    New-VMSwitch -Name $SwitchName `
                        -NetAdapterName $adapterName `
                        -AllowManagementOS $true `
                        -ErrorAction Stop
                    Write-Success "External switch '$SwitchName' created"
                } catch {
                    Write-Fail "Could not create external switch: $($_.Exception.Message)"
                    Write-Info ""
                    Write-Info "Available physical adapters:"
                    Get-NetAdapter -Physical | ForEach-Object {
                        Write-Host "    Name: $($_.Name)  Desc: $($_.InterfaceDescription)  Status: $($_.Status)" -ForegroundColor DarkGray
                    }
                    Write-Info ""
                    Write-Info "Existing switches:"
                    Get-VMSwitch | ForEach-Object {
                        Write-Host "    Name: $($_.Name)  Type: $($_.SwitchType)  Adapter: $($_.NetAdapterInterfaceDescription)" -ForegroundColor DarkGray
                    }
                    Write-Info ""
                    Write-Info "Try creating manually:"
                    Write-Info "  New-VMSwitch -Name '$SwitchName' -NetAdapterName '<ADAPTER_NAME>' -AllowManagementOS `$true"
                    Write-Info ""
                    Write-Info "Or use Default Switch (NAT, no bridged IP):"
                    Write-Info "  Re-run with a Default Switch by editing config.ps1: SwitchName = 'Default Switch'"
                    exit 5
                }
            }

            Write-Info "Waiting for network to stabilize..."
            Start-Sleep -Seconds 10

            # Verify host still has network
            $hostNet = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($hostNet) {
                Write-Success "Host network connectivity confirmed"
            } else {
                Write-Info "Host network may be temporarily disrupted (normal after switch creation)"
                Write-Info "Waiting for recovery..."
                Start-Sleep -Seconds 15
            }
        }
    }
}

# ============================================================
# STEP 6: CREATE THE VM
# ============================================================

Write-Step "Step 6: Creating Hyper-V VM '$VMName'"

# Create VM
New-VM -Name $VMName `
    -Generation 2 `
    -MemoryStartupBytes $MemoryBytes `
    -Path $VMPath `
    -SwitchName $SwitchName `
    -NoVHD

Write-Success "VM created (Gen2, $($MemoryBytes / 1GB)GB RAM)"

# Attach VHDX
Add-VMHardDiskDrive -VMName $VMName -Path $vhdxPath
Write-Success "VHDX attached"

# Configure CPU
Set-VM -Name $VMName -ProcessorCount $CPUCount
Write-Success "CPU count: $CPUCount"

# Auto-start with host
Set-VM -Name $VMName `
    -AutomaticStartAction Start `
    -AutomaticStopAction ShutDown `
    -AutomaticStartDelay 30
Write-Success "Auto-start configured (30s delay)"

# Disable Secure Boot (required for HAOS)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Write-Success "Secure Boot disabled"

# Set boot order to VHDX
$hdd = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $hdd
Write-Success "Boot order set to VHDX"

# Enable dynamic memory with reasonable bounds
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -MinimumBytes 2GB -MaximumBytes 8GB
Write-Success "Dynamic memory: 2GB min, 4GB startup, 8GB max"

# ============================================================
# STEP 7: START THE VM
# ============================================================

Write-Step "Step 7: Starting the VM"

Start-VM -Name $VMName
Write-Success "VM started"

Write-Info "Waiting for HAOS to boot (this takes 2-5 minutes on first boot)..."
Write-Info "Checking for IP address..."

$haIP = $null
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 10

    $vmNet = Get-VMNetworkAdapter -VMName $VMName
    $ips = $vmNet.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -ne '169.254' }

    if ($ips) {
        $haIP = $ips[0]
        Write-Success "VM got IP address: $haIP"
        break
    }

    Write-Host "    Attempt $i/30 - waiting..." -ForegroundColor DarkGray
}

# ============================================================
# STEP 8: VERIFY ACCESS
# ============================================================

Write-Step "Step 8: Verifying Home Assistant access"

if ($haIP) {
    Write-Info "Waiting for HA web interface to become available..."

    $haReady = $false
    for ($i = 1; $i -le 30; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "http://${haIP}:8123" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($response.StatusCode -eq 200) {
                $haReady = $true
                break
            }
        } catch {}

        Write-Host "    Attempt $i/30 - HA is starting up..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }

    if ($haReady) {
        Write-Success "Home Assistant is accessible!"
    } else {
        Write-Info "HA web interface not ready yet (first boot can take up to 20 minutes)"
        Write-Info "Keep trying: http://${haIP}:8123"
    }
} else {
    Write-Info "Could not determine VM IP address yet."
    Write-Info "Check the VM console for the IP: vmconnect.exe localhost $VMName"
}

# ============================================================
# SUMMARY
# ============================================================

Write-Step "Deployment Complete!"

$vm = Get-VM -Name $VMName
Write-Host ""
Write-Host "  VM Name:      $VMName" -ForegroundColor White
Write-Host "  VM State:     $($vm.State)" -ForegroundColor White
Write-Host "  CPUs:         $CPUCount" -ForegroundColor White
Write-Host "  Memory:       $($MemoryBytes / 1GB)GB (dynamic 2-8GB)" -ForegroundColor White
Write-Host "  VHDX:         $vhdxPath" -ForegroundColor White
Write-Host "  Switch:       $SwitchName" -ForegroundColor White

if ($haIP) {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  Home Assistant URL:  http://${haIP}:8123" -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Open http://${haIP}:8123 in your browser" -ForegroundColor White
    Write-Host "    2. Complete the onboarding wizard" -ForegroundColor White
    Write-Host "    3. Set location to Randpark, timezone to Africa/Johannesburg" -ForegroundColor White
    Write-Host "    4. Install add-ons: File Editor, Terminal & SSH, Samba Share" -ForegroundColor White
    Write-Host "    5. Install HACS for custom integrations" -ForegroundColor White
} else {
    Write-Host ""
    Write-Host "  Open VM console to find the IP:" -ForegroundColor Yellow
    Write-Host "    vmconnect.exe localhost $VMName" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Then access HA at: http://<IP>:8123" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor DarkGray
Write-Host "    Get-VM -Name '$VMName'                        # Check VM status" -ForegroundColor DarkGray
Write-Host "    Stop-VM -Name '$VMName'                       # Stop VM" -ForegroundColor DarkGray
Write-Host "    Checkpoint-VM -Name '$VMName' -SnapshotName 'Baseline'  # Snapshot" -ForegroundColor DarkGray
Write-Host ""
