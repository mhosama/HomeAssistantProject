<#
.SYNOPSIS
    Create a Presence dashboard showing Life360 device trackers on a map with details.

.DESCRIPTION
    Discovers Life360 device_tracker entities and creates a dashboard with:
    - Family presence summary (who's home, who's away)
    - Map with all tracked members
    - Per-member detail cards (battery, speed, address, driving state)
    - Presence history graph (24h)

    Also adds a compact Presence card to the Overview dashboard.

    Run AFTER 16-Setup-Life360.ps1 and after Life360 has synced device trackers.

.EXAMPLE
    .\16a-Add-Life360Dashboard.ps1
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

$script:haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

function Invoke-HAREST {
    param([string]$Endpoint, [string]$Method = "GET", [string]$JsonBody)
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $params = @{ Uri = $uri; Method = $Method; Headers = $script:haHeaders; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($JsonBody) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($JsonBody) }
    try { return (Invoke-WebRequest @params).Content | ConvertFrom-Json } catch { Write-Fail "API call failed: $Endpoint - $($_.Exception.Message)"; return $null }
}

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
# Discover Life360 device trackers
# ============================================================

Write-Step "Discovering Life360 Device Trackers"

$allStates = Invoke-HAREST -Endpoint "/api/states"
$trackers = $allStates | Where-Object {
    $_.entity_id -like "device_tracker.life360_*" -and
    $_.attributes.source_type -eq "gps"
}

if ($trackers.Count -eq 0) {
    Write-Fail "No Life360 device trackers found!"
    Write-Info "Make sure:"
    Write-Info "  1. Life360 integration is configured (Settings > Devices & Services)"
    Write-Info "  2. Wait a few minutes for Life360 to sync"
    Write-Info "  3. Check Developer Tools > States > filter 'device_tracker.'"
    exit 1
}

Write-Success "Found $($trackers.Count) device tracker(s):"
foreach ($t in $trackers) {
    $name = $t.attributes.friendly_name
    Write-Info "  - $($t.entity_id) ($name) = $($t.state)"
}

$trackerEntityIds = $trackers | ForEach-Object { $_.entity_id }

# ============================================================
# Step 1: Create per-member Place template sensors
# ============================================================

Write-Step "Step 1: Creating Place Template Sensors"

$placeSensorIds = @()

foreach ($tracker in $trackers) {
    $eid = $tracker.entity_id
    $name = $tracker.attributes.friendly_name
    if (-not $name) { $name = $eid -replace "device_tracker\.", "" -replace "_", " " }
    # Use friendly name for sensor (strip "Life360 " prefix if present)
    $cleanName = $name -replace "^Life360\s+", ""
    $shortName = ($cleanName -split " ")[0].ToLower()
    $sensorName = "$shortName Place"
    $sensorEntityId = "sensor.${shortName}_place"
    # Avoid duplicates — if this sensor ID is already claimed, append a suffix
    if ($placeSensorIds -contains $sensorEntityId) {
        $sensorEntityId = "sensor.${shortName}_2_place"
        $sensorName = "$shortName 2 Place"
    }
    $placeSensorIds += $sensorEntityId

    # Check if sensor already exists
    $existing = $allStates | Where-Object { $_.entity_id -eq $sensorEntityId }
    if ($existing) {
        Write-Info "Sensor $sensorEntityId already exists - skipping"
        continue
    }

    Write-Info "Creating template sensor: $sensorEntityId (from $eid)"

    # Step 1: Start config flow for template
    $startBody = @{ handler = "template" } | ConvertTo-Json -Compress
    $flowStart = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $startBody

    if (-not $flowStart -or -not $flowStart.flow_id) {
        Write-Fail "Failed to start template config flow for $sensorEntityId"
        continue
    }

    # Step 2: Select sensor from menu (next_step_id, not template_type)
    $typeBody = @{ next_step_id = "sensor" } | ConvertTo-Json -Compress
    $flowType = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flowStart.flow_id)" -Method "POST" -JsonBody $typeBody

    if (-not $flowType -or -not $flowType.flow_id) {
        Write-Fail "Failed to select sensor type for $sensorEntityId"
        continue
    }

    # Step 3: Configure the sensor (field is "state", omit empty optional fields)
    $stateTemplate = "{{ state_attr('$eid', 'place') | default('In Transit', true) }}"
    $configBody = @{
        name  = $sensorName
        state = $stateTemplate
    } | ConvertTo-Json -Compress
    $flowConfig = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flowType.flow_id)" -Method "POST" -JsonBody $configBody

    if ($flowConfig -and $flowConfig.type -eq "create_entry") {
        Write-Success "Created template sensor: $sensorEntityId"
    } else {
        Write-Fail "Failed to create template sensor: $sensorEntityId ($($flowConfig | ConvertTo-Json -Compress))"
    }
}

