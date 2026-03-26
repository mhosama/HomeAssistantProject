<#
.SYNOPSIS
    Add a Find My tab to the Presence dashboard showing Google Find My device trackers.

.DESCRIPTION
    Discovers GoogleFindMy device_tracker entities and:
    - Adds a "Find My" tab to the existing Presence (family-presence) dashboard
    - Map with all tracked tags
    - Per-device detail cards (location, battery, last updated, play sound button)
    - Adds a compact Find My section to the Overview dashboard

    Safe to re-run (reads existing config, filters out Find My tab, re-appends).

    Run AFTER 20-Setup-GoogleFindMy.ps1 and after devices have synced.

.EXAMPLE
    .\20a-Add-FindMyDashboard.ps1
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
# Discover GoogleFindMy device trackers
# ============================================================

Write-Step "Discovering Google Find My Device Trackers"

# Known Google Find My tracker entity IDs (discovered from integration)
$findMyTrackerIds = @(
    "device_tracker.galaxy_s24_ultra",
    "device_tracker.kia_sorento",
    "device_tracker.honey_trap",
    "device_tracker.ford_everest",
    "device_tracker.elle_tag",
    "device_tracker.lana_tag"
)

$allStates = Invoke-HAREST -Endpoint "/api/states"
$trackers = $allStates | Where-Object {
    $findMyTrackerIds -contains $_.entity_id
}

if ($trackers.Count -eq 0) {
    Write-Fail "No Google Find My device trackers found!"
    Write-Info "Make sure:"
    Write-Info "  1. GoogleFindMy integration is configured (Settings > Devices & Services)"
    Write-Info "  2. HA has been fully restarted after setup"
    Write-Info "  3. Check Developer Tools > States > filter entity IDs above"
    exit 1
}

Write-Success "Found $($trackers.Count) device tracker(s):"
foreach ($t in $trackers) {
    $name = $t.attributes.friendly_name
    $battery = $t.attributes.battery_level
    Write-Info "  - $($t.entity_id) ($name) = $($t.state)$(if ($battery) { " [Battery: $battery%]" })"
}

$trackerEntityIds = $trackers | ForEach-Object { $_.entity_id }

# Also discover Play Sound buttons
$playButtons = $allStates | Where-Object {
    $_.entity_id -like "button.*_play_sound" -and
    $_.attributes.friendly_name -like "*Play sound*"
}
if ($playButtons.Count -gt 0) {
    Write-Success "Found $($playButtons.Count) Play Sound button(s)"
}

# ============================================================
# Step 1: Add Find My tab to Presence dashboard
# ============================================================

Write-Step "Step 1: Adding Find My Tab to Presence Dashboard"

Connect-HAWS

# Check if Presence dashboard exists
$dashList = Invoke-WSCommand -Type "lovelace/dashboards/list"
$presenceDash = $dashList.result | Where-Object { $_.url_path -eq "family-presence" }

if (-not $presenceDash) {
    Write-Fail "Presence dashboard (family-presence) not found!"
    Write-Info "Run deploy/16a-Add-Life360Dashboard.ps1 first to create it."
    Disconnect-HAWS
    exit 1
}

# Read existing config
$existingConfig = Invoke-WSCommand -Type "lovelace/config" -Extra @{ url_path = "family-presence" }
if (-not $existingConfig.success) {
    Write-Fail "Could not read Presence dashboard config"
    Disconnect-HAWS
    exit 1
}

$dashConfig = $existingConfig.result
$existingViews = @($dashConfig.views)

# Filter out existing Find My tab (safe to re-run)
$otherViews = @($existingViews | Where-Object { $_.path -ne "find-my" })

# Build Find My tab cards
$findMyCards = @()

# --- Map card with all trackers ---
$mapEntities = @()
foreach ($tid in $trackerEntityIds) {
    $mapEntities += @{ entity = $tid }
}

$findMyCards += @{
    type          = "map"
    title         = "Find My Devices"
    entities      = $mapEntities
    default_zoom  = 14
    hours_to_show = 24
    aspect_ratio  = "16:9"
}

# --- Per-device detail cards ---
foreach ($tracker in $trackers) {
    $eid = $tracker.entity_id
    $name = $tracker.attributes.friendly_name
    if (-not $name) { $name = $eid -replace "device_tracker\.", "" -replace "_", " " }

    $detailCards = @(
        @{
            type       = "custom:mushroom-entity-card"
            entity     = $eid
            name       = $name
            icon       = "mdi:tag"
            icon_color = "{{ 'green' if is_state('$eid', 'home') else 'orange' }}"
        }
        @{
            type    = "markdown"
            content = @"
{% set t = '$eid' %}
| | |
|---|---|
| **Zone** | {{ states(t) | replace('_', ' ') | title }} |
| **Battery** | {{ state_attr(t, 'battery_level') | default('?') }}% |
| **Latitude** | {{ state_attr(t, 'latitude') | default('?') }} |
| **Longitude** | {{ state_attr(t, 'longitude') | default('?') }} |
| **Accuracy** | {{ state_attr(t, 'gps_accuracy') | default('?') }}m |
| **Last Updated** | {{ as_timestamp(states[t].last_updated) | timestamp_custom('%H:%M %d/%m', true) }} |
"@
        }
    )

    # Add Play Sound button if available for this device
    $deviceSlug = ($eid -replace "device_tracker\.", "")
    $matchingButton = $playButtons | Where-Object { $_.entity_id -like "*${deviceSlug}*" }
    if ($matchingButton) {
        $detailCards += @{
            type        = "button"
            entity      = $matchingButton[0].entity_id
            name        = "Play Sound"
            icon        = "mdi:volume-high"
            tap_action  = @{
                action = "call-service"
                service = "button.press"
                target = @{ entity_id = $matchingButton[0].entity_id }
            }
        }
    }

    $findMyCards += @{
        type  = "vertical-stack"
        title = $name
        cards = $detailCards
    }
}

