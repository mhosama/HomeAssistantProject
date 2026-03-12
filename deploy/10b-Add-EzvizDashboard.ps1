<#
.SYNOPSIS
    Add EZVIZ farm camera vision analysis sensors to the Security dashboard.

.DESCRIPTION
    Adds a "Farm Cameras" view to the Security dashboard with:
    - Fire/smoke detection status
    - Rain status
    - Animal summary
    - Human/vehicle detection
    - Per-camera status cards

.EXAMPLE
    .\10b-Add-EzvizDashboard.ps1
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
# WebSocket helpers
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

# ============================================================
# Connect
# ============================================================

Write-Step "Connecting to Home Assistant"
Connect-HAWS

# ============================================================
# Step 1: Add Farm Cameras view to Security dashboard
# ============================================================

Write-Step "Step 1: Update Security dashboard"

$currentConfig = Invoke-WSCommand -Type "lovelace/config" -Extra @{ url_path = "security-dashboard" }

if (-not $currentConfig.success) {
    Write-Fail "Could not load security dashboard: $($currentConfig.error.message)"
    Disconnect-HAWS
    exit 1
}

$dashConfig = $currentConfig.result
$existingViews = @($dashConfig.views)
Write-Info "Current security dashboard has $($existingViews.Count) view(s)"

# Build Farm Cameras view
$farmView = @{
    title = "Farm Cameras"
    path  = "farm-cameras"
    icon  = "mdi:barn"
    cards = @(
        # Critical alerts section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type       = "custom:mushroom-template-card"
                    primary    = "Farm Alerts"
                    icon       = "mdi:alert-circle"
                    icon_color = "{{ 'red' if not is_state('sensor.farm_fire_smoke', 'none') else 'green' }}"
                    secondary  = "Fire: {{ states('sensor.farm_fire_smoke') }} | Rain: {{ states('sensor.farm_rain_status') }}"
                }
                @{
                    type    = "grid"
                    columns = 2
                    square  = $false
                    cards   = @(
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.farm_fire_smoke"
                            name       = "Fire/Smoke"
                            icon       = "mdi:fire-alert"
                            icon_color = "{{ 'red' if not is_state('sensor.farm_fire_smoke', 'none') else 'green' }}"
                        }
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.farm_rain_status"
                            name       = "Rain"
                            icon       = "mdi:weather-rainy"
                            icon_color = "{{ 'blue' if not is_state('sensor.farm_rain_status', 'none') else 'grey' }}"
                        }
                    )
                }
            )
        }
        # Animals & Security section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type       = "custom:mushroom-template-card"
                    primary    = "Farm Detection"
                    icon       = "mdi:cow"
                    icon_color = "amber"
                    secondary  = "Animals: {{ states('sensor.farm_animal_summary') }}"
                }
                @{
                    type    = "grid"
                    columns = 2
                    square  = $false
                    cards   = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.farm_animal_summary"
                            name   = "Animals"
                            icon   = "mdi:cow"
                        }
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.farm_human_vehicle_summary"
                            name       = "Humans/Vehicles"
                            icon       = "mdi:account-alert"
                            icon_color = "{{ 'red' if not is_state('sensor.farm_human_vehicle_summary', 'clear') else 'green' }}"
                        }
                    )
                }
            )
        }
        # Per-camera snapshot + status section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type       = "custom:mushroom-template-card"
                    primary    = "Camera Snapshots"
                    icon       = "mdi:cctv"
                    icon_color = "blue"
                    secondary  = "EZVIZ farm cameras - on-demand capture every 5 min"
                }
                # Camera 1 - on-demand capture image + AI status
                @{
                    type    = "markdown"
                    title   = "Farm Camera 1"
                    content = "{% set pic = state_attr('sensor.farm_cam_1_status', 'entity_picture') %}{% if pic %}<img src=`"{{ pic }}`" style=`"width:100%;border-radius:8px`">{% else %}*No capture available*{% endif %}`n**Status:** {{ states('sensor.farm_cam_1_status') }} | **Battery:** {{ states('sensor.farm_cam_1_battery') }}%"
                }
                # Camera 3 - on-demand capture image + AI status
                @{
                    type    = "markdown"
                    title   = "Farm Camera 3"
                    content = "{% set pic = state_attr('sensor.farm_cam_3_status', 'entity_picture') %}{% if pic %}<img src=`"{{ pic }}`" style=`"width:100%;border-radius:8px`">{% else %}*No capture available*{% endif %}`n**Status:** {{ states('sensor.farm_cam_3_status') }} | **Battery:** {{ states('sensor.farm_cam_3_battery') }}%"
                }
                # Camera 5 - on-demand capture image + AI status
                @{
                    type    = "markdown"
                    title   = "Farm Camera 5"
                    content = "{% set pic = state_attr('sensor.farm_cam_5_status', 'entity_picture') %}{% if pic %}<img src=`"{{ pic }}`" style=`"width:100%;border-radius:8px`">{% else %}*No capture available*{% endif %}`n**Status:** {{ states('sensor.farm_cam_5_status') }} | **Battery:** {{ states('sensor.farm_cam_5_battery') }}%"
                }
            )
        }
        # Battery status section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type       = "custom:mushroom-template-card"
                    primary    = "Battery Status"
                    icon       = "mdi:battery"
                    icon_color = "green"
                    secondary  = "Cam1: {{ states('sensor.farm_cam_1_battery') }}% | Cam3: {{ states('sensor.farm_cam_3_battery') }}% | Cam5: {{ states('sensor.farm_cam_5_battery') }}%"
                }
                @{
                    type    = "grid"
                    columns = 3
                    square  = $false
                    cards   = @(
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.farm_cam_1_battery"
                            name       = "Cam 1"
                            icon       = "mdi:battery"
                            icon_color = "{{ 'red' if states('sensor.farm_cam_1_battery')|int(100) < 20 else 'green' }}"
                        }
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.farm_cam_3_battery"
                            name       = "Cam 3"
                            icon       = "mdi:battery"
                            icon_color = "{{ 'red' if states('sensor.farm_cam_3_battery')|int(100) < 20 else 'green' }}"
                        }
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.farm_cam_5_battery"
                            name       = "Cam 5"
                            icon       = "mdi:battery"
                            icon_color = "{{ 'red' if states('sensor.farm_cam_5_battery')|int(100) < 20 else 'green' }}"
                        }
                    )
                }
            )
        }
    )
}

# Remove existing farm-cameras view if present, then add new one
$updatedViews = @($existingViews | Where-Object { $_.path -ne "farm-cameras" })
$updatedViews += $farmView

$dashConfig.views = $updatedViews

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashConfig
    url_path = "security-dashboard"
}

if ($saveResp.success) {
    Write-Success "Security dashboard updated with Farm Cameras tab!"
} else {
    Write-Fail "Save failed: $($saveResp.error.message)"
}

# ============================================================
# Done
# ============================================================

Disconnect-HAWS

Write-Step "Farm Camera Dashboard Update Complete"

Write-Host ""
Write-Host "  Security dashboard:" -ForegroundColor Green
Write-Host "    - New 'Farm Cameras' tab with fire/smoke, rain, animals, humans/vehicles" -ForegroundColor White
Write-Host "    - Per-camera AI analysis status cards" -ForegroundColor White
Write-Host "    - View at: http://$($Config.HA_IP):8123/security-dashboard/farm-cameras" -ForegroundColor White
Write-Host ""
