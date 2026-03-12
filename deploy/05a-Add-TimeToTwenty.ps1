<#
.SYNOPSIS
    Add "Battery Time To Twenty" template sensor and update Overview dashboard.

.DESCRIPTION
    1. Creates a template sensor that estimates hours until battery reaches 20% SOC
       under current load. Battery: 40kWh * 0.95 age multiplier = 38kWh usable.
    2. Updates the Overview dashboard Energy section to show Load and TTT.

.EXAMPLE
    .\05a-Add-TimeToTwenty.ps1
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
    if ($JsonBody) { $params.Body = $JsonBody }
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
    Write-Success "Connected"
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
# Step 1: Create "Battery Time To Twenty" template sensor
# ============================================================

Write-Step "Step 1: Create Battery Time To Twenty sensor"

# Check if it already exists
$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$existingTemplates = @()
if ($existingEntries) {
    $existingTemplates = $existingEntries | Where-Object { $_.domain -eq "template" } | ForEach-Object { $_.title }
}

$sensorName = "Battery Time To Twenty"

if ($existingTemplates -contains $sensorName) {
    Write-Success "$sensorName already exists - skipping"
} else {
    Write-Info "Creating: $sensorName..."

    $flowBody = @{ handler = "template" } | ConvertTo-Json
    $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody
    if (-not $flow) { Write-Fail "Could not start config flow"; exit 1 }

    $selectBody = @{ next_step_id = "sensor" } | ConvertTo-Json
    $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody $selectBody

    $tttTemplate = @"
{% set soc = states('sensor.battery_soc') | float(0) %}
{% set load = states('sensor.solar_total_load') | float(0) %}
{% set capacity = 40 * 0.95 %}
{% set usable_kwh = (soc - 20) / 100 * capacity %}
{% if soc <= 20 or load <= 0 %}
  0
{% else %}
  {{ (usable_kwh / (load / 1000)) | round(1) }}
{% endif %}
"@

    $sensorData = @{
        name                = $sensorName
        state               = $tttTemplate
        unit_of_measurement = "h"
        device_class        = "duration"
        state_class         = "measurement"
    }

    $result = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody ($sensorData | ConvertTo-Json)
    if ($result -and $result.type -eq "create_entry") {
        Write-Success "$sensorName created"
    } else {
        Write-Fail "Failed to create $sensorName"
        Write-Host "  Result: $($result | ConvertTo-Json -Compress)" -ForegroundColor Gray
    }
}

# ============================================================
# Step 2: Update Overview dashboard with TTT in Energy section
# ============================================================

Write-Step "Step 2: Update Overview dashboard"

Connect-HAWS

