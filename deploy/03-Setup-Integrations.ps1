<#
.SYNOPSIS
    Configure Home Assistant integrations via the API.

.DESCRIPTION
    Sets up Sunsynk, eWeLink/Sonoff, Tapo cameras, Google Cast, and Samsung TV.
    Requires HA_IP, HA_TOKEN, and integration credentials in config.ps1.

    Run AFTER 02-Setup-Addons.ps1 and HACS installation.

.EXAMPLE
    .\03-Setup-Integrations.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
}

function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

# Verify connection
$api = Invoke-HAApi -Endpoint "/api/"
if (-not $api) {
    Write-Fail "Cannot connect to HA at http://$($Config.HA_IP):8123"
    exit 1
}
Write-Success "Connected to HA $($api.version)"

# Get existing integrations to avoid duplicates
$existingEntries = Invoke-HAApi -Endpoint "/api/config/config_entries/entry"

function Test-IntegrationExists {
    param([string]$Domain)
    if ($existingEntries) {
        foreach ($entry in $existingEntries) {
            if ($entry.domain -eq $Domain) { return $true }
        }
    }
    return $false
}

# ============================================================
# 1. SUNSYNK (via HACS)
# ============================================================

Write-Step "Integration 1: Sunsynk (Solar/Energy)"

if (Test-IntegrationExists -Domain "sunsynk") {
    Write-Success "Sunsynk integration already configured"
} elseif ([string]::IsNullOrWhiteSpace($Config.SunsynkUsername)) {
    Write-Info "Sunsynk credentials not set in config.ps1 - skipping"
    Write-Info "Fill in SunsynkUsername and SunsynkPassword, then re-run"
} else {
    Write-Info "Sunsynk requires a HACS custom integration."
    Write-Info ""
    Write-Info "Manual steps required:"
    Write-Info "  1. Open HA > HACS > Integrations > Explore & Download"
    Write-Info "  2. Search for 'Sunsynk' or 'ha-sunsynk'"
    Write-Info "  3. Download and install the integration"
    Write-Info "  4. Restart Home Assistant"
    Write-Info "  5. Go to Settings > Devices & Services > Add Integration > Sunsynk"
    Write-Info "  6. Enter credentials:"
    Write-Info "       Username: $($Config.SunsynkUsername)"
    Write-Info "       Password: (as configured in config.ps1)"
    Write-Info ""
    Write-Info "Note: HACS custom integrations cannot be auto-installed via API."
    Write-Info "The config flow requires interactive setup in the browser."

    # Try to add the HACS repository programmatically
    Write-Info "Attempting to add Sunsynk HACS repository..."
    $hacsResult = Invoke-HAApi -Endpoint "/api/services/hacs/register" -Method "POST" -Body @{
        repository = "kellerza/sunsynk"
        category   = "integration"
    }
    if ($hacsResult) {
        Write-Success "Sunsynk repository added to HACS - install it from HACS UI"
    }
}

# ============================================================
# 2. eWeLink / Sonoff
# ============================================================

Write-Step "Integration 2: eWeLink / Sonoff"

if (Test-IntegrationExists -Domain "sonoff") {
    Write-Success "Sonoff/eWeLink integration already configured"
} elseif ([string]::IsNullOrWhiteSpace($Config.EwelinkUsername)) {
    Write-Info "eWeLink credentials not set in config.ps1 - skipping"
    Write-Info "Fill in EwelinkUsername and EwelinkPassword, then re-run"
} else {
    Write-Info "eWeLink/Sonoff requires a HACS custom integration (AlexxIT/SonoffLAN)."
    Write-Info ""
    Write-Info "Manual steps required:"
    Write-Info "  1. Open HA > HACS > Integrations > Explore & Download"
    Write-Info "  2. Search for 'Sonoff' (by AlexxIT)"
    Write-Info "  3. Download and install"
    Write-Info "  4. Restart Home Assistant"
    Write-Info "  5. Go to Settings > Devices & Services > Add Integration > Sonoff"
    Write-Info "  6. Enter credentials:"
    Write-Info "       Username: $($Config.EwelinkUsername)"
    Write-Info "       Password: (as configured in config.ps1)"
    Write-Info "       Region:   $($Config.EwelinkRegion)"
    Write-Info "  7. Select mode: Cloud (recommended for initial setup)"
    Write-Info ""

    Write-Info "Attempting to add SonoffLAN HACS repository..."
    $hacsResult = Invoke-HAApi -Endpoint "/api/services/hacs/register" -Method "POST" -Body @{
        repository = "AlexxIT/SonoffLAN"
        category   = "integration"
    }
    if ($hacsResult) {
        Write-Success "SonoffLAN repository added to HACS - install it from HACS UI"
    }
}

