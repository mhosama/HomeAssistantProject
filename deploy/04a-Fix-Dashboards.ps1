<#
.SYNOPSIS
    Fix all dashboard entity IDs using actual HA entity names.

.DESCRIPTION
    Rebuilds template sensors and all 6 dashboards with verified entity IDs.
    Run this after 04-Setup-Dashboards.ps1 to fix entity-not-found errors.

.EXAMPLE
    .\04a-Fix-Dashboards.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# Output helpers
# ============================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
}

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
# Entity ID Map (verified from /api/states)
# ============================================================

# --- Sunsynk Inverters ---
$inv1 = "sensor.sunsynk_320152_2207207800"
$inv2 = "sensor.sunsynk_320152_2305136364"

# --- Switches ---
$sw = @{
    # Lights - Living
    LoungeLight       = "switch.sonoff_1000feb8de_1"
    LoungeMood        = "switch.sonoff_1000feb8de_2"
    KitchenLight      = "switch.sonoff_1000feaf53_2"
    KitchenSwitch     = "switch.sonoff_1000a21c46"
    DiningLight1      = "switch.sonoff_1000feaf53_1"
    DiningLight2      = "switch.sonoff_10008cd8c2_2"
    BarLights         = "switch.sonoff_1000f40689_2"
    BarFan            = "switch.sonoff_1000f40689_1"
    HallwayLights     = "switch.sonoff_1000f71419"
    TVLights          = "switch.sonoff_1000f4023f_1"
    PlayAreaLights    = "switch.sonoff_10008cd8c2_1"

    # Lights - Bedrooms
    MainBedLight      = "switch.sonoff_1000febc4d_1"
    WardrobeLights    = "switch.sonoff_1000febc4d_2"
    BabyRoomLights    = "switch.sonoff_1000f70f8a"
    GuestRoomLights   = "switch.sonoff_1000f70ce2"
    BabyBathroomLight = "switch.sonoff_1000f712d4"

    # Lights - Utility
    LaundryLight      = "switch.sonoff_1000a1e353"
    SculleryLight     = "switch.sonoff_1000febc1b_1"
    GarageLight       = "switch.sonoff_1000f712c8"
    WorkshopLights    = "switch.sonoff_1000f4023f_2"
    WineCellarLight   = "switch.sonoff_1000feb50b_2"
    GuestBathLight    = "switch.sonoff_1000feb50b_1"

    # Lights - Outdoor
    FrontPorchLight   = "switch.sonoff_1000f4047e_2"
    CourtyardLight    = "switch.sonoff_1000f4047e_3"
    YardLights        = "switch.sonoff_1000f4023f_3"
    BackdoorLights    = "switch.sonoff_1000febc1b_2"
    PoolLights        = "switch.sonoff_1001105a65"
    ReceptionLights   = "switch.sonoff_1000f4047e_1"
    VisitorGateLights = "switch.sonoff_1000f40689_3"

    # Lights - Airbnb
    AirbnbBedLights   = "switch.sonoff_1000febc05_1"
    AirbnbTVLights    = "switch.sonoff_1000f706e3"
    AirbnbBathLights  = "switch.sonoff_1001195db2_1"
    AirbnbBathFan     = "switch.sonoff_1001195db2_2"
    AirbnbTowelRack   = "switch.sonoff_1001195db2_3"

    # Gates
    MainGate          = "switch.sonoff_10011481af"
    VisitorGate       = "switch.sonoff_100114809c"

    # Geysers
    MainGeyser        = "switch.sonoff_1001f8b113"
    FlatGeyser        = "switch.sonoff_100179fb1b"
    GuestGeyser       = "switch.sonoff_100143260c"

    # Pumps
    Borehole          = "switch.sonoff_10011058e1"
    PoolPump          = "switch.sonoff_1001f8b132"
    TankPump          = "switch.sonoff_1000a21e3c"

    # Other
    Aircon            = "switch.sonoff_1001f8af07"
    AlarmMagnets      = "switch.sonoff_10016363b1"
    AlarmMotion       = "switch.sonoff_100160713a"

    # Irrigation valves
    HosePipe          = "switch.sonoff_a4800bd713_switch"
    VegGarden         = "switch.sonoff_a4800bd719_switch"
    ShedGarden        = "switch.sonoff_a4800bd71c_switch"
    BufferTank        = "switch.sonoff_a4800c7052_switch"
}

