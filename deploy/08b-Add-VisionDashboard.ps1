<#
.SYNOPSIS
    Add LLM vision analysis sensors to the Overview and Security dashboards.

.DESCRIPTION
    Adds vision-analysis sensor cards to existing dashboards:
    - Overview: Gate status + car counts in Security section, chicken count
    - Security: New "Vision AI" view with all vision sensors and camera analysis status

.EXAMPLE
    .\08b-Add-VisionDashboard.ps1
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
# Step 1: Add Vision AI view to Security dashboard
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

# Build Vision AI view
$visionView = @{
    title = "Vision AI"
    path  = "vision-ai"
    icon  = "mdi:eye"
    cards = @(
        # Gate Status section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type     = "custom:mushroom-template-card"
                    primary  = "Gate Status"
                    icon     = "mdi:gate"
                    icon_color = "blue"
                    secondary = "AI-powered gate monitoring"
                }
                @{
                    type    = "grid"
                    columns = 2
                    square  = $false
                    cards   = @(
                        @{
                            type      = "custom:mushroom-entity-card"
                            entity    = "sensor.main_gate_status"
                            name      = "Main Gate"
                            icon      = "mdi:gate"
                            icon_color = "{{ 'red' if is_state('sensor.main_gate_status', 'open') else 'green' }}"
                        }
                        @{
                            type      = "custom:mushroom-entity-card"
                            entity    = "sensor.visitor_gate_status"
                            name      = "Visitor Gate"
                            icon      = "mdi:gate"
                            icon_color = "{{ 'red' if is_state('sensor.visitor_gate_status', 'open') else 'green' }}"
                        }
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.main_gate_car_count"
                            name   = "Main Gate Cars"
                            icon   = "mdi:car"
                        }
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.visitor_gate_car_count"
                            name   = "Visitor Gate Cars"
                            icon   = "mdi:car"
                        }
                    )
                }
            )
        }
        # Chickens section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type     = "custom:mushroom-template-card"
                    primary  = "Chickens"
                    icon     = "mdi:chicken"
                    icon_color = "amber"
                    secondary = "AI chicken count from coop camera"
                }
                @{
                    type    = "grid"
                    columns = 2
                    square  = $false
                    cards   = @(
                        @{
                            type      = "gauge"
                            entity    = "sensor.chicken_count"
                            name      = "Chickens in Coop"
                            min       = 0
                            max       = 15
                            severity  = @{
                                green  = 3
                                yellow = 1
                                red    = 0
                            }
                        }
                        @{
                            type      = "gauge"
                            entity    = "sensor.egg_count"
                            name      = "Eggs Visible"
                            min       = 0
                            max       = 12
                            severity  = @{
                                green  = 1
                                yellow = 0
                                red    = 0
                            }
                        }
                    )
                }
            )
        }
        # Kitchen Food section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type     = "custom:mushroom-template-card"
                    primary  = "Kitchen Food Tracker"
                    icon     = "mdi:food"
                    icon_color = "orange"
                    secondary = "AI-detected meals from kitchen camera"
                }
                @{
                    type     = "entities"
                    entities = @(
                        @{ entity = "sensor.breakfast_food"; name = "Breakfast"; icon = "mdi:food-croissant" }
                        @{ entity = "sensor.lunch_food";     name = "Lunch";     icon = "mdi:food" }
                        @{ entity = "sensor.dinner_food";    name = "Dinner";    icon = "mdi:food-turkey" }
                    )
                }
            )
        }
        # Pool Status section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type     = "custom:mushroom-template-card"
                    primary  = "Pool Status"
                    icon     = "mdi:pool"
                    icon_color = "teal"
                    secondary = "AI-detected pool activity from camera"
                }
                @{
                    type    = "grid"
                    columns = 2
                    square  = $false
                    cards   = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.pool_adult_count"
                            name   = "Adults"
                            icon   = "mdi:account"
                        }
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.pool_child_count"
                            name   = "Children"
                            icon   = "mdi:account-child"
                        }
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.pool_cover_status"
                            name       = "Pool Cover"
                            icon       = "mdi:shield-sun"
                            icon_color = "{{ 'red' if is_state('sensor.pool_cover_status', 'open') else ('green' if is_state('sensor.pool_cover_status', 'closed') else 'orange') }}"
                        }
                    )
                }
            )
        }
        # Garage Doors section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type     = "custom:mushroom-template-card"
                    primary  = "Garage Doors"
                    icon     = "mdi:garage"
                    icon_color = "grey"
                    secondary = "AI-detected garage door status"
                }
                @{
                    type    = "grid"
                    columns = 2
                    square  = $false
                    cards   = @(
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.left_garage_door"
                            name       = "Left Door"
                            icon       = "{{ 'mdi:garage-open' if is_state('sensor.left_garage_door', 'open') else 'mdi:garage' }}"
                            icon_color = "{{ 'red' if is_state('sensor.left_garage_door', 'open') else 'green' }}"
                        }
                        @{
                            type       = "custom:mushroom-entity-card"
                            entity     = "sensor.right_garage_door"
                            name       = "Right Door"
                            icon       = "{{ 'mdi:garage-open' if is_state('sensor.right_garage_door', 'open') else 'mdi:garage' }}"
                            icon_color = "{{ 'red' if is_state('sensor.right_garage_door', 'open') else 'green' }}"
                        }
                    )
                }
            )
        }
        # Recent Detections section
        @{
            type  = "vertical-stack"
            cards = @(
                @{
                    type       = "custom:mushroom-template-card"
                    primary    = "Recent Detections"
                    icon       = "mdi:history"
                    icon_color = "purple"
                    secondary  = "{{ states('sensor.vision_last_detections') }} buffered"
                }
                @{
                    type    = "markdown"
                    content = @"
{% set s = 'sensor.vision_last_detections' %}
{% set total = states(s) | int(0) %}
{% if total > 0 %}
{% set cams = ['Chickens','Backyard','BackDoor','VeggieGarden','DiningRoom','Kitchen','MainGate','VisitorGate','Lawn','Pool','Garage','Lounge'] %}
{% for cam in cams %}
{% set cnt = state_attr(s, cam ~ '_count') | int(0) %}
{% if cnt > 0 %}
**{{ cam }}** — {{ state_attr(s, cam ~ '_last_summary') }}
_{{ as_timestamp(state_attr(s, cam ~ '_last')) | timestamp_custom('%H:%M %d %b') }}_
{% set img = state_attr(s, cam ~ '_image') %}
{% if img %}<a href="{{ img }}?t={{ now().timestamp() | int }}" target="_blank"><img src="{{ img }}?t={{ now().timestamp() | int }}" style="width:100%;max-width:480px;border-radius:8px"></a>{% endif %}
---
{% endif %}
{% endfor %}
{% else %}
*No detections recorded yet*
{% endif %}
"@
                }
            )
        }
    )
}

