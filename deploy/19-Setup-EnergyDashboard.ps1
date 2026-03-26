<#
.SYNOPSIS
    Create the Energy Schedule dashboard with schedule controls and weather context.

.DESCRIPTION
    Creates a new "Energy Schedule" sidebar dashboard (energy-schedule) with two views:
    1. Schedule: Solar vs load chart, per-device hour toggle grids, summary, event log, controls
    2. Weather & Solar: Weather briefing, cloud cover chart, solar forecast chart, key metrics

    Safe to re-run — recreates dashboard config each time.

.EXAMPLE
    .\19-Setup-EnergyDashboard.ps1
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
        try { $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait() } catch {}
    }
}

# ============================================================
# Connect
# ============================================================

Write-Step "Connecting to Home Assistant"
Connect-HAWS

# ============================================================
# Step 1: Create Energy Schedule dashboard (or update if exists)
# ============================================================

Write-Step "Step 1: Create Energy Schedule dashboard"

$dashList = Invoke-WSCommand -Type "lovelace/dashboards/list"
$existingDash = $dashList.result | Where-Object { $_.url_path -eq "energy-schedule" }

if (-not $existingDash) {
    Write-Info "Creating energy-schedule dashboard..."
    $createResp = Invoke-WSCommand -Type "lovelace/dashboards/create" -Extra @{
        url_path        = "energy-schedule"
        title           = "Energy Schedule"
        icon            = "mdi:lightning-bolt-circle"
        require_admin   = $false
        show_in_sidebar = $true
    }
    if ($createResp.success) {
        Write-Success "Energy Schedule dashboard created"
    } else {
        Write-Fail "Failed to create dashboard: $($createResp.error.message)"
        Disconnect-HAWS
        exit 1
    }
} else {
    Write-Info "Energy Schedule dashboard already exists - will update config"
}

# ============================================================
# Step 2: Build View 1 - Schedule
# ============================================================

Write-Step "Step 2: Building Schedule view"

# --- Card 1: Header ---
$headerCard = @{
    type       = "custom:mushroom-template-card"
    primary    = "Energy Schedule - {{ now().strftime('%A %d %B') }}"
    icon       = "mdi:lightning-bolt-circle"
    icon_color = "{% if state_attr('sensor.energy_schedule', 'confidence') == 'high' %}green{% elif state_attr('sensor.energy_schedule', 'confidence') == 'medium' %}amber{% else %}red{% endif %}"
    secondary  = "{{ state_attr('sensor.energy_schedule', 'confidence') | default('pending') | title }} confidence | Updated {{ state_attr('sensor.energy_schedule', 'last_updated') | as_timestamp | timestamp_custom('%H:%M') if state_attr('sensor.energy_schedule', 'last_updated') else 'never' }}"
}

# --- Card 2: Solar vs Load chart (manually pre-stacked areas) ---
# data_generator series don't support apexcharts-card native stacking.
# Workaround: each series returns CUMULATIVE values, drawn back-to-front.
# Tallest series first (behind), shortest last (foreground).
# Legend values hidden to avoid showing misleading cumulative numbers.
$dgSolar = "const plan = entity.attributes.hourly_plan || []; return plan.map(s => [new Date(new Date().toDateString() + ' ' + s.hour + ':00').getTime(), s.solar_kw]);"

# Layer 4 (behind): base + main + flat + pool = total consumption
$dgTotal = "const plan = entity.attributes.hourly_plan || []; return plan.map(s => { const t = new Date(new Date().toDateString() + ' ' + s.hour + ':00').getTime(); const d = s.devices || []; const v = 1.5 + (d.includes('main_geyser') ? 3.9 : 0) + (d.includes('flat_geyser') ? 2.2 : 0) + (d.includes('pool_pump') ? 3.0 : 0); return [t, v]; });"
# Layer 3: base + main + flat
$dgNoPool = "const plan = entity.attributes.hourly_plan || []; return plan.map(s => { const t = new Date(new Date().toDateString() + ' ' + s.hour + ':00').getTime(); const d = s.devices || []; const v = 1.5 + (d.includes('main_geyser') ? 3.9 : 0) + (d.includes('flat_geyser') ? 2.2 : 0); return [t, v]; });"
# Layer 2: base + main
$dgNoFlat = "const plan = entity.attributes.hourly_plan || []; return plan.map(s => { const t = new Date(new Date().toDateString() + ' ' + s.hour + ':00').getTime(); const d = s.devices || []; const v = 1.5 + (d.includes('main_geyser') ? 3.9 : 0); return [t, v]; });"
# Layer 1 (foreground): base only
$dgBaseLoad = "const plan = entity.attributes.hourly_plan || []; return plan.map(s => [new Date(new Date().toDateString() + ' ' + s.hour + ':00').getTime(), 1.5]);"