# --- Binary Sensors (doors) ---
$doors = @(
    @{ Entity = "binary_sensor.sonoff_a48003e788"; Name = "Main Bedroom Door" },
    @{ Entity = "binary_sensor.sonoff_a48007aace"; Name = "Houtkamer Door" },
    @{ Entity = "binary_sensor.sonoff_a48003de7c"; Name = "Kitchen Hallway Door" },
    @{ Entity = "binary_sensor.sonoff_a48003e73f"; Name = "Storage Room Door" },
    @{ Entity = "binary_sensor.sonoff_a48007aabd"; Name = "Nissan Garage Door" },
    @{ Entity = "binary_sensor.sonoff_a48003e746"; Name = "AirBnB Patio Door" },
    @{ Entity = "binary_sensor.sonoff_a48003d0a7"; Name = "Patio Door 1" },
    @{ Entity = "binary_sensor.sonoff_a48003d09f"; Name = "Patio Door 3" },
    @{ Entity = "binary_sensor.sonoff_a48003d0a5"; Name = "Patio Door 2" },
    @{ Entity = "binary_sensor.sonoff_a48003ce90"; Name = "Backdoor" },
    @{ Entity = "binary_sensor.sonoff_a48003e749"; Name = "Airbnb Door" },
    @{ Entity = "binary_sensor.sonoff_a48003e73b"; Name = "Courtyard/Front Door" }
)

# --- Binary Sensors (motion) ---
$motion = @(
    @{ Entity = "binary_sensor.sonoff_a48003d0b9"; Name = "Baby Bathroom Motion" },
    @{ Entity = "binary_sensor.sonoff_a480044a59"; Name = "Kids Bathroom Motion" },
    @{ Entity = "binary_sensor.sonoff_a4800654ed"; Name = "Study Motion" },
    @{ Entity = "binary_sensor.sonoff_a480044a9b"; Name = "Hallway Motion" },
    @{ Entity = "binary_sensor.sonoff_a4800654e2"; Name = "TV Motion" }
)

# --- Power Monitoring Sensors ---
$pwr = @{
    MainGeyserPower   = "sensor.sonoff_1001f8b113_power"
    MainGeyserEnergy  = "sensor.sonoff_1001f8b113_energy_month"
    MainGeyserEDay    = "sensor.sonoff_1001f8b113_energy_day"
    FlatGeyserPower   = "sensor.sonoff_100179fb1b_power"
    FlatGeyserEnergy  = "sensor.sonoff_100179fb1b_energy_month"
    FlatGeyserEDay    = "sensor.sonoff_100179fb1b_energy_day"
    GuestGeyserPower  = "sensor.sonoff_100143260c_power"
    PoolPumpPower     = "sensor.sonoff_1001f8b132_power"
    PoolPumpEnergy    = "sensor.sonoff_1001f8b132_energy_month"
    PoolPumpEDay      = "sensor.sonoff_1001f8b132_energy_day"
    AirconPower       = "sensor.sonoff_1001f8af07_power"
    AirconEnergy      = "sensor.sonoff_1001f8af07_energy_month"
    PoolLightsPower   = "sensor.sonoff_1001105a65_power"
    BoreholePower     = "sensor.sonoff_10011058e1_power"
}

# --- Water Sensors ---
$water = @{
    HosePipe   = "sensor.sonoff_a4800bd713_water"
    VegGarden  = "sensor.sonoff_a4800bd719_water"
    ShedGarden = "sensor.sonoff_a4800bd71c_water"
    BufferTank = "sensor.sonoff_a4800c7052_water"
}

# --- Temperature ---
$temp = @{
    MainBedTemp          = "sensor.sonoff_a48003e78d_temperature"
    MainBedHumidity      = "sensor.sonoff_a48003e78d_humidity"
    InverterRoomTemp     = "sensor.sonoff_a48007a2b0_temperature"
    InverterRoomHumidity = "sensor.sonoff_a48007a2b0_humidity"
}

# --- Media ---
$media = @{
    SamsungTV       = "media_player.samsung_tv"
    Kitchen         = "media_player.kitchen_speaker"
    DiningRoom      = "media_player.dining_room_speaker"
    FrontHome       = "media_player.front_home_speakers"
    Study           = "media_player.study_speaker"
    Bedroom         = "media_player.bedroom_speaker"
    BabyRoom        = "media_player.baby_room_speaker"
    GuestRoom       = "media_player.guest_room_speaker"
    Airbnb          = "media_player.airbnb_speaker"
    HomeGroup       = "media_player.home_speakers"
    TVChromecast    = "media_player.tv_chromecast"
}

# ============================================================
# Step 1: Recreate Template Sensors
# ============================================================

Write-Step "Step 1: Fix Template Sensors"