# ============================================================
# Step 2: Create Presence dashboard
# ============================================================

Write-Step "Step 2: Creating Presence Dashboard"

Connect-HAWS

# Check if dashboard exists
$dashList = Invoke-WSCommand -Type "lovelace/dashboards/list"
$existingDash = $dashList.result | Where-Object { $_.url_path -eq "family-presence" }

if (-not $existingDash) {
    Write-Info "Creating presence dashboard..."
    $createResp = Invoke-WSCommand -Type "lovelace/dashboards/create" -Extra @{
        url_path        = "family-presence"
        title           = "Presence"
        icon            = "mdi:map-marker-account"
        require_admin   = $false
        show_in_sidebar = $true
    }
    if ($createResp.success) {
        Write-Success "Presence dashboard created"
    } else {
        Write-Fail "Failed to create dashboard: $($createResp.error.message)"
    }
} else {
    Write-Info "Presence dashboard already exists - updating config"
}

# Build cards
$cards = @()

# --- Header: Family Presence Summary ---
$cards += @{
    type       = "custom:mushroom-template-card"
    primary    = "Family Presence"
    icon       = "mdi:home-account"
    icon_color = "blue"
    secondary  = "{% set trackers = states.device_tracker | selectattr('attributes.source_type', 'eq', 'gps') | list %}{% set at_place = trackers | selectattr('attributes.place', 'defined') | rejectattr('attributes.place', 'eq', '') | rejectattr('attributes.place', 'eq', none) | list %}{{ at_place | length }} at a place / {{ trackers | length - at_place | length }} in transit"
}

# --- Map card with all trackers ---
$mapEntities = @()
foreach ($tid in $trackerEntityIds) {
    $mapEntities += @{ entity = $tid }
}

$cards += @{
    type             = "map"
    title            = "Family Locations"
    entities         = $mapEntities
    default_zoom     = 14
    hours_to_show    = 24
    aspect_ratio     = "16:9"
}

# --- Per-member detail cards ---
foreach ($tracker in $trackers) {
    $eid = $tracker.entity_id
    $name = $tracker.attributes.friendly_name
    if (-not $name) { $name = $eid -replace "device_tracker\.", "" -replace "_", " " }

    $cards += @{
        type  = "vertical-stack"
        title = $name
        cards = @(
            @{
                type       = "custom:mushroom-entity-card"
                entity     = $eid
                name       = $name
                icon       = "mdi:account"
                icon_color = "{{ 'green' if state_attr('$eid', 'place') not in ['', none] else ('blue' if is_state('$eid', 'driving') else 'orange') }}"
            }
            @{
                type    = "markdown"
                content = @"
{% set t = '$eid' %}
| | |
|---|---|
| **Location** | {{ state_attr(t, 'place') | default('In Transit') }} |
| **Address** | {{ state_attr(t, 'address') | default('Unknown') }} |
| **Battery** | {{ state_attr(t, 'battery') | default('?') }}%{% if state_attr(t, 'battery_charging') == true %} (charging){% endif %} |
| **Speed** | {{ state_attr(t, 'speed') | default(0) | round(1) }} km/h |
| **Driving** | {{ state_attr(t, 'driving') | default(false) }} |
| **WiFi** | {{ state_attr(t, 'wifi_on') | default('?') }} |
| **Last Seen** | {{ state_attr(t, 'last_seen') | default('Unknown') }} |
| **At Location Since** | {{ state_attr(t, 'at_loc_since') | default('Unknown') }} |
"@
            }
        )
    }
}

# --- Presence history graph (using place sensors for readable names) ---
$historyEntities = @()
foreach ($placeId in $placeSensorIds) {
    $historyEntities += @{ entity = $placeId }
}

$cards += @{
    type          = "history-graph"
    title         = "Presence History (24h)"
    entities      = $historyEntities
    hours_to_show = 24
}

# Build dashboard config
$dashboardConfig = @{
    views = @(
        @{
            title = "Presence"
            path  = "presence"
            icon  = "mdi:map-marker-account"
            cards = $cards
        }
    )
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashboardConfig
    url_path = "family-presence"
}

if ($saveResp.success) {
    Write-Success "Presence dashboard config saved!"
} else {
    Write-Fail "Save failed: $($saveResp.error.message)"
}

# ============================================================
# Step 3: Add Presence section to Overview dashboard
# ============================================================

Write-Step "Step 3: Adding Presence section to Overview dashboard"

$overviewConfig = Invoke-WSCommand -Type "lovelace/config"

