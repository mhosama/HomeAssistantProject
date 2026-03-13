<#
.SYNOPSIS
    Set up RTSP-only cameras via the Generic Camera config flow.

.DESCRIPTION
    For cameras that only expose RTSP streams (no Tapo management API),
    use HA's built-in Generic Camera integration.

    NOTE: The Generic Camera config flow validates RTSP connectivity and
    times out if the stream is behind a NAT gateway (.2). In that case,
    add cameras directly to configuration.yaml using the ffmpeg platform
    via Samba share (\\192.168.0.239\config\configuration.yaml).

    This script is kept as reference for the camera list and as a fallback
    for cameras with directly reachable RTSP streams.

.EXAMPLE
    .\07c-Setup-RtspCameras.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# RTSP-only camera definitions
# ============================================================

$cameras = @(
    @{
        Name   = "Main Gate Camera"
        Stream = "rtsp://mhocontrol:T3rrabyte@192.168.0.2:5102/stream2"
    },
    @{
        Name   = "Visitor Gate Camera"
        Stream = "rtsp://mhocontrol:T3rrabyte@192.168.0.2:5103/stream2"
    },
    @{
        Name   = "Pool Camera"
        Stream = "rtsp://mhocontrol:T3rrabyte@192.168.0.2:5104/stream2"
    },
    @{
        Name   = "Garage Camera"
        Stream = "rtsp://mhocontrol:T3rrabyte@192.168.0.2:5106/stream2"
    },
    @{
        Name   = "Lounge Camera"
        Stream = "rtsp://mhocontrol:T3rrabyte@192.168.0.2:5110/stream2"
    },
    @{
        Name   = "Street Camera"
        Stream = "rtsp://mhocontrol:T3rrabyte@192.168.0.2:5101/stream2"
    }
)

# ============================================================
# Output helpers
# ============================================================

function Write-Step    { param([string]$Message); Write-Host ""; Write-Host "===================================================" -ForegroundColor Cyan; Write-Host " $Message" -ForegroundColor Cyan; Write-Host "===================================================" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

# ============================================================
# REST helper
# ============================================================

function Invoke-HAREST {
    param([string]$Endpoint, [string]$Method = "GET", [string]$JsonBody = $null)
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $headers = @{ "Authorization" = "Bearer $($Config.HA_TOKEN)"; "Content-Type" = "application/json" }
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($JsonBody) { $params.Body = $JsonBody }
    try { return Invoke-RestMethod @params } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Fail "REST $Method $Endpoint -> HTTP $status"
        return $null
    }
}

# ============================================================
# Step 1: Check existing generic camera entries
# ============================================================

Write-Step "Step 1: Check existing generic camera config entries"

$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$existingGenericStreams = @()
if ($existingEntries) {
    $genericEntries = @($existingEntries | Where-Object { $_.domain -eq "generic" })
    foreach ($ge in $genericEntries) {
        if ($ge.data -and $ge.data.stream_source) {
            $existingGenericStreams += $ge.data.stream_source
        }
    }
    Write-Info "Found $($genericEntries.Count) existing generic camera entries"
} else {
    Write-Info "No existing config entries found"
}

# ============================================================
# Step 2: Set up each RTSP camera
# ============================================================

$successCount = 0
$failedCount = 0

foreach ($cam in $cameras) {
    Write-Step "Setting up $($cam.Name)"
    Write-Info "Stream: $($cam.Stream)"

    # Check if already configured (match by stream URL)
    if ($existingGenericStreams -contains $cam.Stream) {
        Write-Success "$($cam.Name) already configured - skipping"
        $successCount++
        continue
    }

    # Start generic camera config flow
    Write-Info "Starting config flow..."
    $flowBody = @{ handler = "generic" } | ConvertTo-Json
    $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody

    if (-not $flow) {
        Write-Fail "Could not start config flow for $($cam.Name)"
        $failedCount++
        continue
    }

    $flowId = $flow.flow_id
    Write-Info "Flow $flowId started, step: $($flow.step_id)"

    # Submit the user step with stream URL and advanced settings
    # Credentials are in the URL, so username/password fields stay empty
    $stepBody = @{
        stream_source   = $cam.Stream
        still_image_url = ""
        username        = ""
        password        = ""
        advanced        = @{
            framerate      = 2
            verify_ssl     = $false
            rtsp_transport = "tcp"
            authentication = "basic"
        }
    } | ConvertTo-Json -Depth 3

    Write-Info "Submitting stream configuration (may take 30s to verify stream)..."
    $result = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "POST" -JsonBody $stepBody

    if (-not $result) {
        Write-Fail "Config flow submission failed for $($cam.Name)"
        $failedCount++
        continue
    }

    # Check result
    if ($result.type -eq "create_entry") {
        Write-Success "$($cam.Name) configured! Entry: $($result.title)"
        $successCount++
    } elseif ($result.type -eq "form" -and $result.errors) {
        $errJson = $result.errors | ConvertTo-Json -Compress
        Write-Fail "Error: $errJson"

        if ($errJson -like "*timeout*" -or $errJson -like "*connection*") {
            Write-Fail "Stream unreachable from HA. Check that the camera is on and HA can reach the IP."
            Write-Info "Tip: Try running this script from the server itself for better network access."
        }

        # Abort the failed flow
        $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "DELETE"
        $failedCount++
    } elseif ($result.type -eq "abort") {
        Write-Fail "$($cam.Name) flow aborted: $($result.reason)"
        $failedCount++
    } else {
        Write-Fail "Unexpected response type: $($result.type)"
        Write-Host "  $($result | ConvertTo-Json -Depth 5 -Compress)" -ForegroundColor Gray
        $failedCount++
    }
}

# ============================================================
# Step 3: Verify camera entities
# ============================================================

Write-Step "Step 3: Verify camera entities"

Write-Info "Waiting 5 seconds for entities to register..."
Start-Sleep -Seconds 5

$states = Invoke-HAREST -Endpoint "/api/states"
if ($states) {
    $cameraEntities = @($states | Where-Object { $_.entity_id -like "camera.*" })
    Write-Info "Found $($cameraEntities.Count) total camera entities:"
    foreach ($ce in $cameraEntities) {
        $state = $ce.state
        $friendly = $ce.attributes.friendly_name
        Write-Host "    $($ce.entity_id) ($friendly) - $state" -ForegroundColor White
    }
} else {
    Write-Info "Could not query states"
}

# ============================================================
# Done
# ============================================================

Write-Step "Done! ($successCount OK, $failedCount failed out of $($cameras.Count) cameras)"
Write-Host ""
Write-Host "  Verify:" -ForegroundColor White
Write-Host "    1. HA UI > Settings > Devices & Services > Generic Camera" -ForegroundColor Gray
Write-Host "    2. Developer Tools > States > camera.*" -ForegroundColor Gray
Write-Host "    3. Try loading a camera stream in a dashboard" -ForegroundColor Gray
Write-Host ""
if ($failedCount -gt 0) {
    Write-Host "  If streams timed out, try running this script from the HA server itself." -ForegroundColor Yellow
    Write-Host ""
}
