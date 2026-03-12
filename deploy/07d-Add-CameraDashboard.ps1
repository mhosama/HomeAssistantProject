<#
.SYNOPSIS
    Add camera feeds to the Security dashboard.

.DESCRIPTION
    Adds a "Cameras" tab to the existing Security dashboard with picture-glance
    cards for all configured camera entities (Tapo + Generic RTSP).

    Uses SD streams for dashboard thumbnails (lower bandwidth) with tap-action
    to open the HD stream in a dialog.

.EXAMPLE
    .\07d-Add-CameraDashboard.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# Output helpers
# ============================================================

function Write-Step    { param([string]$Message); Write-Host ""; Write-Host "===================================================" -ForegroundColor Cyan; Write-Host " $Message" -ForegroundColor Cyan; Write-Host "===================================================" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

# ============================================================
# WebSocket helpers (same as 04a)
# ============================================================

$script:ws = $null
$script:cts = $null
$script:wsId = 0

function Connect-HAWS {
    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $script:cts.CancelAfter(300000)
    $script:wsId = 0
    $uri = [Uri]"ws://$($Config.HA_IP):8123/api/websocket"
    Write-Info "Connecting to WebSocket at $uri..."
    $script:ws.ConnectAsync($uri, $script:cts.Token).Wait()
    $null = Receive-HAWS
    $authMsg = @{type = "auth"; access_token = $Config.HA_TOKEN} | ConvertTo-Json -Compress
    Send-HAWS $authMsg
    $authResp = Receive-HAWS | ConvertFrom-Json
    if ($authResp.type -ne "auth_ok") { Write-Fail "Auth failed"; exit 1 }
    Write-Success "Connected to Home Assistant $($authResp.ha_version)"
}

function Send-HAWS([string]$msg) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
    $segment = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $script:ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $script:cts.Token).Wait()
}

function Receive-HAWS {
    $all = ""
    do {
        $buf = New-Object byte[] 65536
        $segment = New-Object System.ArraySegment[byte] -ArgumentList (, $buf)
        $result = $script:ws.ReceiveAsync($segment, $script:cts.Token).Result
        $all += [System.Text.Encoding]::UTF8.GetString($buf, 0, $result.Count)
    } while (-not $result.EndOfMessage)
    return $all
}

function Invoke-WSCommand {
    param([string]$Type, [hashtable]$Extra = @{})
    $script:wsId++
    $msg = @{ id = $script:wsId; type = $Type } + $Extra
    Send-HAWS ($msg | ConvertTo-Json -Depth 20 -Compress)
    $resp = Receive-HAWS | ConvertFrom-Json
    return $resp
}

function Disconnect-HAWS {
    if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait()
    }
}

function Invoke-HAREST {
    param([string]$Endpoint, [string]$Method = "GET", [string]$JsonBody = $null)
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $headers = @{ "Authorization" = "Bearer $($Config.HA_TOKEN)"; "Content-Type" = "application/json" }
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($JsonBody) { $params.Body = $JsonBody }
    try { return Invoke-RestMethod @params } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Fail "REST $Method $Endpoint -> HTTP $status"
        return $null
    }
}

# ============================================================
# Connect
# ============================================================

Write-Step "Connecting to Home Assistant"
Connect-HAWS

# ============================================================
# Step 1: Discover all camera entities
# ============================================================

Write-Step "Step 1: Discover camera entities"

$states = Invoke-HAREST -Endpoint "/api/states"
if (-not $states) {
    Write-Fail "Could not query states"
    Disconnect-HAWS
    exit 1
}

$cameraEntities = @($states | Where-Object { $_.entity_id -like "camera.*" })
Write-Info "Found $($cameraEntities.Count) camera entities"

# Group cameras: SD streams for dashboard thumbnails, HD for full view
# Tapo cameras create pairs: *_hd_stream and *_sd_stream
# Generic cameras create a single entity

$cameraCards = @()

