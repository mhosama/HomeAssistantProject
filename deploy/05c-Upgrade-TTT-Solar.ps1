<#
.SYNOPSIS
    Upgrade Battery Time To Twenty sensor with solar-aware calculation.

.DESCRIPTION
    1. Deletes the existing "Battery Time To Twenty" template sensor
    2. Recreates it with a solar-aware Jinja2 template that factors in:
       - Per-hour nominal solar generation (parabolic curve, 8AM-5PM)
       - Hourly cloud cover from sensor.weather_briefing
       - Battery charging when solar exceeds load (95% efficiency)
    3. Installs apexcharts-card via HACS for the projection graph
    4. Adds a 48h Battery Projection graph to the Overview dashboard

.EXAMPLE
    .\05c-Upgrade-TTT-Solar.ps1
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
# REST helper
# ============================================================

function Invoke-HAREST {
    param([string]$Endpoint, [string]$Method = "GET", [string]$JsonBody = $null)
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $headers = @{ "Authorization" = "Bearer $($Config.HA_TOKEN)"; "Content-Type" = "application/json" }
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($JsonBody) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($JsonBody) }
    try { return Invoke-RestMethod @params } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Fail "REST $Method $Endpoint -> HTTP $status"
        return $null
    }
}

# ============================================================
# WebSocket helpers
# ============================================================

$script:ws = $null; $script:cts = $null; $script:wsId = 0

function Connect-HAWS {
    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $script:cts.CancelAfter(60000); $script:wsId = 0
    $script:ws.ConnectAsync([Uri]"ws://$($Config.HA_IP):8123/api/websocket", $script:cts.Token).Wait()
    $null = Receive-HAWS
    Send-HAWS (@{type="auth"; access_token=$Config.HA_TOKEN} | ConvertTo-Json -Compress)
    $null = Receive-HAWS
    Write-Success "WebSocket connected"
}

function Send-HAWS([string]$msg) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $script:ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $script:cts.Token).Wait()
}