if (-not $overviewConfig.success) {
    Write-Fail "Could not load Overview dashboard"
} else {
    $overviewDash = $overviewConfig.result
    $overviewViews = @($overviewDash.views)
    $overviewView = $overviewViews[0]
    $existingCards = @($overviewView.cards)

    # Check if presence card already exists
    $presenceCardIndex = -1
    for ($i = 0; $i -lt $existingCards.Count; $i++) {
        $json = $existingCards[$i] | ConvertTo-Json -Depth 10 -Compress
        if ($json -match "Family Presence" -or $json -match "map-marker-account") {
            $presenceCardIndex = $i
            break
        }
    }

    # Build compact presence card for Overview
    $trackerGrid = @()
    foreach ($tracker in $trackers) {
        $eid = $tracker.entity_id
        $name = $tracker.attributes.friendly_name
        if (-not $name) { $name = $eid -replace "device_tracker\.", "" -replace "_", " " }
        # Shorten name for grid display
        $shortName = ($name -split " ")[0]

        $trackerGrid += @{
            type       = "custom:mushroom-entity-card"
            entity     = $eid
            name       = $shortName
            icon       = "mdi:account"
            icon_color = "{{ 'green' if state_attr('$eid', 'place') not in ['', none] else ('blue' if is_state('$eid', 'driving') else 'orange') }}"
        }
    }

    $presenceOverviewCard = @{
        type  = "vertical-stack"
        cards = @(
            @{
                type       = "custom:mushroom-template-card"
                primary    = "Family Presence"
                icon       = "mdi:map-marker-account"
                icon_color = "blue"
                secondary  = "{% set trackers = states.device_tracker | selectattr('attributes.source_type', 'eq', 'gps') | list %}{% set at_place = trackers | selectattr('attributes.place', 'defined') | rejectattr('attributes.place', 'eq', '') | rejectattr('attributes.place', 'eq', none) | list %}{{ at_place | length }} at a place / {{ trackers | length - at_place | length }} in transit"
            }
            @{
                type    = "grid"
                columns = 2
                square  = $false
                cards   = $trackerGrid
            }
        )
    }

    if ($presenceCardIndex -ge 0) {
        Write-Info "Replacing existing Presence card at index $presenceCardIndex"
        $existingCards[$presenceCardIndex] = $presenceOverviewCard
        $newCards = $existingCards
    } else {
        # Insert after the Vision AI section (look for it, or append at end)
        Write-Info "Inserting new Presence card"
        $insertAfter = -1
        for ($i = 0; $i -lt $existingCards.Count; $i++) {
            $json = $existingCards[$i] | ConvertTo-Json -Depth 10 -Compress
            if ($json -match "Vision AI") {
                $insertAfter = $i
                break
            }
        }
        $newCards = @()
        for ($i = 0; $i -lt $existingCards.Count; $i++) {
            $newCards += $existingCards[$i]
            if ($i -eq $insertAfter) {
                $newCards += $presenceOverviewCard
            }
        }
        if ($insertAfter -eq -1) {
            # Append at end if Vision AI section not found
            $newCards += $presenceOverviewCard
        }
    }

    $overviewView.cards = $newCards
    $overviewViews[0] = $overviewView
    $overviewDash.views = $overviewViews

    $saveResp2 = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
        config = $overviewDash
    }

    if ($saveResp2.success) {
        Write-Success "Overview dashboard updated with Presence section!"
    } else {
        Write-Fail "Save failed: $($saveResp2.error.message)"
    }
}

Disconnect-HAWS

# ============================================================
# Done
# ============================================================

Write-Step "Life360 Dashboard Setup Complete"

Write-Host ""
Write-Host "  Place sensors:" -ForegroundColor Green
foreach ($placeId in $placeSensorIds) {
    Write-Host "    - $placeId" -ForegroundColor White
}
Write-Host ""
Write-Host "  Presence dashboard:" -ForegroundColor Green
Write-Host "    - Map with all $($trackers.Count) family member(s)" -ForegroundColor White
Write-Host "    - Per-member cards with battery, speed, address, driving state" -ForegroundColor White
Write-Host "    - 24h presence history graph (shows place names)" -ForegroundColor White
Write-Host "    - View at: http://$($Config.HA_IP):8123/presence" -ForegroundColor White
Write-Host ""
Write-Host "  Overview dashboard:" -ForegroundColor Green
Write-Host "    - Compact presence summary with who's home/away" -ForegroundColor White
Write-Host ""
Write-Host "  Members:" -ForegroundColor Green
foreach ($t in $trackers) {
    Write-Host "    - $($t.attributes.friendly_name): $($t.state)" -ForegroundColor White
}
Write-Host ""