$solarLoadChart = @{
    type = "custom:apexcharts-card"
    header = @{ title = "Energy Budget"; show = $true }
    graph_span = "1d"
    span = @{ start = "day" }
    yaxis = @(
        @{ id = "kw"; min = 0; max = 20; apex_config = @{ tickAmount = 4 } }
        @{ id = "kw_solar"; min = 0; max = 20; show = $false }
    )
    series = @(
        @{
            entity = "sensor.energy_schedule"
            name   = "Pool Pump (3.0 kW)"
            color  = "#4488FF"
            type   = "area"
            curve  = "stepline"
            yaxis_id = "kw"
            data_generator = $dgTotal
            opacity = 1
            stroke_width = 0
            show = @{ legend_value = $false }
        }
        @{
            entity = "sensor.energy_schedule"
            name   = "Flat Geyser (2.2 kW)"
            color  = "#FF8C00"
            type   = "area"
            curve  = "stepline"
            yaxis_id = "kw"
            data_generator = $dgNoPool
            opacity = 1
            stroke_width = 0
            show = @{ legend_value = $false }
        }
        @{
            entity = "sensor.energy_schedule"
            name   = "Main Geyser (3.9 kW)"
            color  = "#FF4444"
            type   = "area"
            curve  = "stepline"
            yaxis_id = "kw"
            data_generator = $dgNoFlat
            opacity = 1
            stroke_width = 0
            show = @{ legend_value = $false }
        }
        @{
            entity = "sensor.energy_schedule"
            name   = "Base Load (1.5 kW)"
            color  = "#888888"
            type   = "area"
            curve  = "stepline"
            yaxis_id = "kw"
            data_generator = $dgBaseLoad
            opacity = 1
            stroke_width = 0
            show = @{ legend_value = $false }
        }
        @{
            entity = "sensor.energy_schedule"
            name   = "Solar Available"
            color  = "#FFD700"
            type   = "line"
            curve  = "smooth"
            yaxis_id = "kw_solar"
            data_generator = $dgSolar
            stroke_width = 3
            show = @{ legend_value = $false }
        }
    )
}

# --- Card 3: Device hour toggle grids ---
$deviceConfigs = @(
    @{ key = "main_geyser"; label = "Main Geyser"; icon = "mdi:water-boiler";      iconColor = "red";    switchEntity = "switch.sonoff_1001f8b113" }
    @{ key = "flat_geyser"; label = "Flat Geyser"; icon = "mdi:water-boiler-auto"; iconColor = "orange"; switchEntity = "switch.sonoff_100179fb1b" }
    @{ key = "pool_pump";   label = "Pool Pump";   icon = "mdi:pool";              iconColor = "blue";   switchEntity = "switch.sonoff_1001f8b132" }
)

$deviceScheduleCards = @()
foreach ($dev in $deviceConfigs) {
    # Label card with live device state
    $labelCard = @{
        type       = "custom:mushroom-template-card"
        entity     = $dev.switchEntity
        primary    = $dev.label
        icon       = $dev.icon
        icon_color = "{{ '$($dev.iconColor)' if is_state('$($dev.switchEntity)', 'on') else 'disabled' }}"
        secondary  = "Currently {{ states('$($dev.switchEntity)') | upper }} | Tap hours to toggle schedule"
    }

    # Build 15 hour toggle cards (06-20) using lightweight entity-card
    $chipCards = @()
    for ($h = 6; $h -le 20; $h++) {
        $hh = $h.ToString("D2")
        $entityId = "input_boolean.override_$($dev.key)_$hh"
        $chipCards += @{
            type           = "custom:mushroom-entity-card"
            entity         = $entityId
            name           = "$hh"
            icon           = "mdi:circle-medium"
            layout         = "vertical"
            primary_info   = "name"
            secondary_info = "none"
            tap_action     = @{
                action  = "call-service"
                service = "input_boolean.toggle"
                service_data = @{ entity_id = $entityId }
            }
        }
    }

    $deviceScheduleCards += @{
        type  = "vertical-stack"
        cards = @(
            $labelCard
            @{
                type    = "grid"
                columns = 8
                square  = $false
                cards   = $chipCards
            }
        )
    }
}