# Find Tapo camera pairs (SD for display, tap to open HD)
$sdCameras = @($cameraEntities | Where-Object { $_.entity_id -like "*_sd_stream" })
$hdCameras = @($cameraEntities | Where-Object { $_.entity_id -like "*_hd_stream" })
$genericCameras = @($cameraEntities | Where-Object { $_.entity_id -notlike "*_sd_stream" -and $_.entity_id -notlike "*_hd_stream" })

foreach ($sd in $sdCameras) {
    # Derive friendly name (strip " SD Stream" suffix)
    $name = $sd.attributes.friendly_name -replace " SD Stream$", ""
    # Find matching HD entity
    $hdId = $sd.entity_id -replace "_sd_stream$", "_hd_stream"

    $cameraCards += @{
        type        = "picture-glance"
        title       = $name
        camera_image = $sd.entity_id
        entity      = $sd.entity_id
        camera_view = "live"
        entities    = @()
        tap_action  = @{
            action          = "fire-dom-event"
            browser_mod     = @{
                service = "browser_mod.more_info"
                data    = @{ entity = $hdId }
            }
        }
    }
    Write-Info "  $name -> $($sd.entity_id) (tap: $hdId)"
}

# Add generic RTSP cameras (single entity, no HD/SD split)
foreach ($gc in $genericCameras) {
    $name = $gc.attributes.friendly_name
    $cameraCards += @{
        type         = "picture-glance"
        title        = $name
        camera_image = $gc.entity_id
        entity       = $gc.entity_id
        camera_view  = "live"
        entities     = @()
    }
    Write-Info "  $name -> $($gc.entity_id)"
}

Write-Success "Built $($cameraCards.Count) camera cards"

if ($cameraCards.Count -eq 0) {
    Write-Fail "No camera entities found - nothing to add to dashboard"
    Disconnect-HAWS
    exit 1
}

# ============================================================
# Step 2: Get current Security dashboard config
# ============================================================

Write-Step "Step 2: Load current Security dashboard"

$currentConfig = Invoke-WSCommand -Type "lovelace/config" -Extra @{ url_path = "security-dashboard" }

if (-not $currentConfig.success) {
    Write-Fail "Could not load security dashboard: $($currentConfig.error.message)"
    Disconnect-HAWS
    exit 1
}

$dashConfig = $currentConfig.result
$existingViews = @($dashConfig.views)
Write-Info "Current dashboard has $($existingViews.Count) view(s)"

# ============================================================
# Step 3: Build camera grid view
# ============================================================

Write-Step "Step 3: Build Cameras view"

# Wrap camera cards in a grid for a nice 2-column layout
$cameraView = @{
    title = "Cameras"
    path  = "cameras"
    icon  = "mdi:cctv"
    cards = @(
        @{
            type    = "grid"
            columns = 2
            square  = $false
            cards   = $cameraCards
        }
    )
}

# ============================================================
# Step 4: Save updated dashboard
# ============================================================

Write-Step "Step 4: Save updated Security dashboard"

# Remove existing cameras view if present (idempotent)
$updatedViews = @($existingViews | Where-Object { $_.path -ne "cameras" })
$updatedViews += $cameraView

$dashConfig.views = $updatedViews

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashConfig
    url_path = "security-dashboard"
}

if ($saveResp.success) {
    Write-Success "Security dashboard updated with Cameras tab!"
} else {
    Write-Fail "Save failed: $($saveResp.error.message)"
}

# ============================================================
# Done
# ============================================================

Disconnect-HAWS

Write-Step "Done! $($cameraCards.Count) cameras added to Security dashboard"
Write-Host ""
Write-Host "  View at: http://$($Config.HA_IP):8123/security-dashboard/cameras" -ForegroundColor White
Write-Host ""
Write-Host "  Camera list:" -ForegroundColor White
foreach ($cc in $cameraCards) {
    Write-Host "    - $($cc.title) ($($cc.camera_image))" -ForegroundColor Gray
}
Write-Host ""