$templateSensors = @(
    @{
        Name = "Solar Total Generation"
        State = "{{ states('${inv1}_instantaneous_generation') | float(0) + states('${inv2}_instantaneous_generation') | float(0) }}"
        UnitOfMeasurement = "W"; DeviceClass = "power"; StateClass = "measurement"
    },
    @{
        Name = "Solar Total Load"
        State = "{{ states('${inv1}_instantaneous_load') | float(0) + states('${inv2}_instantaneous_load') | float(0) }}"
        UnitOfMeasurement = "W"; DeviceClass = "power"; StateClass = "measurement"
    },
    @{
        Name = "Solar Total Battery IO"
        State = "{{ states('${inv1}_instantaneous_battery_i_o') | float(0) + states('${inv2}_instantaneous_battery_i_o') | float(0) }}"
        UnitOfMeasurement = "W"; DeviceClass = "power"; StateClass = "measurement"
    },
    @{
        Name = "Solar Total Grid IO"
        State = "{{ states('${inv1}_instantaneous_grid_i_o_total') | float(0) + states('${inv2}_instantaneous_grid_i_o_total') | float(0) }}"
        UnitOfMeasurement = "W"; DeviceClass = "power"; StateClass = "measurement"
    },
    @{
        Name = "Solar Daily Production"
        State = "{{ states('${inv1}_solar_production') | float(0) + states('${inv2}_solar_production') | float(0) }}"
        UnitOfMeasurement = "kWh"; DeviceClass = "energy"; StateClass = "total_increasing"
    },
    @{
        Name = "Solar Battery SOC Average"
        State = "{{ ((states('${inv1}_instantaneous_battery_soc') | float(0) + states('${inv2}_instantaneous_battery_soc') | float(0)) / 2) | round(0) }}"
        UnitOfMeasurement = "%"; DeviceClass = "battery"; StateClass = $null
    },
    @{
        Name = "Solar Daily Load"
        State = "{{ states('${inv1}_total_load') | float(0) + states('${inv2}_total_load') | float(0) }}"
        UnitOfMeasurement = "kWh"; DeviceClass = "energy"; StateClass = "total_increasing"
    },
    @{
        Name = "Lights On Count"
        State = "{{ states.switch | selectattr('entity_id', 'match', 'switch.sonoff_') | selectattr('attributes.friendly_name', 'search', '(?i)(light|lamp|mood)', ignorecase=True) | selectattr('state', 'eq', 'on') | list | count }}"
        UnitOfMeasurement = $null; DeviceClass = $null; StateClass = $null
    },
    @{
        Name = "Doors Open Count"
        State = "{{ states.binary_sensor | selectattr('entity_id', 'match', 'binary_sensor.sonoff_') | selectattr('state', 'eq', 'on') | list | count }}"
        UnitOfMeasurement = $null; DeviceClass = $null; StateClass = $null
    }
)

# Check existing
$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$existingTemplates = @()
if ($existingEntries) {
    $existingTemplates = $existingEntries | Where-Object { $_.domain -eq "template" } | ForEach-Object { $_.title }
}

$created = 0
foreach ($sensor in $templateSensors) {
    if ($existingTemplates -contains $sensor.Name) {
        Write-Success "$($sensor.Name) already exists"
        continue
    }

    Write-Info "Creating: $($sensor.Name)..."
    $flowBody = @{ handler = "template" } | ConvertTo-Json
    $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody
    if (-not $flow) { Write-Fail "Could not start flow"; continue }

    $selectBody = @{ next_step_id = "sensor" } | ConvertTo-Json
    $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody $selectBody

    $sensorData = @{ name = $sensor.Name; state = $sensor.State }
    if ($sensor.UnitOfMeasurement) { $sensorData.unit_of_measurement = $sensor.UnitOfMeasurement }
    if ($sensor.DeviceClass) { $sensorData.device_class = $sensor.DeviceClass }
    if ($sensor.StateClass) { $sensorData.state_class = $sensor.StateClass }

    $result = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody ($sensorData | ConvertTo-Json)
    if ($result -and $result.type -eq "create_entry") {
        Write-Success "$($sensor.Name) created"
        $created++
    } else {
        Write-Fail "Failed: $($sensor.Name)"
    }
}
Write-Success "$created template sensors created"

# ============================================================
# Step 2: Home Overview Dashboard
# ============================================================

Write-Step "Step 2: Rebuilding Home Overview Dashboard"