# --- Card 4: Summary grid ---
$summaryGrid = @{
    type    = "grid"
    columns = 4
    square  = $false
    cards   = @(
        @{
            type      = "custom:mushroom-template-card"
            primary   = "{{ state_attr('sensor.energy_schedule', 'total_solar_kwh') | default(0) | round(1) }}"
            secondary = "Solar kWh"
            icon      = "mdi:solar-power"
            icon_color = "amber"
        }
        @{
            type      = "custom:mushroom-template-card"
            primary   = "{{ state_attr('sensor.energy_schedule', 'total_device_kwh') | default(0) | round(1) }}"
            secondary = "Device kWh"
            icon      = "mdi:flash"
            icon_color = "red"
        }
        @{
            type      = "custom:mushroom-template-card"
            primary   = "{{ ((state_attr('sensor.energy_schedule', 'total_solar_kwh') | float(0)) - (state_attr('sensor.energy_schedule', 'total_device_kwh') | float(0)) - 22.5) | round(1) }}"
            secondary = "Surplus kWh"
            icon      = "mdi:battery-charging"
            icon_color = "green"
        }
        @{
            type      = "custom:mushroom-template-card"
            primary   = "{{ states('sensor.battery_soc') | default('?') }}%"
            secondary = "Battery"
            icon      = "mdi:battery"
            icon_color = "green"
        }
    )
}

# --- Card 5: Event log ---
$eventLogContent = @"
{% set events = state_attr('sensor.energy_schedule_log', 'events') %}
{% if events and events | length > 0 %}
| Time | Device | Action |
|------|--------|--------|
{% for e in events | reverse %}| {{ e.time }} | {{ e.device }} | {{ e.action }} |
{% endfor %}
{% else %}
*No switch events today.*
{% endif %}
"@

$eventLogCard = @{
    type    = "markdown"
    title   = "Today's Switch Events"
    content = $eventLogContent
}

# --- Card 6: Master controls ---
$controlsGrid = @{
    type    = "grid"
    columns = 2
    square  = $false
    cards   = @(
        @{
            type   = "custom:mushroom-entity-card"
            entity = "input_boolean.energy_schedule_active"
            name   = "Energy Scheduler"
            icon   = "mdi:lightning-bolt"
            tap_action = @{ action = "toggle" }
        }
        @{
            type   = "custom:mushroom-entity-card"
            entity = "input_boolean.borehole_pump_schedule"
            name   = "Borehole Pump"
            icon   = "mdi:water-pump"
            tap_action = @{ action = "toggle" }
        }
    )
}

# Assemble View 1
$scheduleView = @{
    title = "Schedule"
    path  = "schedule"
    icon  = "mdi:calendar-clock"
    cards = @($headerCard, $solarLoadChart) + $deviceScheduleCards + @($summaryGrid, $eventLogCard, $controlsGrid)
}

Write-Success "Schedule view built ($($scheduleView.cards.Count) cards)"

# ============================================================
# Step 3: Build View 2 - Weather & Solar
# ============================================================

Write-Step "Step 3: Building Weather & Solar view"

# --- Weather briefing ---
$weatherCard = @{
    type    = "markdown"
    title   = "Weather Briefing"
    content = "{{ state_attr('sensor.weather_briefing', 'detailed_summary') | default('Weather data pending - refreshes daily at 04:15') }}"
}

# --- Cloud cover chart ---
$dgCloudCover = "const data = entity.attributes.hourly_cloud_cover || []; return data.map(d => [new Date(d.hour).getTime(), d.cloud_pct]);"

$cloudChart = @{
    type   = "custom:apexcharts-card"
    header = @{ title = "Hourly Cloud Cover"; show = $true }
    graph_span = "1d"
    span   = @{ start = "day" }
    yaxis  = @(@{ id = "pct"; min = 0; max = 100; apex_config = @{ tickAmount = 4 } })
    series = @(
        @{
            entity   = "sensor.weather_briefing"
            name     = "Cloud Cover"
            color    = "#888888"
            type     = "area"
            curve    = "smooth"
            yaxis_id = "pct"
            data_generator = $dgCloudCover
            opacity  = 0.4
        }
    )
}