# ============================================================
# 3. TAPO CAMERAS
# ============================================================

Write-Step "Integration 3: Tapo Cameras"

if ($Config.TapoCameras.Count -eq 0) {
    Write-Info "No Tapo cameras configured in config.ps1 - skipping"
    Write-Info "Add camera entries to the TapoCameras array, then re-run"
} else {
    Write-Info "Setting up $($Config.TapoCameras.Count) Tapo camera(s)..."

    foreach ($cam in $Config.TapoCameras) {
        Write-Info ""
        Write-Info "Camera: $($cam.Name) ($($cam.IP))"

        # Test connectivity
        $ping = Test-Connection -ComputerName $cam.IP -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($ping) {
            Write-Success "  Camera reachable at $($cam.IP)"
        } else {
            Write-Fail "  Camera not reachable at $($cam.IP) - check IP and network"
            continue
        }

        # Check if already configured
        if (Test-IntegrationExists -Domain "tapo") {
            Write-Info "  Tapo integration exists - camera may already be configured"
            continue
        }

        Write-Info "  Tapo cameras need manual setup in HA:"
        Write-Info "    Option A (HACS Tapo integration):"
        Write-Info "      1. HACS > Integrations > Search 'Tapo'"
        Write-Info "      2. Install 'Tapo Controller' integration"
        Write-Info "      3. Settings > Devices & Services > Add > Tapo"
        Write-Info "      4. Enter IP: $($cam.IP) and Tapo cloud credentials"
        Write-Info ""
        Write-Info "    Option B (Generic RTSP camera):"
        Write-Info "      1. Enable RTSP in Tapo app (Camera > Settings > Advanced)"
        Write-Info "      2. Settings > Devices & Services > Add > Generic Camera"
        Write-Info "      3. RTSP URL: rtsp://$($cam.Username):PASSWORD@$($cam.IP):554/stream1"
    }
}

# ============================================================
# 4. GOOGLE CAST
# ============================================================

Write-Step "Integration 4: Google Cast"

if (Test-IntegrationExists -Domain "cast") {
    Write-Success "Google Cast integration already configured"
} else {
    Write-Info "Google Cast uses mDNS auto-discovery."
    Write-Info "Attempting to add integration..."

    # Google Cast is a built-in integration - try config flow
    $flowResult = Invoke-HAApi -Endpoint "/api/config/config_entries/flow" -Method "POST" -Body @{
        handler = "cast"
    }

    if ($flowResult -and $flowResult.flow_id) {
        # Complete the flow (Cast typically auto-completes)
        $complete = Invoke-HAApi -Endpoint "/api/config/config_entries/flow/$($flowResult.flow_id)" -Method "POST" -Body @{}
        if ($complete -and $complete.result -eq "create_entry") {
            Write-Success "Google Cast integration added - devices will be auto-discovered"
        } else {
            Write-Info "Config flow started but may need confirmation in the HA UI"
            Write-Info "  Settings > Devices & Services > check for pending setup"
        }
    } else {
        Write-Info "Could not auto-configure Google Cast."
        Write-Info "  Settings > Devices & Services > Add Integration > Google Cast"
    }
}