# Remove existing vision-ai view if present, then add new one
$updatedViews = @($existingViews | Where-Object { $_.path -ne "vision-ai" })
$updatedViews += $visionView

$dashConfig.views = $updatedViews

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashConfig
    url_path = "security-dashboard"
}

if ($saveResp.success) {
    Write-Success "Security dashboard updated with Vision AI tab!"
} else {
    Write-Fail "Save failed: $($saveResp.error.message)"
}

# ============================================================
# Step 2: Update Overview dashboard
# ============================================================

Write-Step "Step 2: Update Overview dashboard"

$overviewConfig = Invoke-WSCommand -Type "lovelace/config"

if (-not $overviewConfig.success) {
    Write-Fail "Could not load Overview dashboard: $($overviewConfig.error.message)"
    Disconnect-HAWS
    exit 1
}

$overviewDash = $overviewConfig.result
$overviewViews = @($overviewDash.views)
Write-Info "Current overview has $($overviewViews.Count) view(s)"

# Find the overview view (first view)
$overviewView = $overviewViews[0]
$existingCards = @($overviewView.cards)
Write-Info "Overview has $($existingCards.Count) card(s)"

# Check if we already added vision cards (look for chicken_count entity)
$visionCardIndex = -1
for ($i = 0; $i -lt $existingCards.Count; $i++) {
    $json = $existingCards[$i] | ConvertTo-Json -Depth 10 -Compress
    if ($json -match "chicken_count") {
        $visionCardIndex = $i
        break
    }
}