$overviewConfig = @{
    title = "Home"
    views = @(
        @{
            title = "Overview"
            path  = "overview"
            icon  = "mdi:home"
            cards = @(
                # --- Energy Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type    = "custom:mushroom-template-card"
                            primary = "Energy"
                            secondary = "Solar: {{ states('sensor.solar_total_generation') }}W | Battery: {{ states('sensor.battery_soc') }}%"
                            icon    = "mdi:solar-power"
                            icon_color = "amber"
                            tap_action = @{ action = "navigate"; navigation_path = "/energy-dashboard" }
                        },
                        @{
                            type = "gauge"; entity = "sensor.battery_soc"; name = "Battery (40kWh)"
                            min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 }
                        },
                        @{
                            type = "grid"; columns = 2; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_generation"; name = "Solar"; icon = "mdi:solar-panel"; icon_color = "amber" },
                                @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_load"; name = "Load"; icon = "mdi:flash"; icon_color = "blue" }
                            )
                        }
                    )
                },
                # --- Security Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Security"
                            secondary = "Doors open: {{ states('sensor.doors_open_count') }}"
                            icon = "mdi:shield-home"
                            icon_color = "{{ 'red' if states('sensor.doors_open_count') | int > 0 else 'green' }}"
                            tap_action = @{ action = "navigate"; navigation_path = "/security-dashboard" }
                        },
                        @{ type = "custom:mushroom-entity-card"; entity = $sw.MainGate; name = "Main Gate"; icon = "mdi:gate" },
                        @{ type = "custom:mushroom-entity-card"; entity = $sw.VisitorGate; name = "Visitor Gate"; icon = "mdi:gate" }
                    )
                },
                # --- Climate Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Climate"
                            secondary = "Bed: {{ states('$($temp.MainBedTemp)') }}°C | Inverter: {{ states('$($temp.InverterRoomTemp)') }}°C"
                            icon = "mdi:thermometer"; icon_color = "teal"
                            tap_action = @{ action = "navigate"; navigation_path = "/water-climate-dashboard" }
                        },
                        @{ type = "custom:mushroom-entity-card"; entity = $sw.MainGeyser; name = "Main Geyser"; icon = "mdi:water-boiler" },
                        @{ type = "custom:mushroom-entity-card"; entity = $sw.FlatGeyser; name = "Flat Geyser"; icon = "mdi:water-boiler" },
                        @{
                            type = "grid"; columns = 2; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = $temp.InverterRoomTemp; name = "Inverter Room"; icon = "mdi:thermometer-alert" },
                                @{ type = "custom:mushroom-entity-card"; entity = $temp.InverterRoomHumidity; name = "Inverter Humidity"; icon = "mdi:water-percent" }
                            )
                        }
                    )
                },
                # --- Lighting Summary ---
                @{
                    type  = "vertical-stack"
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
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.LoungeLight; name = "Lounge"; icon = "mdi:lamp"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.KitchenLight; name = "Kitchen"; icon = "mdi:ceiling-light"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.MainBedLight; name = "Bedroom"; icon = "mdi:lamp"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.YardLights; name = "Yard"; icon = "mdi:outdoor-lamp"; tap_action = @{ action = "toggle" } }
                            )
                        }
                    )
                },
                # --- Water Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Water"
                            secondary = "Irrigation & Pumps"
                            icon = "mdi:water-pump"; icon_color = "blue"
                            tap_action = @{ action = "navigate"; navigation_path = "/water-climate-dashboard" }
                        },
                        @{ type = "custom:mushroom-entity-card"; entity = $sw.Borehole; name = "Borehole"; icon = "mdi:water-pump" },
                        @{ type = "custom:mushroom-entity-card"; entity = $sw.PoolPump; name = "Pool Pump"; icon = "mdi:pool" }
                    )
                },
                # --- Media Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type = "custom:mushroom-template-card"; primary = "Media"
                            secondary = "TV & Speakers"
                            icon = "mdi:speaker-multiple"; icon_color = "deep-purple"
                            tap_action = @{ action = "navigate"; navigation_path = "/media-dashboard" }
                        },
                        @{
                            type = "custom:mushroom-media-player-card"; entity = $media.SamsungTV; name = "Samsung TV"
                            use_media_info = $true; show_volume_level = $false; collapsible_controls = $true
                        }
                    )
                }
            )
        }
    )
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $overviewConfig }
if ($saveResp.success) { Write-Success "Overview dashboard saved" } else { Write-Fail "Overview: $($saveResp.error.message)" }

# ============================================================
# Step 3: Energy Dashboard
# ============================================================

Write-Step "Step 3: Rebuilding Energy Dashboard"