# ============================================================
# 5. SAMSUNG TV
# ============================================================

Write-Step "Integration 5: Samsung Smart TV"

if (Test-IntegrationExists -Domain "samsungtv") {
    Write-Success "Samsung TV integration already configured"
} elseif ([string]::IsNullOrWhiteSpace($Config.SamsungTV_IP)) {
    Write-Info "Samsung TV IP not set in config.ps1 - skipping"
    Write-Info "Fill in SamsungTV_IP and re-run, or add manually in HA"
} else {
    $ping = Test-Connection -ComputerName $Config.SamsungTV_IP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $ping) {
        Write-Fail "Samsung TV not reachable at $($Config.SamsungTV_IP)"
        Write-Info "Make sure the TV is powered on and connected to the network"
    } else {
        Write-Success "Samsung TV reachable at $($Config.SamsungTV_IP)"
    }

    Write-Info "Samsung TV requires on-screen pairing approval."
    Write-Info "It must be set up manually in the HA UI:"
    Write-Info "  1. Ensure TV is powered ON"
    Write-Info "  2. Settings > Devices & Services > Add Integration > Samsung Smart TV"
    Write-Info "  3. Enter IP: $($Config.SamsungTV_IP)"
    Write-Info "  4. Accept the pairing request on the TV screen"
}

# ============================================================
# 6. ALLIANCE HEAT PUMP
# ============================================================

Write-Step "Integration 6: Alliance Heat Pump (Pool)"

Write-Info "Alliance heat pump integration status: Research needed"
Write-Info ""
Write-Info "Options to explore:"
Write-Info "  1. Check if the heat pump has WiFi/Modbus connectivity"
Write-Info "  2. Search HA community forums: 'Alliance heat pump'"
Write-Info "  3. Fallback: Use a Sonoff POW relay for on/off + power monitoring"
Write-Info "  4. Add a waterproof DS18B20 temperature sensor to the pool"
Write-Info ""
Write-Info "This will be configured in a future phase."

# ============================================================
# SUMMARY
# ============================================================

Write-Step "Integration Setup Summary"

$integrations = @(
    @{ Name = "Sunsynk";         Status = if (Test-IntegrationExists "sunsynk") { "Configured" } elseif ($Config.SunsynkUsername) { "Needs HACS Install" } else { "No Credentials" } },
    @{ Name = "Sonoff/eWeLink";  Status = if (Test-IntegrationExists "sonoff")  { "Configured" } elseif ($Config.EwelinkUsername) { "Needs HACS Install" } else { "No Credentials" } },
    @{ Name = "Tapo Cameras";    Status = if ($Config.TapoCameras.Count -gt 0)  { "Manual Setup Needed" } else { "No Cameras Configured" } },
    @{ Name = "Google Cast";     Status = if (Test-IntegrationExists "cast")    { "Configured" } else { "Manual Setup" } },
    @{ Name = "Samsung TV";      Status = if (Test-IntegrationExists "samsungtv") { "Configured" } elseif ($Config.SamsungTV_IP) { "Manual Pairing Needed" } else { "No IP Set" } },
    @{ Name = "Alliance Pool";   Status = "Future Phase" }
)

Write-Host ""
foreach ($i in $integrations) {
    $color = switch -Wildcard ($i.Status) {
        "Configured"  { "Green" }
        "Needs*"      { "Yellow" }
        "Manual*"     { "Yellow" }
        "No*"         { "DarkGray" }
        default       { "DarkGray" }
    }
    Write-Host "  $($i.Name.PadRight(20)) $($i.Status)" -ForegroundColor $color
}
Write-Host ""
Write-Host "  Note: HACS custom integrations (Sunsynk, Sonoff) require" -ForegroundColor Yellow
Write-Host "  manual install via HACS UI, then configure in HA." -ForegroundColor Yellow
Write-Host ""
