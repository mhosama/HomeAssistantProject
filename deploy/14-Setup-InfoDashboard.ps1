<#
.SYNOPSIS
    Create the Info dashboard with vision analysis statistics.

.DESCRIPTION
    Creates a new "Info" dashboard (info-dashboard) showing:
    - Vision analysis stats: today's total, per-camera daily counts, recent daily history

.EXAMPLE
    .\14-Setup-InfoDashboard.ps1
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
# Step 1: Create Info dashboard (or update if exists)
# ============================================================

Write-Step "Step 1: Create Info dashboard"

# Check if dashboard already exists
$dashList = Invoke-WSCommand -Type "lovelace/dashboards/list"
$existingDash = $dashList.result | Where-Object { $_.url_path -eq "info-dashboard" }

if (-not $existingDash) {
    Write-Info "Creating info-dashboard..."
    $createResp = Invoke-WSCommand -Type "lovelace/dashboards/create" -Extra @{
        url_path       = "info-dashboard"
        title          = "Info"
        icon           = "mdi:information-outline"
        require_admin  = $false
        show_in_sidebar = $true
    }
    if ($createResp.success) {
        Write-Success "Info dashboard created"
    } else {
        Write-Fail "Failed to create dashboard: $($createResp.error.message)"
        Disconnect-HAWS
        exit 1
    }
} else {
    Write-Info "Info dashboard already exists - will update config"
}

# ============================================================
# Step 2: Build dashboard config
# ============================================================

Write-Step "Step 2: Building dashboard config"

# Camera names matching 08a-Run-VisionAnalysis.ps1
$cameraNames = @(
    "Chickens", "Backyard", "BackDoor", "VeggieGarden",
    "DiningRoom", "Kitchen", "MainGate", "VisitorGate",
    "Lawn", "Pool", "Garage", "Lounge"
)

# Build Jinja2 template for per-camera daily counts
$perCamRows = ($cameraNames | ForEach-Object {
    "| $_ | {{ state_attr('sensor.vision_analysis_stats', '${_}_today') | default(0) }} |"
}) -join "`n"

$perCameraTemplate = @"
## Per-Camera Analysis Counts (Today)

| Camera | Analyses |
|--------|----------|
$perCamRows
"@

# Build Jinja2 template for recent daily history
$historyRows = ($cameraNames | ForEach-Object {
    "| $_ | {{ state_attr('sensor.vision_analysis_stats', '${_}_history') | default('no data') }} |"
}) -join "`n"

$historyTemplate = @"
## Recent Daily History

Per-camera daily totals (last 7 days, newest first):

| Camera | Recent Daily Counts |
|--------|---------------------|
$historyRows
"@

# Build Jinja2 template for active suppressions
$suppressionContent = @"
{% set sensor = 'sensor.vision_analysis_stats' -%}
{% set ns = namespace(rows=[]) -%}
{% for cam in [$( ($cameraNames | ForEach-Object { "'$_'" }) -join ", " )] -%}
  {%- set heavy = state_attr(sensor, cam ~ '_heavy_until') -%}
  {%- if heavy -%}
    {%- set ns.rows = ns.rows + [cam ~ ' | ' ~ (as_timestamp(heavy) | timestamp_custom('%H:%M:%S'))] -%}
  {%- endif -%}
{%- endfor -%}
{% if ns.rows | length > 0 -%}
| Camera | Suppressed Until |
|--------|-----------------|
{% for row in ns.rows -%}
| {{ row }} |
{% endfor -%}
{% else -%}
*No cameras currently suppressed.*
{% endif %}
"@

# Build Jinja2 template for motion events log
$motionEventsContent = @"
{% set events_json = state_attr('sensor.vision_analysis_stats', 'motion_events') -%}
{% if events_json and events_json != '[]' -%}
{% set events = events_json | from_json -%}
| Time | Camera | Event |
|------|--------|-------|
{% for e in events -%}
| {{ as_timestamp(e.time) | timestamp_custom('%H:%M:%S') }} | {{ e.camera }} | {{ e.event }} |
{% endfor -%}
{% else -%}
*No motion events in the last 24 hours.*
{% endif %}
"@

# Count suppressed cameras for header
$suppressedCountTemplate = @"
{% set sensor = 'sensor.vision_analysis_stats' -%}
{% set ns = namespace(count=0) -%}
{% for cam in [$( ($cameraNames | ForEach-Object { "'$_'" }) -join ", " )] -%}
  {%- if state_attr(sensor, cam ~ '_heavy_until') -%}
    {%- set ns.count = ns.count + 1 -%}
  {%- endif -%}
{%- endfor -%}
{% if ns.count > 0 -%}{{ ns.count }} camera(s) suppressed{% else -%}All cameras active{% endif %}
"@

$streetDetectionTemplate = @"
## Detection Counts (Today)