# --- Solar forecast chart ---
$dgSolarForecast = "const plan = entity.attributes.hourly_plan || []; return plan.map(s => [new Date(new Date().toDateString() + ' ' + s.hour + ':00').getTime(), s.solar_kw]);"

$solarChart = @{
    type   = "custom:apexcharts-card"
    header = @{ title = "Solar Forecast"; show = $true }
    graph_span = "1d"
    span   = @{ start = "day" }
    yaxis  = @(@{ id = "kw"; min = 0; max = 20; apex_config = @{ tickAmount = 4 } })
    series = @(
        @{
            entity   = "sensor.energy_schedule"
            name     = "Solar Available"
            color    = "#FFD700"
            type     = "area"
            curve    = "smooth"
            yaxis_id = "kw"
            data_generator = $dgSolarForecast
            stroke_width = 3
            opacity  = 0.3
        }
    )
}

# --- Key metrics ---
$metricsGrid = @{
    type    = "grid"
    columns = 4
    square  = $false
    cards   = @(
        @{
            type       = "custom:mushroom-template-card"
            primary    = "{{ state_attr('sensor.weather_briefing', 'total_precip_mm') | default(0) }}mm"
            secondary  = "Precipitation"
            icon       = "mdi:weather-rainy"
            icon_color = "blue"
        }
        @{
            type       = "custom:mushroom-template-card"
            primary    = "{{ states('sensor.battery_soc') | default('?') }}%"
            secondary  = "Battery SOC"
            icon       = "mdi:battery"
            icon_color = "green"
        }
        @{
            type       = "custom:mushroom-template-card"
            primary    = "{% if state_attr('sensor.energy_schedule', 'irrigation_disabled') %}Disabled{% else %}Active{% endif %}"
            secondary  = "Irrigation"
            icon       = "mdi:sprinkler"
            icon_color = "{% if state_attr('sensor.energy_schedule', 'irrigation_disabled') %}red{% else %}green{% endif %}"
        }
        @{
            type       = "custom:mushroom-template-card"
            primary    = "{{ state_attr('sensor.energy_schedule', 'confidence') | default('pending') | title }}"
            secondary  = "Confidence"
            icon       = "mdi:shield-check"
            icon_color = "{% if state_attr('sensor.energy_schedule', 'confidence') == 'high' %}green{% elif state_attr('sensor.energy_schedule', 'confidence') == 'medium' %}amber{% else %}red{% endif %}"
        }
    )
}

# --- TTS summary ---
$ttsSummaryCard = @{
    type    = "markdown"
    title   = "Schedule Summary"
    content = "{{ state_attr('sensor.energy_schedule', 'tts_summary') | default('Schedule pending - calculated daily at 04:20') }}"
}

# --- Solar impact note ---
$solarImpactCard = @{
    type    = "markdown"
    title   = "Solar Impact"
    content = "{{ state_attr('sensor.weather_briefing', 'solar_impact') | default('No solar impact data available') }}"
}

# Assemble View 2
$weatherView = @{
    title = "Weather & Solar"
    path  = "weather-solar"
    icon  = "mdi:weather-sunny"
    cards = @($metricsGrid, $ttsSummaryCard, $solarChart, $cloudChart, $solarImpactCard, $weatherCard)
}

Write-Success "Weather & Solar view built ($($weatherView.cards.Count) cards)"

# ============================================================
# Step 4: Save dashboard config
# ============================================================

Write-Step "Step 4: Saving dashboard config"

$dashConfig = @{
    views = @($scheduleView, $weatherView)
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashConfig
    url_path = "energy-schedule"
}

if ($saveResp.success) {
    Write-Success "Energy Schedule dashboard saved with 2 views"
} else {
    Write-Fail "Dashboard save failed: $($saveResp.error.message)"
}

Disconnect-HAWS

# ============================================================
# Done
# ============================================================

Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host " Energy Schedule dashboard setup complete!" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Access at: http://homeassistant.local:8123/energy-schedule/schedule" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Run 18a-Refresh-EnergySchedule.ps1 to generate schedule + sync overrides" -ForegroundColor White
Write-Host "  2. Run 17-Integrity-Check.ps1 to verify" -ForegroundColor White