$energyConfig = @{
    title = "Energy"
    views = @(
        # --- Combined ---
        @{
            title = "Combined"; path = "combined"; icon = "mdi:solar-power-variant"
            cards = @(
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_generation"; name = "Solar"; icon = "mdi:solar-panel"; icon_color = "amber"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_battery_io"; name = "Battery"; icon = "mdi:battery-charging"; icon_color = "green"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_grid_io"; name = "Grid"; icon = "mdi:transmission-tower"; icon_color = "red"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_total_load"; name = "Load"; icon = "mdi:flash"; icon_color = "blue"; layout = "vertical" }
                    )
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_daily_production"; name = "Solar Today"; icon = "mdi:solar-power"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "sensor.solar_daily_load"; name = "Load Today"; icon = "mdi:home-lightning-bolt"; layout = "vertical" }
                    )
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "gauge"; entity = "${inv1}_instantaneous_battery_soc"; name = "Inverter 1 Battery"; min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 } },
                        @{ type = "gauge"; entity = "${inv2}_instantaneous_battery_soc"; name = "Inverter 2 Battery"; min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 } }
                    )
                },
                @{
                    type = "entities"; title = "Top Energy Consumers"
                    entities = @(
                        @{ entity = $sw.MainGeyser; name = "Main Geyser"; icon = "mdi:water-boiler"; secondary_info = "last-changed" },
                        @{ entity = $sw.PoolPump; name = "Pool Pump"; icon = "mdi:pool"; secondary_info = "last-changed" },
                        @{ entity = $sw.FlatGeyser; name = "Flat Geyser"; icon = "mdi:water-boiler"; secondary_info = "last-changed" },
                        @{ entity = $sw.Aircon; name = "Aircon"; icon = "mdi:air-conditioner"; secondary_info = "last-changed" }
                    )
                },
                @{
                    type = "entities"; title = "Energy Readings (Monthly)"
                    entities = @(
                        @{ entity = $pwr.MainGeyserEnergy; name = "Main Geyser"; icon = "mdi:water-boiler" },
                        @{ entity = $pwr.PoolPumpEnergy; name = "Pool Pump"; icon = "mdi:pool" },
                        @{ entity = $pwr.FlatGeyserEnergy; name = "Flat Geyser"; icon = "mdi:water-boiler" },
                        @{ entity = $pwr.AirconEnergy; name = "Aircon"; icon = "mdi:air-conditioner" }
                    )
                }
            )
        },
        # --- Inverter 1 ---
        @{
            title = "Inverter 1"; path = "inverter1"; icon = "mdi:numeric-1-box"
            cards = @(
                @{ type = "markdown"; content = "## Inverter 1 - S/N 2207207800`n8.8kW Inverter | 9kWp Solar | 4x5kWh = 20kWh Battery" },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_ppv1"; name = "PPV1"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_ppv2"; name = "PPV2"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv1}_instantaneous_generation"; name = "Total PV"; icon = "mdi:solar-power"; icon_color = "amber"; layout = "vertical" }
                    )
                },
                @{ type = "gauge"; entity = "${inv1}_instantaneous_battery_soc"; name = "Battery SOC"; min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 } },
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
        # --- Inverter 2 ---
        @{
            title = "Inverter 2"; path = "inverter2"; icon = "mdi:numeric-2-box"
            cards = @(
                @{ type = "markdown"; content = "## Inverter 2 - S/N 2305136364`n8.8kW Inverter | 9kWp Solar | 4x5kWh = 20kWh Battery" },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_ppv1"; name = "PPV1"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_ppv2"; name = "PPV2"; icon = "mdi:solar-panel"; layout = "vertical" },
                        @{ type = "custom:mushroom-entity-card"; entity = "${inv2}_instantaneous_generation"; name = "Total PV"; icon = "mdi:solar-power"; icon_color = "amber"; layout = "vertical" }
                    )
                },
                @{ type = "gauge"; entity = "${inv2}_instantaneous_battery_soc"; name = "Battery SOC"; min = 0; max = 100; severity = @{ green = 50; yellow = 20; red = 0 } },
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

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $energyConfig; url_path = "energy-dashboard" }
if ($saveResp.success) { Write-Success "Energy dashboard saved" } else { Write-Fail "Energy: $($saveResp.error.message)" }

# ============================================================
# Step 4: Lighting Dashboard
# ============================================================

Write-Step "Step 4: Rebuilding Lighting Dashboard"

function New-LightCard($entity, $name, $icon = "mdi:ceiling-light") {
    return @{ type = "custom:mushroom-entity-card"; entity = $entity; name = $name; icon = $icon; tap_action = @{ action = "toggle" } }
}