# Build the Find My view
$findMyView = @{
    title = "Find My"
    path  = "find-my"
    icon  = "mdi:crosshairs-gps"
    cards = $findMyCards
}

# Append Find My tab
$allViews = $otherViews + @($findMyView)
$dashConfig.views = $allViews

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashConfig
    url_path = "family-presence"
}

if ($saveResp.success) {
    Write-Success "Find My tab added to Presence dashboard!"
} else {
    Write-Fail "Save failed: $($saveResp.error.message)"
}

# ============================================================
# Step 2: Add Find My section to Overview dashboard
# ============================================================

Write-Step "Step 2: Adding Find My section to Overview dashboard"

$overviewConfig = Invoke-WSCommand -Type "lovelace/config"

if (-not $overviewConfig.success) {
    Write-Fail "Could not load Overview dashboard"
} else {
    $overviewDash = $overviewConfig.result
    $overviewViews = @($overviewDash.views)
    $overviewView = $overviewViews[0]
    $existingCards = @($overviewView.cards)

    # Check if Find My card already exists
    $findMyCardIndex = -1
    for ($i = 0; $i -lt $existingCards.Count; $i++) {
        $json = $existingCards[$i] | ConvertTo-Json -Depth 10 -Compress
        if ($json -match "Find My Devices" -and $json -match "crosshairs-gps") {
            $findMyCardIndex = $i
            break
        }
    }

    # Build compact Find My card for Overview
    $tagGrid = @()
    foreach ($tracker in $trackers) {
        $eid = $tracker.entity_id
        $name = $tracker.attributes.friendly_name
        if (-not $name) { $name = $eid -replace "device_tracker\.", "" -replace "_", " " }
        $shortName = ($name -split " ")[0]

        $tagGrid += @{
            type       = "custom:mushroom-entity-card"
            entity     = $eid
            name       = $shortName
            icon       = "mdi:tag"
            icon_color = "{{ 'green' if is_state('$eid', 'home') else 'orange' }}"
            secondary_info = "state"
        }
    }

    $findMyOverviewCard = @{
        type  = "vertical-stack"
        cards = @(
            @{
                type       = "custom:mushroom-template-card"
                primary    = "Find My Devices"
                icon       = "mdi:crosshairs-gps"
                icon_color = "teal"
                secondary  = "{% set ids = ['galaxy_s24_ultra','kia_sorento','honey_trap','ford_everest','elle_tag','lana_tag'] %}{% set trackers = states.device_tracker | selectattr('entity_id', 'in', ids | map('regex_replace', '^', 'device_tracker.') | list) | list %}{% set home = trackers | selectattr('state', 'eq', 'home') | list %}{{ home | length }} home / {{ trackers | length - home | length }} away"
            }
            @{
                type    = "grid"
                columns = 2
                square  = $false
                cards   = $tagGrid
            }
        )
    }

    if ($findMyCardIndex -ge 0) {
        Write-Info "Replacing existing Find My card at index $findMyCardIndex"
        $existingCards[$findMyCardIndex] = $findMyOverviewCard
        $newCards = $existingCards
    } else {
        # Insert after Family Presence section (or append at end)
        Write-Info "Inserting new Find My card"
        $insertAfter = -1
        for ($i = 0; $i -lt $existingCards.Count; $i++) {
            $json = $existingCards[$i] | ConvertTo-Json -Depth 10 -Compress
            if ($json -match "Family Presence" -or $json -match "map-marker-account") {
                $insertAfter = $i
                break
            }
        }
        $newCards = @()
        for ($i = 0; $i -lt $existingCards.Count; $i++) {
            $newCards += $existingCards[$i]
            if ($i -eq $insertAfter) {
                $newCards += $findMyOverviewCard
            }
        }
        if ($insertAfter -eq -1) {
            $newCards += $findMyOverviewCard
        }
    }

    $overviewView.cards = $newCards
    $overviewViews[0] = $overviewView
    $overviewDash.views = $overviewViews

    $saveResp2 = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
        config = $overviewDash
    }

    if ($saveResp2.success) {
        Write-Success "Overview dashboard updated with Find My section!"
    } else {
        Write-Fail "Save failed: $($saveResp2.error.message)"
    }
}

Disconnect-HAWS

# ============================================================
# Done
# ============================================================

Write-Step "Find My Dashboard Setup Complete"

Write-Host ""
Write-Host "  Presence dashboard - Find My tab:" -ForegroundColor Green
Write-Host "    - Map with all $($trackers.Count) tracked device(s)" -ForegroundColor White
Write-Host "    - Per-device cards with zone, battery, accuracy, last updated" -ForegroundColor White
if ($playButtons.Count -gt 0) {
    Write-Host "    - Play Sound buttons for $($playButtons.Count) device(s)" -ForegroundColor White
}
Write-Host "    - View at: http://$($Config.HA_IP):8123/family-presence/find-my" -ForegroundColor White
Write-Host ""
Write-Host "  Overview dashboard:" -ForegroundColor Green
Write-Host "    - Compact Find My section with home/away summary" -ForegroundColor White
Write-Host ""
Write-Host "  Devices:" -ForegroundColor Green
foreach ($t in $trackers) {
    Write-Host "    - $($t.attributes.friendly_name): $($t.state)" -ForegroundColor White
}
Write-Host ""