$overviewConfig = @{
    title = "Home"
    views = @(
        @{
            title = "Overview"; path = "overview"; icon = "mdi:home"
            cards = @(
                # Energy
                @{
                    type = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Energy"
                            secondary = "Solar: {{ states('sensor.solar_total_generation') }}W | Load: {{ states('sensor.solar_total_load') }}W | Battery: {{ states('sensor.battery_soc') }}%"
                            icon = "mdi:solar-power"; icon_color = "amber"
                            tap_action = @{ action = "navigate"; navigation_path = "/energy-dashboard" }
                        },
                        @{
                            type = "gauge"; entity = "sensor.battery_soc"; name = "Battery (40kWh)"
                            min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 }
                        },
                        @{
                            type = "grid"; columns = 3; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_generation"; name = "Solar"; icon = "mdi:solar-panel"; icon_color = "amber" },
                                @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_load"; name = "Load"; icon = "mdi:flash"; icon_color = "blue" },
                                @{
                                    type = "custom:mushroom-template-card"
                                    primary = "TTT"
                                    secondary = "{{ states('sensor.battery_time_to_twenty') }}h"
                                    icon = "mdi:timer-sand"
                                    icon_color = "{{ 'green' if states('sensor.battery_time_to_twenty') | float(0) > 4 else ('orange' if states('sensor.battery_time_to_twenty') | float(0) >= 1 else 'red') }}"
                                }
                            )
                        }
                    )
                },
                # Security
                @{
                    type = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Security"
                            secondary = "Doors open: {{ states('sensor.doors_open_count') }}"
                            icon = "mdi:shield-home"
                            icon_color = "{{ 'red' if states('sensor.doors_open_count') | int > 0 else 'green' }}"
                            tap_action = @{ action = "navigate"; navigation_path = "/security-dashboard" }
                        },
                        @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_10011481af"; name = "Main Gate"; icon = "mdi:gate" },
                        @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_100114809c"; name = "Visitor Gate"; icon = "mdi:gate" }
                    )
                },
                # Climate
                @{
                    type = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Climate"
                            secondary = "{{ states('sensor.sonoff_a48003e78d_temperature') }}C | {{ states('sensor.sonoff_a48003e78d_humidity') }}%"
                            icon = "mdi:thermometer"; icon_color = "teal"
                            tap_action = @{ action = "navigate"; navigation_path = "/water-climate-dashboard" }
                        },
                        @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1001f8b113"; name = "Main Geyser"; icon = "mdi:water-boiler" },
                        @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_100179fb1b"; name = "Flat Geyser"; icon = "mdi:water-boiler" }
                    )
                },
                # Lighting
                @{
                    type = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Lighting"
                            secondary = "{{ states('sensor.lights_on_count') }} lights on"
                            icon = "mdi:lightbulb-group"; icon_color = "yellow"
                            tap_action = @{ action = "navigate"; navigation_path = "/lighting-dashboard" }
                        },
                        @{
                            type = "grid"; columns = 2; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000feb8de_1"; name = "Lounge"; icon = "mdi:lamp"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000feaf53_2"; name = "Kitchen"; icon = "mdi:ceiling-light"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000febc4d_1"; name = "Bedroom"; icon = "mdi:lamp"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000f4023f_3"; name = "Yard"; icon = "mdi:outdoor-lamp"; tap_action = @{ action = "toggle" } }
                            )
                        }
                    )
                },
                # Water
                @{
                    type = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Water"
                            secondary = "Irrigation & Pumps"
                            icon = "mdi:water-pump"; icon_color = "blue"
                            tap_action = @{ action = "navigate"; navigation_path = "/water-climate-dashboard" }
                        },
                        @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_10011058e1"; name = "Borehole"; icon = "mdi:water-pump" },
                        @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1001f8b132"; name = "Pool Pump"; icon = "mdi:pool" }
                    )
                },
                # Media
                @{
                    type = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Media"
                            secondary = "TV & Speakers"; icon = "mdi:speaker-multiple"; icon_color = "deep-purple"
                            tap_action = @{ action = "navigate"; navigation_path = "/media-dashboard" }
                        },
                        @{
                            type = "custom:mushroom-media-player-card"; entity = "media_player.samsung_tv"; name = "Samsung TV"
                            use_media_info = $true; show_volume_level = $false; collapsible_controls = $true
                        }
                    )
                }
            )
        }
    )
}

Write-Info "Saving Overview dashboard..."
$r = Invoke-WS "lovelace/config/save" @{ config = $overviewConfig }
if ($r.success) { Write-Success "Overview saved" } else { Write-Fail "Overview: $($r.error.message)" }

$script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait()

# ============================================================
# Done
# ============================================================

Write-Step "Done!"
Write-Host ""
Write-Host "  Verify:" -ForegroundColor White
Write-Host "    1. Developer Tools > States > sensor.battery_time_to_twenty" -ForegroundColor Gray
Write-Host "    2. Overview dashboard shows Solar, Load, and TTT cards" -ForegroundColor Gray
Write-Host "    3. Sanity check: at 82% SOC with 1867W load -> ~12.6h" -ForegroundColor Gray
Write-Host ""