$lightingConfig = @{
    title = "Lighting"
    views = @(
        @{
            title = "All Rooms"; path = "rooms"; icon = "mdi:lightbulb-group"
            cards = @(
                @{
                    type = "custom:mushroom-template-card"; primary = "Lighting"
                    secondary = "{{ states('sensor.lights_on_count') }} lights currently on"
                    icon = "mdi:lightbulb-group"; icon_color = "amber"
                },
                # Living Areas
                @{
                    type = "vertical-stack"; title = "Living Areas"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            (New-LightCard $sw.LoungeLight "Lounge Lights" "mdi:lamp"),
                            (New-LightCard $sw.LoungeMood "Lounge Mood" "mdi:lamp"),
                            (New-LightCard $sw.KitchenLight "Kitchen Lights"),
                            (New-LightCard $sw.KitchenSwitch "Kitchen Switch"),
                            (New-LightCard $sw.DiningLight1 "Dining Lights 1" "mdi:chandelier"),
                            (New-LightCard $sw.DiningLight2 "Dining Lights 2" "mdi:chandelier"),
                            (New-LightCard $sw.BarLights "Bar Lights" "mdi:glass-cocktail"),
                            (New-LightCard $sw.BarFan "Bar Fan" "mdi:fan"),
                            (New-LightCard $sw.HallwayLights "Hallway"),
                            (New-LightCard $sw.TVLights "TV Lights" "mdi:television-ambient-light"),
                            (New-LightCard $sw.PlayAreaLights "Play Area")
                        )
                    })
                },
                # Bedrooms
                @{
                    type = "vertical-stack"; title = "Bedrooms"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            (New-LightCard $sw.MainBedLight "Main Bedroom" "mdi:lamp"),
                            (New-LightCard $sw.WardrobeLights "Wardrobe"),
                            (New-LightCard $sw.BabyRoomLights "Baby Room" "mdi:baby-face-outline"),
                            (New-LightCard $sw.GuestRoomLights "Guest Room" "mdi:bed")
                        )
                    })
                },
                # Utility
                @{
                    type = "vertical-stack"; title = "Utility"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            (New-LightCard $sw.LaundryLight "Laundry" "mdi:washing-machine"),
                            (New-LightCard $sw.SculleryLight "Scullery"),
                            (New-LightCard $sw.GarageLight "Garage" "mdi:garage"),
                            (New-LightCard $sw.WorkshopLights "Workshop" "mdi:tools"),
                            (New-LightCard $sw.WineCellarLight "Wine Cellar" "mdi:glass-wine"),
                            (New-LightCard $sw.GuestBathLight "Guest Bathroom" "mdi:shower"),
                            (New-LightCard $sw.BabyBathroomLight "Baby Bathroom" "mdi:shower")
                        )
                    })
                },
                # Outdoor
                @{
                    type = "vertical-stack"; title = "Outdoor"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            (New-LightCard $sw.FrontPorchLight "Front Porch" "mdi:outdoor-lamp"),
                            (New-LightCard $sw.CourtyardLight "Courtyard" "mdi:outdoor-lamp"),
                            (New-LightCard $sw.YardLights "Yard" "mdi:outdoor-lamp"),
                            (New-LightCard $sw.BackdoorLights "Backdoor" "mdi:door"),
                            (New-LightCard $sw.PoolLights "Pool Lights" "mdi:pool"),
                            (New-LightCard $sw.ReceptionLights "Reception" "mdi:desk-lamp"),
                            (New-LightCard $sw.VisitorGateLights "Visitor Gate Lights" "mdi:gate")
                        )
                    })
                },
                # Airbnb
                @{
                    type = "vertical-stack"; title = "Airbnb"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            (New-LightCard $sw.AirbnbBedLights "Bed Lights" "mdi:bed"),
                            (New-LightCard $sw.AirbnbTVLights "TV Lights" "mdi:television"),
                            (New-LightCard $sw.AirbnbBathLights "Bathroom Lights" "mdi:shower"),
                            (New-LightCard $sw.AirbnbBathFan "Bathroom Fan" "mdi:fan"),
                            (New-LightCard $sw.AirbnbTowelRack "Towel Rack" "mdi:towel-rail")
                        )
                    })
                }
            )
        }
    )
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $lightingConfig; url_path = "lighting-dashboard" }
if ($saveResp.success) { Write-Success "Lighting dashboard saved" } else { Write-Fail "Lighting: $($saveResp.error.message)" }

# ============================================================
# Step 5: Security Dashboard
# ============================================================

Write-Step "Step 5: Rebuilding Security Dashboard"

# Build door entities list
$doorEntities = $doors | ForEach-Object { @{ entity = $_.Entity; name = $_.Name; icon = "mdi:door" } }
$motionEntities = $motion | ForEach-Object { @{ entity = $_.Entity; name = $_.Name; icon = "mdi:motion-sensor" } }

$securityConfig = @{
    title = "Security"
    views = @(
        @{
            title = "Security"; path = "security"; icon = "mdi:shield-home"
            cards = @(
                @{
                    type = "custom:mushroom-template-card"; primary = "Security Status"
                    secondary = "{{ states('sensor.doors_open_count') }} doors open"
                    icon = "mdi:shield-home"
                    icon_color = "{{ 'red' if states('sensor.doors_open_count') | int > 0 else 'green' }}"
                },
                @{ type = "entities"; title = "Door Sensors"; entities = $doorEntities },
                @{
                    type = "vertical-stack"; title = "Gates"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            @{ type = "custom:mushroom-entity-card"; entity = $sw.MainGate; name = "Main Gate"; icon = "mdi:gate"; tap_action = @{ action = "toggle" } },
                            @{ type = "custom:mushroom-entity-card"; entity = $sw.VisitorGate; name = "Visitor Gate"; icon = "mdi:gate"; tap_action = @{ action = "toggle" } }
                        )
                    })
                },
                @{ type = "entities"; title = "Motion Sensors"; entities = $motionEntities },
                @{
                    type = "vertical-stack"; title = "Alarm System"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            @{ type = "custom:mushroom-entity-card"; entity = $sw.AlarmMagnets; name = "Alarm Magnets"; icon = "mdi:alarm-light"; icon_color = "red"; tap_action = @{ action = "toggle" } },
                            @{ type = "custom:mushroom-entity-card"; entity = $sw.AlarmMotion; name = "Alarm Motion"; icon = "mdi:alarm-light"; icon_color = "red"; tap_action = @{ action = "toggle" } }
                        )
                    })
                },
                @{
                    type = "markdown"
                    content = "### Unavailable Devices`nMany sensors are offline (battery or range issues):`n- Alarm Motion Trigger`n- Tank Pump`n- Multiple door/motion sensors`n`nCheck **Settings > Devices** for connectivity status."
                }
            )
        }
    )
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $securityConfig; url_path = "security-dashboard" }
if ($saveResp.success) { Write-Success "Security dashboard saved" } else { Write-Fail "Security: $($saveResp.error.message)" }