# Always build the latest Vision AI card
$visionOverviewCard = @{
    type  = "vertical-stack"
    cards = @(
        @{
            type       = "custom:mushroom-template-card"
            primary    = "Vision AI"
            icon       = "mdi:eye"
            icon_color = "purple"
            secondary  = "{{ states('sensor.main_gate_status') | title }} / {{ states('sensor.visitor_gate_status') | title }} gates | {{ states('sensor.chicken_count') }} chickens | {{ states('sensor.egg_count') }} eggs | {{ states('sensor.vision_last_detections') }} detections"
        }
        @{
            type    = "grid"
            columns = 2
            square  = $false
            cards   = @(
                @{
                    type      = "custom:mushroom-entity-card"
                    entity    = "sensor.main_gate_status"
                    name      = "Main Gate"
                    icon      = "mdi:gate"
                    icon_color = "{{ 'red' if is_state('sensor.main_gate_status', 'open') else 'green' }}"
                }
                @{
                    type      = "custom:mushroom-entity-card"
                    entity    = "sensor.visitor_gate_status"
                    name      = "Visitor Gate"
                    icon      = "mdi:gate"
                    icon_color = "{{ 'red' if is_state('sensor.visitor_gate_status', 'open') else 'green' }}"
                }
                @{
                    type   = "custom:mushroom-entity-card"
                    entity = "sensor.chicken_count"
                    name   = "Chickens"
                    icon   = "mdi:chicken"
                }
                @{
                    type   = "custom:mushroom-entity-card"
                    entity = "sensor.main_gate_car_count"
                    name   = "Cars (Main)"
                    icon   = "mdi:car"
                }
                @{
                    type       = "custom:mushroom-entity-card"
                    entity     = "sensor.pool_cover_status"
                    name       = "Pool Cover"
                    icon       = "mdi:shield-sun"
                    icon_color = "{{ 'red' if is_state('sensor.pool_cover_status', 'open') else ('green' if is_state('sensor.pool_cover_status', 'closed') else 'orange') }}"
                }
                @{
                    type       = "custom:mushroom-entity-card"
                    entity     = "sensor.left_garage_door"
                    name       = "Garage (L)"
                    icon       = "{{ 'mdi:garage-open' if is_state('sensor.left_garage_door', 'open') else 'mdi:garage' }}"
                    icon_color = "{{ 'red' if is_state('sensor.left_garage_door', 'open') else 'green' }}"
                }
            )
        }
    )
}

if ($visionCardIndex -ge 0) {
    # Replace existing Vision AI card in place
    Write-Info "Replacing existing Vision AI card at index $visionCardIndex"
    $existingCards[$visionCardIndex] = $visionOverviewCard
    $newCards = $existingCards
} else {
    # Insert after the Security section (index 1, which is the 2nd card)
    Write-Info "Inserting new Vision AI card"
    $newCards = @()
    for ($i = 0; $i -lt $existingCards.Count; $i++) {
        $newCards += $existingCards[$i]
        if ($i -eq 1) {
            $newCards += $visionOverviewCard
        }
    }
}

$overviewView.cards = $newCards
$overviewViews[0] = $overviewView
$overviewDash.views = $overviewViews

$saveResp2 = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config = $overviewDash
}

if ($saveResp2.success) {
    Write-Success "Overview dashboard updated with Vision AI section!"
} else {
    Write-Fail "Save failed: $($saveResp2.error.message)"
}

# ============================================================
# Done
# ============================================================

Disconnect-HAWS

Write-Step "Dashboard Update Complete"

Write-Host ""
Write-Host "  Security dashboard:" -ForegroundColor Green
Write-Host "    - New 'Vision AI' tab with gate status, chicken count, food tracker, pool status, garage doors" -ForegroundColor White
Write-Host "    - View at: http://$($Config.HA_IP):8123/security-dashboard/vision-ai" -ForegroundColor White
Write-Host ""
Write-Host "  Overview dashboard:" -ForegroundColor Green
Write-Host "    - New 'Vision AI' section with gate status, chickens, car count, pool cover, garage door" -ForegroundColor White
Write-Host "    - View at: http://$($Config.HA_IP):8123/lovelace/overview" -ForegroundColor White
Write-Host ""