| Metric | Value |
|--------|-------|
| Total Detections | {{ states('sensor.street_cam_detections_today') }} |
| People | {{ states('sensor.street_cam_people_today') }} |
| Vehicles | {{ states('sensor.street_cam_vehicles_today') }} |
| Last Detection | {{ states('sensor.street_cam_last_detection') }} |
| Last Object | {{ states('sensor.street_cam_last_object') }} |
| Status | {{ states('sensor.street_cam_status') }} |
"@

$plateOcrTemplate = @"
## Plate OCR Stats (Today)

| Metric | Value |
|--------|-------|
| Gemini Calls | {{ state_attr('sensor.street_cam_plate_ocr_stats', 'gemini_calls_today') | default(0) }} |
| Tesseract Fallback | {{ state_attr('sensor.street_cam_plate_ocr_stats', 'tesseract_calls_today') | default(0) }} |
| Plates Detected | {{ state_attr('sensor.street_cam_plate_ocr_stats', 'plates_detected_today') | default(0) }} |
| Known Plates Matched | {{ state_attr('sensor.street_cam_plate_ocr_stats', 'known_plates_today') | default(0) }} |
| Last Plate | {{ states('sensor.street_cam_last_plate') }} ({{ state_attr('sensor.street_cam_last_plate', 'owner') | default('unknown') }}) |
"@

$hourlyDetectionTemplate = @"
## Hourly Detections

{% set hourly = state_attr('sensor.street_cam_detections_today', 'hourly') -%}
{% if hourly -%}
| Hour | Count |
|------|-------|
{% for h in range(24) -%}
{% set hkey = '%02d' % h -%}
{% set count = hourly.get(hkey, 0) if hourly is mapping else 0 -%}
{% if count > 0 -%}
| {{ hkey }}:00 | {{ count }} |
{% endif -%}
{% endfor -%}
{% else -%}
*No hourly data available.*
{% endif %}
"@

$dashboardConfig = @{
    views = @(
        @{
            title = "Vision Analysis Stats"
            path  = "vision-stats"
            icon  = "mdi:chart-bar"
            cards = @(
                # Today's total header
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type       = "custom:mushroom-template-card"
                            primary    = "Vision Analysis Statistics"
                            icon       = "mdi:chart-bar"
                            icon_color = "purple"
                            secondary  = "{{ states('sensor.vision_analysis_stats') }} total analyses today"
                        }
                        @{
                            type   = "entity"
                            entity = "sensor.vision_analysis_stats"
                            name   = "Total Analyses Today"
                        }
                    )
                }
                # Per-camera daily counts
                @{
                    type    = "markdown"
                    title   = "Today's Counts"
                    content = $perCameraTemplate
                }
                # Recent history
                @{
                    type    = "markdown"
                    title   = "Daily History"
                    content = $historyTemplate
                }
            )
        }
        @{
            title = "Motion Activity"
            path  = "motion-activity"
            icon  = "mdi:motion-sensor"
            cards = @(
                @{
                    type       = "custom:mushroom-template-card"
                    primary    = "Motion Activity"
                    icon       = "mdi:motion-sensor"
                    icon_color = "orange"
                    secondary  = $suppressedCountTemplate
                }
                @{
                    type    = "markdown"
                    title   = "Active Suppressions"
                    content = $suppressionContent
                }
                @{
                    type    = "markdown"
                    title   = "Recent Motion Events (24h)"
                    content = $motionEventsContent
                }
            )
        }
        @{
            title = "Street Camera"
            path  = "street-camera"
            icon  = "mdi:cctv"
            cards = @(
                @{
                    type       = "custom:mushroom-template-card"
                    primary    = "Street Camera Stats"
                    icon       = "mdi:cctv"
                    icon_color = "blue"
                    secondary  = "{{ states('sensor.street_cam_detections_today') }} detections today"
                    entity     = "sensor.street_cam_detections_today"
                }
                @{
                    type    = "markdown"
                    title   = "Detection Counts"
                    content = $streetDetectionTemplate
                }
                @{
                    type    = "markdown"
                    title   = "Plate OCR Stats"
                    content = $plateOcrTemplate
                }
                @{
                    type    = "markdown"
                    title   = "Hourly Detections"
                    content = $hourlyDetectionTemplate
                }
            )
        }
    )
}

# ============================================================
# Step 3: Save dashboard config
# ============================================================

Write-Step "Step 3: Saving dashboard config"

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashboardConfig
    url_path = "info-dashboard"
}

if ($saveResp.success) {
    Write-Success "Info dashboard config saved!"
} else {
    Write-Fail "Save failed: $($saveResp.error.message)"
}

# ============================================================
# Done
# ============================================================

Disconnect-HAWS

Write-Step "Info Dashboard Setup Complete"

Write-Host ""
Write-Host "  Info dashboard:" -ForegroundColor Green
Write-Host "    - Vision Analysis Stats: today's total, per-camera counts, daily history" -ForegroundColor White
Write-Host "    - Motion Activity: event log, active suppressions" -ForegroundColor White
Write-Host "    - Street Camera: detection counts, plate OCR stats, hourly breakdown" -ForegroundColor White
Write-Host "    - View at: http://$($Config.HA_IP):8123/info-dashboard" -ForegroundColor White
Write-Host ""