# ============================================================
# Step 6: Water & Climate Dashboard
# ============================================================

Write-Step "Step 6: Rebuilding Water & Climate Dashboard"

$waterClimateConfig = @{
    title = "Water & Climate"
    views = @(
        @{
            title = "Water & Climate"; path = "water-climate"; icon = "mdi:water-thermometer"
            cards = @(
                # Geysers
                @{
                    type = "vertical-stack"; title = "Geysers"
                    cards = @(
                        @{
                            type = "grid"; columns = 3; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.MainGeyser; name = "Main Geyser"; icon = "mdi:water-boiler"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.FlatGeyser; name = "Flat Geyser"; icon = "mdi:water-boiler"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.GuestGeyser; name = "Guest Geyser"; icon = "mdi:water-boiler"; tap_action = @{ action = "toggle" } }
                            )
                        },
                        @{
                            type = "entities"; title = "Geyser Power"
                            entities = @(
                                @{ entity = $pwr.MainGeyserPower; name = "Main Geyser Power"; icon = "mdi:flash" },
                                @{ entity = $pwr.MainGeyserEDay; name = "Main Geyser Today"; icon = "mdi:counter" },
                                @{ entity = $pwr.MainGeyserEnergy; name = "Main Geyser Month"; icon = "mdi:counter" },
                                @{ entity = $pwr.FlatGeyserPower; name = "Flat Geyser Power"; icon = "mdi:flash" },
                                @{ entity = $pwr.FlatGeyserEDay; name = "Flat Geyser Today"; icon = "mdi:counter" },
                                @{ entity = $pwr.FlatGeyserEnergy; name = "Flat Geyser Month"; icon = "mdi:counter" },
                                @{ entity = $pwr.GuestGeyserPower; name = "Guest Geyser Power"; icon = "mdi:flash" }
                            )
                        }
                    )
                },
                # Irrigation
                @{
                    type = "vertical-stack"; title = "Irrigation"
                    cards = @(
                        @{
                            type = "grid"; columns = 2; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.HosePipe; name = "Hose Pipe"; icon = "mdi:water"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.VegGarden; name = "Vegetable Garden"; icon = "mdi:sprinkler-variant"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.ShedGarden; name = "Shed Garden"; icon = "mdi:sprinkler-variant"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.BufferTank; name = "Buffer Tank"; icon = "mdi:water-pump"; tap_action = @{ action = "toggle" } }
                            )
                        },
                        @{
                            type = "entities"; title = "Water Usage"
                            entities = @(
                                @{ entity = $water.HosePipe; name = "Hose Pipe"; icon = "mdi:water" },
                                @{ entity = $water.VegGarden; name = "Vegetable Garden"; icon = "mdi:water" },
                                @{ entity = $water.ShedGarden; name = "Shed Garden"; icon = "mdi:water" },
                                @{ entity = $water.BufferTank; name = "Buffer Tank"; icon = "mdi:water" }
                            )
                        }
                    )
                },
                # Pumps
                @{
                    type = "vertical-stack"; title = "Pumps"
                    cards = @(
                        @{
                            type = "grid"; columns = 3; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.Borehole; name = "Borehole"; icon = "mdi:water-pump"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.PoolPump; name = "Pool Pump"; icon = "mdi:pool"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = $sw.TankPump; name = "Tank Pump"; icon = "mdi:water-pump"; tap_action = @{ action = "toggle" } }
                            )
                        },
                        @{
                            type = "entities"; title = "Pool Pump Power"
                            entities = @(
                                @{ entity = $pwr.PoolPumpPower; name = "Current Power"; icon = "mdi:flash" },
                                @{ entity = $pwr.PoolPumpEDay; name = "Today"; icon = "mdi:counter" },
                                @{ entity = $pwr.PoolPumpEnergy; name = "This Month"; icon = "mdi:counter" }
                            )
                        }
                    )
                },
                # Climate
                @{
                    type = "vertical-stack"; title = "Climate"
                    cards = @(
                        @{
                            type = "grid"; columns = 2; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = $temp.MainBedTemp; name = "Main Bedroom Temp"; icon = "mdi:thermometer" },
                                @{ type = "custom:mushroom-entity-card"; entity = $temp.MainBedHumidity; name = "Main Bedroom Humidity"; icon = "mdi:water-percent" }
                            )
                        },
                        @{
                            type = "grid"; columns = 2; square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = $temp.InverterRoomTemp; name = "Inverter Room Temp"; icon = "mdi:thermometer-alert" },
                                @{ type = "custom:mushroom-entity-card"; entity = $temp.InverterRoomHumidity; name = "Inverter Room Humidity"; icon = "mdi:water-percent" }
                            )
                        },
                        @{ type = "custom:mushroom-entity-card"; entity = $sw.Aircon; name = "Living Room Aircon"; icon = "mdi:air-conditioner"; tap_action = @{ action = "toggle" } },
                        @{ type = "weather-forecast"; entity = "weather.forecast_home"; show_forecast = $true }
                    )
                },
                # Pool
                @{
                    type = "vertical-stack"; title = "Pool"
                    cards = @(@{
                        type = "grid"; columns = 2; square = $false
                        cards = @(
                            @{ type = "custom:mushroom-entity-card"; entity = $sw.PoolLights; name = "Pool Lights"; icon = "mdi:pool"; tap_action = @{ action = "toggle" } },
                            @{ type = "custom:mushroom-entity-card"; entity = $sw.PoolPump; name = "Pool Pump"; icon = "mdi:pump"; tap_action = @{ action = "toggle" } }
                        )
                    })
                }
            )
        }
    )
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $waterClimateConfig; url_path = "water-climate-dashboard" }
if ($saveResp.success) { Write-Success "Water & Climate dashboard saved" } else { Write-Fail "Water & Climate: $($saveResp.error.message)" }

