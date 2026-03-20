<#
.SYNOPSIS
    Fix Energy dashboard: battery SOC gauge + per-inverter PPV1/PPV2 layout.
    Energy-only — does NOT touch the Overview dashboard (managed by 04a + additive scripts).
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }

# WebSocket helpers
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

Connect-HAWS

$inv1 = "sensor.sunsynk_320152_2207207800"
$inv2 = "sensor.sunsynk_320152_2305136364"

# ============================================================
# Energy Dashboard - single SOC gauge, note on Inv2 SOC
# NOTE: This script is Energy-only. Overview is managed by
#       04a + additive scripts (05a, 05c, 08b, 16a).
# ============================================================

Write-Info "Saving Energy dashboard..."

$energyConfig = @{
    title = "Energy"
    views = @(
        # Combined
        @{
            title = "Combined"; path = "combined"; icon = "mdi:solar-power-variant"
            cards = @(
                # --- Shared Battery SOC ---
                @{
                    type = "gauge"; entity = "sensor.battery_soc"; name = "Battery SOC (8x5kWh = 40kWh)"
                    min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 }
                },
                # --- Side-by-side inverter stats ---
                @{
                    type = "horizontal-stack"
                    cards = @(
                        # Inverter 1 column
                        @{
                            type = "vertical-stack"
                            cards = @(
                                @{
                                    type = "custom:mushroom-template-card"; primary = "Inverter 1"
                                    secondary = "S/N 2207207800"
                                    icon = "mdi:numeric-1-box"; icon_color = "amber"
                                },
                                # Solar
                                @{
                                    type = "custom:mushroom-template-card"
                                    primary = "Solar"
                                    secondary = "{{ states('${inv1}_instantaneous_generation') }}W"
                                    icon = "mdi:solar-panel"; icon_color = "amber"
                                },
                                @{
                                    type = "grid"; columns = 2; square = $false
                                    cards = @(
                                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_ppv1"; name = "PPV1"; layout = "vertical" },
                                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_ppv2"; name = "PPV2"; layout = "vertical" }
                                    )
                                },
                                # Load
                                @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_load"; name = "Load"; icon = "mdi:flash"; icon_color = "blue" },
                                # Grid
                                @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_grid_i_o_total"; name = "Grid I/O"; icon = "mdi:transmission-tower"; icon_color = "red" },
                                # Battery
                                @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_battery_i_o"; name = "Battery I/O"; icon = "mdi:battery-charging"; icon_color = "green" },
                                # Daily
                                @{
                                    type = "entities"; title = "Daily"
                                    entities = @(
                                        @{ entity = "${inv1}_solar_production"; name = "Solar"; icon = "mdi:solar-power" },
                                        @{ entity = "${inv1}_total_load"; name = "Load"; icon = "mdi:flash" },
                                        @{ entity = "${inv1}_grid_to_load"; name = "Grid to Load"; icon = "mdi:transmission-tower" },
                                        @{ entity = "${inv1}_charge"; name = "Batt Charge"; icon = "mdi:battery-plus" },
                                        @{ entity = "${inv1}_discharge"; name = "Batt Discharge"; icon = "mdi:battery-minus" }
                                    )
                                }
                            )
                        },
                        # Inverter 2 column
                        @{
                            type = "vertical-stack"
                            cards = @(
                                @{
                                    type = "custom:mushroom-template-card"; primary = "Inverter 2"
                                    secondary = "S/N 2305136364"
                                    icon = "mdi:numeric-2-box"; icon_color = "orange"
                                },
                                # Solar
                                @{
                                    type = "custom:mushroom-template-card"
                                    primary = "Solar"
                                    secondary = "{{ states('${inv2}_instantaneous_generation') }}W"
                                    icon = "mdi:solar-panel"; icon_color = "orange"
                                },
                                @{
                                    type = "grid"; columns = 2; square = $false
                                    cards = @(
                                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_ppv1"; name = "PPV1"; layout = "vertical" },
                                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_ppv2"; name = "PPV2"; layout = "vertical" }
                                    )
                                },
                                # Load
                                @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_load"; name = "Load"; icon = "mdi:flash"; icon_color = "blue" },
                                # Grid
                                @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_grid_i_o_total"; name = "Grid I/O"; icon = "mdi:transmission-tower"; icon_color = "red" },
                                # Battery
                                @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_battery_i_o"; name = "Battery I/O"; icon = "mdi:battery-charging"; icon_color = "green" },
                                # Daily
                                @{
                                    type = "entities"; title = "Daily"
                                    entities = @(
                                        @{ entity = "${inv2}_solar_production"; name = "Solar"; icon = "mdi:solar-power" },
                                        @{ entity = "${inv2}_total_load"; name = "Load"; icon = "mdi:flash" },
                                        @{ entity = "${inv2}_grid_to_load"; name = "Grid to Load"; icon = "mdi:transmission-tower" },
                                        @{ entity = "${inv2}_charge"; name = "Batt Charge"; icon = "mdi:battery-plus" },
                                        @{ entity = "${inv2}_discharge"; name = "Batt Discharge"; icon = "mdi:battery-minus" }
                                    )
                                }
                            )
                        }
                    )
                },
                # --- Combined totals row ---
                @{
                    type = "custom:mushroom-template-card"; primary = "Combined Totals"
                    secondary = "Solar: {{ states('sensor.solar_total_generation') }}W | Load: {{ states('sensor.solar_total_load') }}W"
                    icon = "mdi:sigma"; icon_color = "cyan"
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_daily_production"; name = "Solar Today"; icon = "mdi:solar-power"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_daily_load"; name = "Load Today"; icon = "mdi:home-lightning-bolt"; layout = "vertical" }
                    )
                },
                # Top consumers
                @{
                    type = "entities"; title = "Top Energy Consumers (Monthly)"
                    entities = @(
                        @{ entity = "sensor.sonoff_1001f8b113_energy_month"; name = "Main Geyser"; icon = "mdi:water-boiler" },
                        @{ entity = "sensor.sonoff_1001f8b132_energy_month"; name = "Pool Pump"; icon = "mdi:pool" },
                        @{ entity = "sensor.sonoff_100179fb1b_energy_month"; name = "Flat Geyser"; icon = "mdi:water-boiler" },
                        @{ entity = "sensor.sonoff_1001f8af07_energy_month"; name = "Aircon"; icon = "mdi:air-conditioner" }
                    )
                }
            )
        },
        # Inverter 1
        @{
            title = "Inverter 1"; path = "inverter1"; icon = "mdi:numeric-1-box"
            cards = @(
                @{ type = "markdown"; content = "## Inverter 1 - S/N 2207207800`n8.8kW Inverter | 9kWp Solar | 4x5kWh = 20kWh Battery`n`n**Note:** Battery SOC on this inverter reports the combined SOC for all 40kWh (8 batteries across both inverters)." },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_ppv1"; name = "PPV1"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_ppv2"; name = "PPV2"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_generation"; name = "Total PV"; icon = "mdi:solar-power"; icon_color = "amber"; layout = "vertical" }
                    )
                },
                @{ type = "gauge"; entity = "${inv1}_instantaneous_battery_soc"; name = "Battery SOC (all 40kWh)"; min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 } },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_charge"; name = "Charge Today"; icon = "mdi:battery-plus"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_discharge"; name = "Discharge Today"; icon = "mdi:battery-minus"; layout = "vertical" }
                    )
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_load"; name = "Load"; icon = "mdi:flash"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_grid_i_o_total"; name = "Grid"; icon = "mdi:transmission-tower"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_battery_i_o"; name = "Battery"; icon = "mdi:battery"; layout = "vertical" }
                    )
                },
                @{
                    type = "entities"; title = "Daily Stats"
                    entities = @(
                        @{ entity = "${inv1}_solar_production"; name = "Solar Production" },
                        @{ entity = "${inv1}_total_load"; name = "Total Load" },
                        @{ entity = "${inv1}_grid_to_load"; name = "Grid to Load" },
                        @{ entity = "${inv1}_solar_to_grid"; name = "Solar to Grid" },
                        @{ entity = "${inv1}_charge"; name = "Battery Charge" },
                        @{ entity = "${inv1}_discharge"; name = "Battery Discharge" }
                    )
                }
            )
        },
        # Inverter 2
        @{
            title = "Inverter 2"; path = "inverter2"; icon = "mdi:numeric-2-box"
            cards = @(
                @{ type = "markdown"; content = "## Inverter 2 - S/N 2305136364`n8.8kW Inverter | 9kWp Solar | 4x5kWh = 20kWh Battery`n`n**Note:** This inverter reports 0% SOC. The combined battery SOC for all 40kWh is reported by Inverter 1." },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_ppv1"; name = "PPV1"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_ppv2"; name = "PPV2"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_generation"; name = "Total PV"; icon = "mdi:solar-power"; icon_color = "amber"; layout = "vertical" }
                    )
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_charge"; name = "Charge Today"; icon = "mdi:battery-plus"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_discharge"; name = "Discharge Today"; icon = "mdi:battery-minus"; layout = "vertical" }
                    )
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_load"; name = "Load"; icon = "mdi:flash"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_grid_i_o_total"; name = "Grid"; icon = "mdi:transmission-tower"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_battery_i_o"; name = "Battery"; icon = "mdi:battery"; layout = "vertical" }
                    )
                },
                @{
                    type = "entities"; title = "Daily Stats"
                    entities = @(
                        @{ entity = "${inv2}_solar_production"; name = "Solar Production" },
                        @{ entity = "${inv2}_total_load"; name = "Total Load" },
                        @{ entity = "${inv2}_grid_to_load"; name = "Grid to Load" },
                        @{ entity = "${inv2}_solar_to_grid"; name = "Solar to Grid" },
                        @{ entity = "${inv2}_charge"; name = "Battery Charge" },
                        @{ entity = "${inv2}_discharge"; name = "Battery Discharge" }
                    )
                }
            )
        }
    )
}

$r = Invoke-WS "lovelace/config/save" @{ config = $energyConfig; url_path = "energy-dashboard" }
if ($r.success) { Write-Success "Energy saved" } else { Write-Host "  FAIL: $($r.error.message)" -ForegroundColor Red }

$script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait()
Write-Success "Done! Refresh your browser."