function Receive-HAWS {
    $all = ""
    do {
        $buf = New-Object byte[] 65536
        $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $buf)
        $r = $script:ws.ReceiveAsync($seg, $script:cts.Token).Result
        $all += [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    return $all
}

function Invoke-WS([string]$Type, [hashtable]$Extra = @{}) {
    $script:wsId++
    $msg = @{ id = $script:wsId; type = $Type } + $Extra
    Send-HAWS ($msg | ConvertTo-Json -Depth 20 -Compress)
    return (Receive-HAWS | ConvertFrom-Json)
}

# ============================================================
# Step 1: Delete existing "Battery Time To Twenty" template sensor
# ============================================================

Write-Step "Step 1: Delete existing Battery Time To Twenty sensor"

$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$tttEntry = $null
if ($existingEntries) {
    $tttEntry = $existingEntries | Where-Object { $_.domain -eq "template" -and $_.title -eq "Battery Time To Twenty" }
}

if ($tttEntry) {
    Write-Info "Found existing entry: $($tttEntry.entry_id) - deleting..."
    $delResult = Invoke-HAREST -Endpoint "/api/config/config_entries/entry/$($tttEntry.entry_id)" -Method "DELETE"
    if ($delResult -ne $null -or $true) {
        # DELETE returns empty on success
        Write-Success "Deleted old TTT sensor"
    }
} else {
    Write-Info "No existing TTT sensor found - will create fresh"
}

Start-Sleep -Seconds 2

# ============================================================
# Step 2: Create solar-aware TTT template sensor
# ============================================================

Write-Step "Step 2: Create solar-aware Battery Time To Twenty sensor"

$flowBody = @{ handler = "template" } | ConvertTo-Json
$flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody
if (-not $flow) { Write-Fail "Could not start config flow"; exit 1 }

$selectBody = @{ next_step_id = "sensor" } | ConvertTo-Json
$null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody $selectBody

# Solar-aware TTT Jinja2 template
# Uses namespace() for mutable state in for loop
# Simulates hour-by-hour battery drain/charge with cloud-attenuated solar
$tttTemplate = @"
{% set ns = namespace(soc = states('sensor.battery_soc') | float(0), hours = 0.0) %}
{% set load = states('sensor.solar_total_load') | float(0) %}
{% set capacity = 40 * 0.95 %}
{% set cloud_data = state_attr('sensor.weather_briefing', 'hourly_cloud_cover') %}
{% set now_ts = now() %}
{% if ns.soc <= 20 or load <= 0 %}
0
{% else %}
{% set ns2 = namespace(found = false) %}
{% for h in range(48) %}
{% if not ns2.found %}
{% set future = now_ts + timedelta(hours=h) %}
{% set hod = future.hour + future.minute / 60 %}
{% if hod >= 8 and hod <= 17 %}
{% set nominal = 800 + 15200 * (1 - ((hod - 12.5) / 4.5) ** 2) %}
{% if nominal < 0 %}{% set nominal = 0 %}{% endif %}
{% else %}
{% set nominal = 0 %}
{% endif %}
{% set cloud = 0 %}
{% if cloud_data and cloud_data | length > 0 %}
{% set future_str = future.strftime('%Y-%m-%dT%H:00') %}
{% for entry in cloud_data %}
{% if entry.hour == future_str %}
{% set cloud = entry.cloud_pct | float(0) %}
{% endif %}
{% endfor %}
{% endif %}
{% if cloud <= 50 %}
{% set factor = 1.0 - cloud * 0.006 %}
{% else %}
{% set factor = 1.2 - cloud * 0.01 %}
{% endif %}
{% set solar_w = nominal * factor %}
{% set net = load - solar_w %}
{% if net > 0 %}
{% set drain_kwh = net / 1000 %}
{% set soc_drop = drain_kwh / capacity * 100 %}
{% set ns.soc = ns.soc - soc_drop %}
{% else %}
{% set charge_kwh = (solar_w - load) / 1000 * 0.95 %}
{% set soc_gain = charge_kwh / capacity * 100 %}
{% set ns.soc = [ns.soc + soc_gain, 100] | min %}
{% endif %}
{% if ns.soc <= 20 %}
{% set ns.hours = h %}
{% if h > 0 %}
{% set prev_soc = ns.soc + (soc_drop if net > 0 else 0) %}
{% if prev_soc > 20 and soc_drop > 0 %}
{% set frac = (prev_soc - 20) / soc_drop %}
{% set ns.hours = h - 1 + (1 - frac) %}
{% endif %}
{% endif %}
{% set ns2.found = true %}
{% endif %}
{% endif %}
{% endfor %}
{% if ns2.found %}
{{ ns.hours | round(1) }}
{% else %}
48
{% endif %}
{% endif %}
"@

$sensorData = @{
    name                = "Battery Time To Twenty"
    state               = $tttTemplate
    unit_of_measurement = "h"
    device_class        = "duration"
    state_class         = "measurement"
}

$result = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody ($sensorData | ConvertTo-Json)
if ($result -and $result.type -eq "create_entry") {
    Write-Success "Solar-aware Battery Time To Twenty sensor created"
} else {
    Write-Fail "Failed to create TTT sensor"
    Write-Host "  Result: $($result | ConvertTo-Json -Compress)" -ForegroundColor Gray
}

# ============================================================
# Step 3: Install apexcharts-card via HACS
# ============================================================

Write-Step "Step 3: Install apexcharts-card via HACS"

Connect-HAWS

# List HACS repositories to find apexcharts-card
Write-Info "Listing HACS repositories..."
$hacsRepos = Invoke-WS "hacs/repositories/list"

$apexId = $null
if ($hacsRepos.success -and $hacsRepos.result) {
    $apex = $hacsRepos.result | Where-Object { $_.full_name -eq "RomRider/apexcharts-card" }
    if ($apex) {
        $apexId = $apex.id
        Write-Info "Found apexcharts-card: ID=$apexId"
    }
}

if ($apexId) {
    # Check if already installed
    if ($apex.installed) {
        Write-Success "apexcharts-card already installed"
    } else {
        Write-Info "Downloading apexcharts-card..."
        $dlResult = Invoke-WS "hacs/repository/download" @{ repository = $apexId }
        if ($dlResult.success) {
            Write-Success "apexcharts-card downloaded"
        } else {
            Write-Fail "Failed to download: $($dlResult.error.message)"
        }
    }
} else {
    Write-Fail "apexcharts-card not found in HACS repository list"
    Write-Info "You may need to add it manually: HACS > Frontend > + Explore > apexcharts-card"
}

# ============================================================
# Step 4: Add projection graph to Overview dashboard
# ============================================================

Write-Step "Step 4: Update Overview dashboard with projection graph"

# Get current overview config
$currentConfig = Invoke-WS "lovelace/config" @{}

if (-not $currentConfig.success) {
    Write-Fail "Could not fetch current Overview dashboard config"
    Write-Info "Skipping dashboard update - add the graph manually"
} else {
    $config = $currentConfig.result

    # Find the Overview view
    $overviewView = $null
    $overviewIdx = -1
    for ($i = 0; $i -lt $config.views.Count; $i++) {
        if ($config.views[$i].path -eq "overview" -or $config.views[$i].title -eq "Overview") {
            $overviewView = $config.views[$i]
            $overviewIdx = $i
            break
        }
    }

    if ($overviewView) {
        # Build the apexcharts projection card
        $projectionCard = @{
            type = "vertical-stack"
            cards = @(
                @{
                    type = "custom:apexcharts-card"
                    header = @{
                        title = "Battery Projection (24h)"
                        show = $true
                    }
                    graph_span = "24h"
                    span = @{
                        start = "minute"
                    }
                    now = @{
                        show = $true
                        label = "Now"
                    }
                    apex_config = @{
                        chart = @{ height = "250px" }
                        yaxis = @(
                            @{
                                id = "power"
                                title = @{ text = "Watts" }
                                min = 0
                            },
                            @{
                                id = "soc"
                                title = @{ text = "SOC %" }
                                opposite = $true
                                min = 0
                                max = 100
                            }
                        )
                    }
                    series = @(
                        @{
                            entity = "sensor.battery_projection"
                            name = "Solar Generation"
                            yaxis_id = "power"
                            color = "#FFC107"
                            data_generator = "return entity.attributes.hours.map((h, i) => [new Date(h).getTime(), entity.attributes.projected_solar[i]]);"
                        },
                        @{
                            entity = "sensor.battery_projection"
                            name = "House Load"
                            yaxis_id = "power"
                            color = "#F44336"
                            data_generator = "return entity.attributes.hours.map((h, i) => [new Date(h).getTime(), entity.attributes.projected_load[i]]);"
                        },
                        @{
                            entity = "sensor.battery_projection"
                            name = "Battery SOC"
                            yaxis_id = "soc"
                            color = "#4CAF50"
                            data_generator = "return entity.attributes.hours.map((h, i) => [new Date(h).getTime(), entity.attributes.projected_soc[i]]);"
                        }
                    )
                }
            )
        }

        # Insert the projection card after the first card (Energy section) in the Overview view
        $cards = [System.Collections.ArrayList]@($overviewView.cards)

        # Check if projection card already exists
        $hasProjection = $false
        foreach ($card in $cards) {
            if ($card.cards) {
                foreach ($subcard in $card.cards) {
                    if ($subcard.type -eq "custom:apexcharts-card" -and $subcard.header.title -like "Battery Projection*") {
                        $hasProjection = $true
                        break
                    }
                }
            }
            if ($hasProjection) { break }
        }

        if ($hasProjection) {
            Write-Success "Projection graph already on dashboard"
        } else {
            # Insert after the first card (Energy section, index 0)
            $cards.Insert(1, $projectionCard)
            $config.views[$overviewIdx].cards = $cards.ToArray()

            $saveResult = Invoke-WS "lovelace/config/save" @{ config = $config }
            if ($saveResult.success) {
                Write-Success "Overview dashboard updated with projection graph"
            } else {
                Write-Fail "Dashboard save failed: $($saveResult.error.message)"
            }
        }
    } else {
        Write-Fail "Could not find Overview view in dashboard"
    }
}

# Close WebSocket
try {
    $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait()
} catch {}

# ============================================================
# Done
# ============================================================

Write-Step "Done!"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Run 09a-Refresh-Weather.ps1 to populate hourly_cloud_cover" -ForegroundColor Gray
Write-Host "    2. Verify sensor.battery_time_to_twenty shows solar-aware values" -ForegroundColor Gray
Write-Host "    3. Deploy 05d-Refresh-TTT-Projection.ps1 to server (10-min schedule)" -ForegroundColor Gray
Write-Host "    4. Verify the projection graph on the Overview dashboard" -ForegroundColor Gray
Write-Host ""