# ============================================================
# Step 7: Media Dashboard
# ============================================================

Write-Step "Step 7: Rebuilding Media Dashboard"

$mediaConfig = @{
    title = "Media"
    views = @(
        @{
            title = "Media"; path = "media"; icon = "mdi:speaker-multiple"
            cards = @(
                @{
                    type = "vertical-stack"; title = "Samsung TV"
                    cards = @(
                        @{ type = "media-control"; entity = $media.SamsungTV }
                    )
                },
                @{
                    type = "vertical-stack"; title = "Living Area Speakers"
                    cards = @(
                        @{ type = "custom:mini-media-player"; entity = $media.Kitchen; name = "Kitchen"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } },
                        @{ type = "custom:mini-media-player"; entity = $media.DiningRoom; name = "Dining Room"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } },
                        @{ type = "custom:mini-media-player"; entity = $media.FrontHome; name = "Front Home"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } },
                        @{ type = "custom:mini-media-player"; entity = $media.Study; name = "Study"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } }
                    )
                },
                @{
                    type = "vertical-stack"; title = "Bedroom Speakers"
                    cards = @(
                        @{ type = "custom:mini-media-player"; entity = $media.Bedroom; name = "Bedroom"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } },
                        @{ type = "custom:mini-media-player"; entity = $media.BabyRoom; name = "Baby Room"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } },
                        @{ type = "custom:mini-media-player"; entity = $media.GuestRoom; name = "Guest Room"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } }
                    )
                },
                @{
                    type = "vertical-stack"; title = "Other"
                    cards = @(
                        @{ type = "custom:mini-media-player"; entity = $media.Airbnb; name = "Airbnb"; icon = "mdi:speaker"; group = $true; hide = @{ power = $true } },
                        @{ type = "custom:mini-media-player"; entity = $media.HomeGroup; name = "All Speakers"; icon = "mdi:speaker-multiple"; group = $true; hide = @{ power = $true } },
                        @{ type = "custom:mini-media-player"; entity = $media.TVChromecast; name = "TV Chromecast"; icon = "mdi:cast"; group = $true; hide = @{ power = $true } }
                    )
                }
            )
        }
    )
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $mediaConfig; url_path = "media-dashboard" }
if ($saveResp.success) { Write-Success "Media dashboard saved" } else { Write-Fail "Media: $($saveResp.error.message)" }

# ============================================================
# Done
# ============================================================

Write-Step "All Dashboards Rebuilt!"
Write-Host ""
Write-Host "  All entity IDs have been updated to match actual HA entities." -ForegroundColor Green
Write-Host "  Refresh your browser to see the changes." -ForegroundColor Cyan
Write-Host ""

Disconnect-HAWS
