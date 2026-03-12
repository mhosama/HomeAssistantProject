<#
.SYNOPSIS
    Create Home Assistant dashboards via the Lovelace WebSocket API.

.DESCRIPTION
    Sets up:
    - HACS frontend cards (Mushroom, Mini Media Player)
    - Template sensors for combined inverter data (via Samba)
    - 6 dashboards: Overview, Energy, Lighting, Security, Water/Climate, Media

    Run AFTER integrations are working (03-Setup-Integrations.ps1).

.EXAMPLE
    .\04-Setup-Dashboards.ps1
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
# WebSocket API helpers (same pattern as 02-Setup-Addons.ps1)
# ============================================================

$script:ws = $null
$script:cts = $null
$script:wsId = 0

function Connect-HAWS {
    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $script:cts.CancelAfter(300000)  # 5 min global timeout
    $script:wsId = 0

    $uri = [Uri]"ws://$($Config.HA_IP):8123/api/websocket"
    Write-Info "Connecting to WebSocket at $uri..."
    $script:ws.ConnectAsync($uri, $script:cts.Token).Wait()

    # Receive auth_required
    $null = Receive-HAWS

    # Authenticate
    $authMsg = @{type = "auth"; access_token = $Config.HA_TOKEN} | ConvertTo-Json -Compress
    Send-HAWS $authMsg
    $authResp = Receive-HAWS | ConvertFrom-Json

    if ($authResp.type -ne "auth_ok") {
        Write-Fail "WebSocket authentication failed: $($authResp | ConvertTo-Json -Compress)"
        exit 1
    }
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
    param(
        [string]$Type,
        [hashtable]$Extra = @{}
    )
    $script:wsId++
    $msg = @{ id = $script:wsId; type = $Type } + $Extra
    Send-HAWS ($msg | ConvertTo-Json -Depth 20 -Compress)
    $resp = Receive-HAWS | ConvertFrom-Json
    return $resp
}

function Invoke-Supervisor {
    param(
        [string]$Endpoint,
        [string]$Method = "get",
        [hashtable]$Data = $null
    )
    $extra = @{ endpoint = $Endpoint; method = $Method }
    if ($Data) { $extra.data = $Data }
    return Invoke-WSCommand -Type "supervisor/api" -Extra $extra
}

function Disconnect-HAWS {
    if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $script:ws.CloseAsync(
            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "",
            $script:cts.Token
        ).Wait()
    }
}

# ============================================================
# REST API helper
# ============================================================

function Invoke-HAREST {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [string]$JsonBody = $null
    )
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $headers = @{
        "Authorization" = "Bearer $($Config.HA_TOKEN)"
        "Content-Type"  = "application/json"
    }
    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $true
        TimeoutSec      = 30
    }
    if ($JsonBody) { $params.Body = $JsonBody }

    try {
        return Invoke-RestMethod @params
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Fail "REST $Method $Endpoint -> HTTP $status : $($_.Exception.Message)"
        return $null
    }
}

# ============================================================
# Connect
# ============================================================

Write-Step "Connecting to Home Assistant"
Connect-HAWS

# ============================================================
# Step 0: Install HACS Frontend Cards
# ============================================================

Write-Step "Step 0: Install HACS Frontend Cards"

# First, get the HACS repository list to find numeric IDs
Write-Info "Fetching HACS repository list..."
$script:wsId++
$listMsg = @{ id = $script:wsId; type = "hacs/repositories/list" } | ConvertTo-Json -Compress
Send-HAWS $listMsg
$hacsListResp = Receive-HAWS | ConvertFrom-Json

$hacsCards = @(
    @{ FullName = "piitaya/lovelace-mushroom"; Name = "Mushroom Cards" },
    @{ FullName = "kalkih/mini-media-player";  Name = "Mini Media Player" }
)

if ($hacsListResp.success) {
    foreach ($card in $hacsCards) {
        $repo = $hacsListResp.result | Where-Object { $_.full_name -eq $card.FullName }

        if (-not $repo) {
            Write-Fail "$($card.Name) not found in HACS repository list"
            continue
        }

        if ($repo.installed) {
            Write-Success "$($card.Name) already installed (id: $($repo.id))"
            continue
        }

        Write-Info "Downloading $($card.Name) (id: $($repo.id))..."
        $script:wsId++
        $dlMsg = @{
            id         = $script:wsId
            type       = "hacs/repository/download"
            repository = $repo.id
        } | ConvertTo-Json -Compress
        Send-HAWS $dlMsg
        $dlResp = Receive-HAWS | ConvertFrom-Json

        if ($dlResp.success -eq $true) {
            Write-Success "$($card.Name) downloaded"
        } else {
            Write-Info "$($card.Name) download failed: $($dlResp.error.message)"
        }
    }
} else {
    Write-Fail "Could not fetch HACS repositories: $($hacsListResp.error.message)"
    Write-Info "Install Mushroom and Mini Media Player manually via HACS UI"
}

Write-Info "Waiting for HACS resources to register..."
Start-Sleep -Seconds 5

# ============================================================
# Step 1: Template Sensors (via Samba share)
# ============================================================

Write-Step "Step 1: Template Sensors for Combined Inverter Data"

# Create template sensors via the HA config flow API (no file editing needed)
# Each sensor gets its own config entry - clean and reliable

$inv1Prefix = "sensor.sunsynk_320152_2207207800"
$inv2Prefix = "sensor.sunsynk_320152_2305136364"

$templateSensors = @(
    @{
        Name             = "Solar Total Generation"
        State            = "{{ states('${inv1Prefix}_instantaneous_generation') | float(0) + states('${inv2Prefix}_instantaneous_generation') | float(0) }}"
        UnitOfMeasurement = "W"
        DeviceClass      = "power"
        StateClass       = "measurement"
    },
    @{
        Name             = "Solar Total Load"
        State            = "{{ states('${inv1Prefix}_instantaneous_load') | float(0) + states('${inv2Prefix}_instantaneous_load') | float(0) }}"
        UnitOfMeasurement = "W"
        DeviceClass      = "power"
        StateClass       = "measurement"
    },
    @{
        Name             = "Solar Total Battery IO"
        State            = "{{ states('${inv1Prefix}_instantaneous_battery_i_o') | float(0) + states('${inv2Prefix}_instantaneous_battery_i_o') | float(0) }}"
        UnitOfMeasurement = "W"
        DeviceClass      = "power"
        StateClass       = "measurement"
    },
    @{
        Name             = "Solar Total Grid IO"
        State            = "{{ states('${inv1Prefix}_instantaneous_grid_i_o_total') | float(0) + states('${inv2Prefix}_instantaneous_grid_i_o_total') | float(0) }}"
        UnitOfMeasurement = "W"
        DeviceClass      = "power"
        StateClass       = "measurement"
    },
    @{
        Name             = "Solar Daily Production"
        State            = "{{ states('${inv1Prefix}_solar_production') | float(0) + states('${inv2Prefix}_solar_production') | float(0) }}"
        UnitOfMeasurement = "kWh"
        DeviceClass      = "energy"
        StateClass       = "total_increasing"
    },
    @{
        Name             = "Solar Battery SOC Average"
        State            = "{{ ((states('${inv1Prefix}_instantaneous_battery_soc') | float(0) + states('${inv2Prefix}_instantaneous_battery_soc') | float(0)) / 2) | round(0) }}"
        UnitOfMeasurement = "%"
        DeviceClass      = "battery"
        StateClass       = $null
    },
    @{
        Name             = "Solar Daily Load"
        State            = "{{ states('${inv1Prefix}_total_load') | float(0) + states('${inv2Prefix}_total_load') | float(0) }}"
        UnitOfMeasurement = "kWh"
        DeviceClass      = "energy"
        StateClass       = "total_increasing"
    },
    @{
        Name             = "Lights On Count"
        State            = "{{ states.switch | selectattr('entity_id', 'match', 'switch.sonoff_') | selectattr('attributes.friendly_name', 'match', '(?i)(light|lamp|mood)') | selectattr('state', 'eq', 'on') | list | count }}"
        UnitOfMeasurement = $null
        DeviceClass      = $null
        StateClass       = $null
    },
    @{
        Name             = "Doors Open Count"
        State            = "{{ states.binary_sensor | selectattr('attributes.device_class', 'eq', 'door') | selectattr('state', 'eq', 'on') | list | count }}"
        UnitOfMeasurement = $null
        DeviceClass      = $null
        StateClass       = $null
    }
)

# Check which template sensors already exist
$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$existingTemplates = @()
if ($existingEntries) {
    $existingTemplates = $existingEntries | Where-Object { $_.domain -eq "template" } | ForEach-Object { $_.title }
}

$created = 0
$skipped = 0

foreach ($sensor in $templateSensors) {
    if ($existingTemplates -contains $sensor.Name) {
        Write-Success "$($sensor.Name) already exists - skipping"
        $skipped++
        continue
    }

    Write-Info "Creating: $($sensor.Name)..."

    # Step 1: Start config flow
    $flowBody = @{ handler = "template" } | ConvertTo-Json
    $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody
    if (-not $flow -or -not $flow.flow_id) {
        Write-Fail "Could not start config flow for $($sensor.Name)"
        continue
    }

    # Step 2: Select "sensor" type
    $selectBody = @{ next_step_id = "sensor" } | ConvertTo-Json
    $step2 = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody $selectBody
    if (-not $step2 -or $step2.step_id -ne "sensor") {
        Write-Fail "Could not select sensor type for $($sensor.Name)"
        try { Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "DELETE" | Out-Null } catch {}
        continue
    }

    # Step 3: Fill in sensor details
    $sensorData = @{
        name  = $sensor.Name
        state = $sensor.State
    }
    if ($sensor.UnitOfMeasurement) { $sensorData.unit_of_measurement = $sensor.UnitOfMeasurement }
    if ($sensor.DeviceClass)       { $sensorData.device_class = $sensor.DeviceClass }
    if ($sensor.StateClass)        { $sensorData.state_class = $sensor.StateClass }

    $sensorJson = $sensorData | ConvertTo-Json
    $result = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody $sensorJson

    if ($result -and $result.type -eq "create_entry") {
        Write-Success "$($sensor.Name) created"
        $created++
    } else {
        Write-Fail "Failed to create $($sensor.Name): $($result | ConvertTo-Json -Compress)"
    }
}

Write-Success "Template sensors: $created created, $skipped already existed"

# No restart needed - config flow template sensors load immediately

# ============================================================
# Dashboard YAML definitions
# ============================================================

# Entity ID prefixes for readability
$inv1 = "sensor.sunsynk_320152_2207207800"
$inv2 = "sensor.sunsynk_320152_2305136364"

# ============================================================
# Helper: Save a Lovelace dashboard
# ============================================================

function Save-Dashboard {
    param(
        [string]$UrlPath,
        [string]$Title,
        [string]$Icon,
        [hashtable]$DashConfig
    )

    Write-Info "Creating dashboard: $Title ($UrlPath)..."

    # List existing dashboards via WebSocket
    $listResp = Invoke-WSCommand -Type "lovelace/dashboards/list"

    $exists = $false
    if ($listResp.success -and $listResp.result) {
        foreach ($d in $listResp.result) {
            if ($d.url_path -eq $UrlPath) {
                $exists = $true
                break
            }
        }
    }

    if (-not $exists -and $UrlPath) {
        # Create the dashboard entry via WebSocket
        $createResp = Invoke-WSCommand -Type "lovelace/dashboards/create" -Extra @{
            url_path        = $UrlPath
            title           = $Title
            icon            = $Icon
            require_admin   = $false
            show_in_sidebar = $true
        }
        if ($createResp.success) {
            Write-Success "Dashboard '$Title' created in sidebar"
        } else {
            Write-Fail "Failed to create dashboard '$Title': $($createResp.error.message)"
        }
    } else {
        Write-Info "Dashboard '$Title' already exists"
    }

    # Save the lovelace config via WebSocket
    $saveExtra = @{ config = $DashConfig }
    if ($UrlPath) { $saveExtra.url_path = $UrlPath }
    $saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra $saveExtra

    if ($saveResp.success) {
        Write-Success "Dashboard '$Title' config saved"
    } else {
        Write-Fail "Failed to save dashboard '$Title' config: $($saveResp.error.message)"
    }
}

# ============================================================
# Step 2: Home Overview Dashboard (default)
# ============================================================

Write-Step "Step 2: Home Overview Dashboard"

$overviewConfig = @{
    title = "Home"
    views = @(
        @{
            title = "Overview"
            path  = "overview"
            icon  = "mdi:home"
            type  = "sections"
            max_columns = 3
            cards = @(
                # --- Energy Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type    = "custom:mushroom-template-card"
                            primary = "Energy"
                            secondary = "Solar: {{ states('sensor.solar_total_generation') }}W | Battery: {{ states('sensor.solar_battery_soc_average') }}%"
                            icon    = "mdi:solar-power"
                            icon_color = "amber"
                            tap_action = @{
                                action          = "navigate"
                                navigation_path = "/energy-dashboard"
                            }
                        },
                        @{
                            type     = "gauge"
                            entity   = "sensor.solar_battery_soc_average"
                            name     = "Battery"
                            min      = 0
                            max      = 100
                            severity = @{
                                green  = 50
                                yellow = 20
                                red    = 0
                            }
                        },
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "sensor.solar_total_generation"
                                    name   = "Solar"
                                    icon   = "mdi:solar-panel"
                                    icon_color = "amber"
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "sensor.solar_total_load"
                                    name   = "Load"
                                    icon   = "mdi:flash"
                                    icon_color = "blue"
                                }
                            )
                        }
                    )
                },
                # --- Security Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type    = "custom:mushroom-template-card"
                            primary = "Security"
                            secondary = "Doors open: {{ states('sensor.doors_open_count') }}"
                            icon    = "mdi:shield-home"
                            icon_color = "{{ 'red' if states('sensor.doors_open_count') | int > 0 else 'green' }}"
                            tap_action = @{
                                action          = "navigate"
                                navigation_path = "/security-dashboard"
                            }
                        },
                        @{
                            type     = "custom:mushroom-entity-card"
                            entity   = "switch.sonoff_1000f74d0c"
                            name     = "Main Gate"
                            icon     = "mdi:gate"
                        },
                        @{
                            type     = "custom:mushroom-entity-card"
                            entity   = "switch.sonoff_10014e3e9b"
                            name     = "Visitor Gate"
                            icon     = "mdi:gate"
                        }
                    )
                },
                # --- Climate Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type    = "custom:mushroom-template-card"
                            primary = "Climate"
                            secondary = "{{ states('sensor.sonoff_th_main_bedroom_temperature') }}C | {{ states('sensor.sonoff_th_main_bedroom_humidity') }}%"
                            icon    = "mdi:thermometer"
                            icon_color = "teal"
                            tap_action = @{
                                action          = "navigate"
                                navigation_path = "/water-climate-dashboard"
                            }
                        },
                        @{
                            type     = "custom:mushroom-entity-card"
                            entity   = "switch.sonoff_100168f6d9"
                            name     = "Main Geyser"
                            icon     = "mdi:water-boiler"
                        },
                        @{
                            type     = "custom:mushroom-entity-card"
                            entity   = "switch.sonoff_10016b7e5c"
                            name     = "Flat Geyser"
                            icon     = "mdi:water-boiler"
                        }
                    )
                },
                # --- Lighting Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type    = "custom:mushroom-template-card"
                            primary = "Lighting"
                            secondary = "{{ states('sensor.lights_on_count') }} lights on"
                            icon    = "mdi:lightbulb-group"
                            icon_color = "yellow"
                            tap_action = @{
                                action          = "navigate"
                                navigation_path = "/lighting-dashboard"
                            }
                        },
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e4e53f"
                                    name   = "Lounge"
                                    icon   = "mdi:lamp"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000f7cd0d"
                                    name   = "Kitchen"
                                    icon   = "mdi:ceiling-light"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e95e4a"
                                    name   = "Bedroom"
                                    icon   = "mdi:lamp"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e4bac4"
                                    name   = "Yard"
                                    icon   = "mdi:outdoor-lamp"
                                    tap_action = @{ action = "toggle" }
                                }
                            )
                        }
                    )
                },
                # --- Water Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type    = "custom:mushroom-template-card"
                            primary = "Water"
                            secondary = "Irrigation & Pumps"
                            icon    = "mdi:water-pump"
                            icon_color = "blue"
                            tap_action = @{
                                action          = "navigate"
                                navigation_path = "/water-climate-dashboard"
                            }
                        },
                        @{
                            type     = "custom:mushroom-entity-card"
                            entity   = "switch.sonoff_1001604abd"
                            name     = "Borehole"
                            icon     = "mdi:water-pump"
                        },
                        @{
                            type     = "custom:mushroom-entity-card"
                            entity   = "switch.sonoff_100168e932"
                            name     = "Pool Pump"
                            icon     = "mdi:pool"
                        }
                    )
                },
                # --- Media Summary ---
                @{
                    type  = "vertical-stack"
                    cards = @(
                        @{
                            type    = "custom:mushroom-template-card"
                            primary = "Media"
                            secondary = "TV & Speakers"
                            icon    = "mdi:speaker-multiple"
                            icon_color = "deep-purple"
                            tap_action = @{
                                action          = "navigate"
                                navigation_path = "/media-dashboard"
                            }
                        },
                        @{
                            type   = "custom:mushroom-media-player-card"
                            entity = "media_player.samsung_qa65q70bakxxa"
                            name   = "Samsung TV"
                            use_media_info      = $true
                            show_volume_level    = $false
                            collapsible_controls = $true
                        }
                    )
                }
            )
        }
    )
}

# Save as the default dashboard via WebSocket
$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $overviewConfig }
if ($saveResp.success) {
    Write-Success "Overview dashboard saved as default"
} else {
    Write-Fail "Failed to save overview: $($saveResp.error.message)"
}

# ============================================================
# Step 3: Energy Dashboard
# ============================================================

Write-Step "Step 3: Energy Dashboard"

$energyConfig = @{
    title = "Energy"
    views = @(
        # --- Tab 1: Combined Overview ---
        @{
            title = "Combined"
            path  = "combined"
            icon  = "mdi:solar-power-variant"
            cards = @(
                # Power Flow Card
                @{
                    type = "custom:sunsynk-power-flow-card"
                    cardstyle = "full"
                    show_solar = $true
                    show_battery = $true
                    show_grid = $true
                    battery = @{
                        energy  = 40000
                        shutdown_soc = 20
                        show_daily = $true
                    }
                    solar = @{
                        show_daily = $true
                        mppts = 2
                    }
                    load = @{
                        show_daily = $true
                    }
                    grid = @{
                        show_daily_buy = $true
                        show_daily_sell = $true
                    }
                    entities = @{
                        inverter_voltage_154      = "none"
                        load_frequency_192        = "none"
                        inverter_current_164      = "none"
                        inverter_power_175        = "none"
                        grid_connected_status_194 = "none"
                        inverter_status_59        = "none"
                        day_battery_charge_70     = "${inv1}_battery_charge"
                        day_battery_discharge_71  = "${inv1}_battery_discharge"
                        battery_voltage_183       = "${inv1}_instantaneous_battery_voltage"
                        battery_soc_184           = "sensor.solar_battery_soc_average"
                        battery_power_190         = "sensor.solar_total_battery_io"
                        battery_current_191       = "none"
                        grid_power_169            = "sensor.solar_total_grid_io"
                        day_grid_import_76        = "${inv1}_grid_import"
                        day_grid_export_77        = "${inv1}_grid_export"
                        grid_ct_power_172         = "sensor.solar_total_grid_io"
                        day_load_energy_84        = "sensor.solar_daily_load"
                        essential_power           = "sensor.solar_total_load"
                        nonessential_power        = "none"
                        day_pv_energy_108         = "sensor.solar_daily_production"
                        pv1_power_186             = "${inv1}_pv1_power"
                        pv2_power_187             = "${inv1}_pv2_power"
                        pv1_voltage_109           = "none"
                        pv1_current_110           = "none"
                        pv2_voltage_111           = "none"
                        pv2_current_112           = "none"
                        solar_sell_247            = "none"
                        pv3_power_188             = "${inv2}_pv1_power"
                        pv4_power_189             = "${inv2}_pv2_power"
                    }
                },
                # Stats row
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.solar_total_generation"
                            name   = "Solar"
                            icon   = "mdi:solar-panel"
                            icon_color = "amber"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.solar_total_battery_io"
                            name   = "Battery"
                            icon   = "mdi:battery-charging"
                            icon_color = "green"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.solar_total_grid_io"
                            name   = "Grid"
                            icon   = "mdi:transmission-tower"
                            icon_color = "red"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.solar_total_load"
                            name   = "Load"
                            icon   = "mdi:flash"
                            icon_color = "blue"
                            layout = "vertical"
                        }
                    )
                },
                # Daily totals
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.solar_daily_production"
                            name   = "Solar Today"
                            icon   = "mdi:solar-power"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "sensor.solar_daily_load"
                            name   = "Load Today"
                            icon   = "mdi:home-lightning-bolt"
                            layout = "vertical"
                        }
                    )
                },
                # Battery gauges
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "gauge"
                            entity = "${inv1}_instantaneous_battery_soc"
                            name   = "Inverter 1 Battery"
                            min    = 0
                            max    = 100
                            severity = @{ green = 50; yellow = 20; red = 0 }
                        },
                        @{
                            type   = "gauge"
                            entity = "${inv2}_instantaneous_battery_soc"
                            name   = "Inverter 2 Battery"
                            min    = 0
                            max    = 100
                            severity = @{ green = 50; yellow = 20; red = 0 }
                        }
                    )
                },
                # Top energy consumers
                @{
                    type     = "entities"
                    title    = "Top Energy Consumers"
                    entities = @(
                        @{
                            entity = "switch.sonoff_100168f6d9"
                            name   = "Main Geyser"
                            icon   = "mdi:water-boiler"
                            secondary_info = "last-changed"
                        },
                        @{
                            entity = "switch.sonoff_100168e932"
                            name   = "Pool Pump"
                            icon   = "mdi:pool"
                            secondary_info = "last-changed"
                        },
                        @{
                            entity = "switch.sonoff_10016b7e5c"
                            name   = "Flat Geyser"
                            icon   = "mdi:water-boiler"
                            secondary_info = "last-changed"
                        },
                        @{
                            entity = "switch.sonoff_100168f5e3"
                            name   = "Aircon"
                            icon   = "mdi:air-conditioner"
                            secondary_info = "last-changed"
                        }
                    )
                }
            )
        },
        # --- Tab 2: Inverter 1 ---
        @{
            title = "Inverter 1"
            path  = "inverter1"
            icon  = "mdi:numeric-1-box"
            cards = @(
                @{
                    type = "markdown"
                    content = "## Inverter 1 - S/N 2207207800`n8.8kW Inverter | 9kWp Solar | 4x5kWh = 20kWh Battery"
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_pv1_power"
                            name   = "String 1 (PPV1)"
                            icon   = "mdi:solar-panel"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_pv2_power"
                            name   = "String 2 (PPV2)"
                            icon   = "mdi:solar-panel"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_instantaneous_generation"
                            name   = "Total PV"
                            icon   = "mdi:solar-power"
                            icon_color = "amber"
                            layout = "vertical"
                        }
                    )
                },
                @{
                    type   = "gauge"
                    entity = "${inv1}_instantaneous_battery_soc"
                    name   = "Battery SOC"
                    min    = 0
                    max    = 100
                    severity = @{ green = 50; yellow = 20; red = 0 }
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_battery_charge"
                            name   = "Charge Today"
                            icon   = "mdi:battery-plus"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_battery_discharge"
                            name   = "Discharge Today"
                            icon   = "mdi:battery-minus"
                            layout = "vertical"
                        }
                    )
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_instantaneous_load"
                            name   = "Load"
                            icon   = "mdi:flash"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_instantaneous_grid_i_o"
                            name   = "Grid"
                            icon   = "mdi:transmission-tower"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv1}_instantaneous_battery_i_o"
                            name   = "Battery"
                            icon   = "mdi:battery"
                            layout = "vertical"
                        }
                    )
                },
                @{
                    type     = "entities"
                    title    = "Daily Stats"
                    entities = @(
                        @{ entity = "${inv1}_solar_production"; name = "Solar Production" },
                        @{ entity = "${inv1}_total_load";       name = "Total Load" },
                        @{ entity = "${inv1}_grid_import";      name = "Grid Import" },
                        @{ entity = "${inv1}_grid_export";      name = "Grid Export" },
                        @{ entity = "${inv1}_battery_charge";   name = "Battery Charge" },
                        @{ entity = "${inv1}_battery_discharge"; name = "Battery Discharge" }
                    )
                }
            )
        },
        # --- Tab 3: Inverter 2 ---
        @{
            title = "Inverter 2"
            path  = "inverter2"
            icon  = "mdi:numeric-2-box"
            cards = @(
                @{
                    type = "markdown"
                    content = "## Inverter 2 - S/N 2305136364`n8.8kW Inverter | 9kWp Solar | 4x5kWh = 20kWh Battery"
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_pv1_power"
                            name   = "String 1 (PPV1)"
                            icon   = "mdi:solar-panel"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_pv2_power"
                            name   = "String 2 (PPV2)"
                            icon   = "mdi:solar-panel"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_instantaneous_generation"
                            name   = "Total PV"
                            icon   = "mdi:solar-power"
                            icon_color = "amber"
                            layout = "vertical"
                        }
                    )
                },
                @{
                    type   = "gauge"
                    entity = "${inv2}_instantaneous_battery_soc"
                    name   = "Battery SOC"
                    min    = 0
                    max    = 100
                    severity = @{ green = 50; yellow = 20; red = 0 }
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_battery_charge"
                            name   = "Charge Today"
                            icon   = "mdi:battery-plus"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_battery_discharge"
                            name   = "Discharge Today"
                            icon   = "mdi:battery-minus"
                            layout = "vertical"
                        }
                    )
                },
                @{
                    type = "horizontal-stack"
                    cards = @(
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_instantaneous_load"
                            name   = "Load"
                            icon   = "mdi:flash"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_instantaneous_grid_i_o"
                            name   = "Grid"
                            icon   = "mdi:transmission-tower"
                            layout = "vertical"
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "${inv2}_instantaneous_battery_i_o"
                            name   = "Battery"
                            icon   = "mdi:battery"
                            layout = "vertical"
                        }
                    )
                },
                @{
                    type     = "entities"
                    title    = "Daily Stats"
                    entities = @(
                        @{ entity = "${inv2}_solar_production"; name = "Solar Production" },
                        @{ entity = "${inv2}_total_load";       name = "Total Load" },
                        @{ entity = "${inv2}_grid_import";      name = "Grid Import" },
                        @{ entity = "${inv2}_grid_export";      name = "Grid Export" },
                        @{ entity = "${inv2}_battery_charge";   name = "Battery Charge" },
                        @{ entity = "${inv2}_battery_discharge"; name = "Battery Discharge" }
                    )
                }
            )
        }
    )
}

Save-Dashboard -UrlPath "energy-dashboard" -Title "Energy" -Icon "mdi:solar-power-variant" -DashConfig $energyConfig

# ============================================================
# Step 4: Lighting & Rooms Dashboard
# ============================================================

Write-Step "Step 4: Lighting & Rooms Dashboard"

$lightingConfig = @{
    title = "Lighting"
    views = @(
        @{
            title = "All Rooms"
            path  = "rooms"
            icon  = "mdi:lightbulb-group"
            cards = @(
                # --- Lights on counter ---
                @{
                    type    = "custom:mushroom-template-card"
                    primary = "Lighting"
                    secondary = "{{ states('sensor.lights_on_count') }} lights currently on"
                    icon    = "mdi:lightbulb-group"
                    icon_color = "amber"
                },
                # --- Living Areas ---
                @{
                    type  = "vertical-stack"
                    title = "Living Areas"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4e53f"; name = "Lounge Light 1";   icon = "mdi:lamp";          tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e95ae6"; name = "Lounge Light 2";   icon = "mdi:lamp";          tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000f7cd0d"; name = "Kitchen Light 1";  icon = "mdi:ceiling-light"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000f7d022"; name = "Kitchen Light 2";  icon = "mdi:ceiling-light"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4cc42"; name = "Dining Light 1";   icon = "mdi:chandelier";    tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4cc96"; name = "Dining Light 2";   icon = "mdi:chandelier";    tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e56ced"; name = "Bar Light 1";      icon = "mdi:glass-cocktail"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4bcf2"; name = "Bar Light 2";      icon = "mdi:glass-cocktail"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e56cb1"; name = "Bar Fan";          icon = "mdi:fan";           tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4bbaf"; name = "Hallway";          icon = "mdi:ceiling-light"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000f74c78"; name = "TV Lights";        icon = "mdi:television-ambient-light"; tap_action = @{ action = "toggle" } }
                            )
                        }
                    )
                },
                # --- Bedrooms ---
                @{
                    type  = "vertical-stack"
                    title = "Bedrooms"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e95e4a"; name = "Main Bed Light 1"; icon = "mdi:lamp";          tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4fa5c"; name = "Main Bed Light 2"; icon = "mdi:lamp";          tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4e554"; name = "Baby Room";         icon = "mdi:baby-face-outline"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e53419"; name = "Guest Room";        icon = "mdi:bed";           tap_action = @{ action = "toggle" } }
                            )
                        }
                    )
                },
                # --- Utility ---
                @{
                    type  = "vertical-stack"
                    title = "Utility"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e95944"; name = "Laundry";        icon = "mdi:washing-machine"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000f7cd18"; name = "Scullery";       icon = "mdi:silverware-fork-knife"; tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000f7cf1b"; name = "Garage";         icon = "mdi:garage";        tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4c4c1"; name = "Workshop";       icon = "mdi:tools";         tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4c546"; name = "Wine Cellar";    icon = "mdi:glass-wine";    tap_action = @{ action = "toggle" } }
                            )
                        }
                    )
                },
                # --- Outdoor ---
                @{
                    type  = "vertical-stack"
                    title = "Outdoor"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e95aeb"; name = "Front Porch";     icon = "mdi:outdoor-lamp";  tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4bd3a"; name = "Courtyard";       icon = "mdi:outdoor-lamp";  tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4bac4"; name = "Yard";            icon = "mdi:outdoor-lamp";  tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4bafd"; name = "Backdoor";        icon = "mdi:door";          tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e95ca2"; name = "Pool Lights";     icon = "mdi:pool";          tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4ba93"; name = "Reception";       icon = "mdi:desk-lamp";     tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_10014e3f03"; name = "Visitor Gate Lights"; icon = "mdi:gate";      tap_action = @{ action = "toggle" } }
                            )
                        }
                    )
                },
                # --- Airbnb ---
                @{
                    type  = "vertical-stack"
                    title = "Airbnb"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e95bf3"; name = "Bed Lights";      icon = "mdi:bed";           tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e56c1e"; name = "TV Lights";       icon = "mdi:television";    tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e4e504"; name = "Bathroom Lights"; icon = "mdi:shower";        tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000e95b7e"; name = "Bathroom Fan";    icon = "mdi:fan";           tap_action = @{ action = "toggle" } },
                                @{ type = "custom:mushroom-entity-card"; entity = "switch.sonoff_1000f74d7f"; name = "Towel Rack";      icon = "mdi:towel-rail";    tap_action = @{ action = "toggle" } }
                            )
                        }
                    )
                }
            )
        }
    )
}

Save-Dashboard -UrlPath "lighting-dashboard" -Title "Lighting" -Icon "mdi:lightbulb-group" -DashConfig $lightingConfig

# ============================================================
# Step 5: Security Dashboard
# ============================================================

Write-Step "Step 5: Security Dashboard"

$securityConfig = @{
    title = "Security"
    views = @(
        @{
            title = "Security"
            path  = "security"
            icon  = "mdi:shield-home"
            cards = @(
                # Status summary
                @{
                    type    = "custom:mushroom-template-card"
                    primary = "Security Status"
                    secondary = "{{ states('sensor.doors_open_count') }} doors open"
                    icon    = "mdi:shield-home"
                    icon_color = "{{ 'red' if states('sensor.doors_open_count') | int > 0 else 'green' }}"
                },
                # --- Doors ---
                @{
                    type  = "vertical-stack"
                    title = "Door Sensors"
                    cards = @(
                        @{
                            type     = "entities"
                            entities = @(
                                @{ entity = "binary_sensor.sonoff_ds01_a"; name = "Door 1"; icon = "mdi:door" },
                                @{ entity = "binary_sensor.sonoff_ds01_b"; name = "Door 2"; icon = "mdi:door" },
                                @{ entity = "binary_sensor.sonoff_ds01_c"; name = "Door 3"; icon = "mdi:door" },
                                @{ entity = "binary_sensor.sonoff_ds01_d"; name = "Door 4"; icon = "mdi:door" },
                                @{ entity = "binary_sensor.sonoff_ds01_e"; name = "Door 5"; icon = "mdi:door" },
                                @{ entity = "binary_sensor.sonoff_ds01_f"; name = "Door 6"; icon = "mdi:door" },
                                @{ entity = "binary_sensor.sonoff_ds01_g"; name = "Door 7"; icon = "mdi:door" },
                                @{ entity = "binary_sensor.sonoff_ds01_h"; name = "Door 8"; icon = "mdi:door" }
                            )
                        }
                    )
                },
                # --- Gates ---
                @{
                    type  = "vertical-stack"
                    title = "Gates"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000f74d0c"
                                    name   = "Main Gate"
                                    icon   = "mdi:gate"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_10014e3e9b"
                                    name   = "Visitor Gate"
                                    icon   = "mdi:gate"
                                    tap_action = @{ action = "toggle" }
                                }
                            )
                        }
                    )
                },
                # --- Motion Sensors ---
                @{
                    type  = "vertical-stack"
                    title = "Motion Sensors"
                    cards = @(
                        @{
                            type     = "entities"
                            entities = @(
                                @{ entity = "binary_sensor.sonoff_snzb_03_a"; name = "Motion 1"; icon = "mdi:motion-sensor" },
                                @{ entity = "binary_sensor.sonoff_snzb_03_b"; name = "Motion 2"; icon = "mdi:motion-sensor" },
                                @{ entity = "binary_sensor.sonoff_snzb_03_c"; name = "Motion 3"; icon = "mdi:motion-sensor" },
                                @{ entity = "binary_sensor.sonoff_snzb_03_d"; name = "Motion 4"; icon = "mdi:motion-sensor" },
                                @{ entity = "binary_sensor.sonoff_snzb_03_e"; name = "Motion 5"; icon = "mdi:motion-sensor" }
                            )
                        }
                    )
                },
                # --- Alarm ---
                @{
                    type  = "vertical-stack"
                    title = "Alarm System"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000f74ceb"
                                    name   = "Alarm Magnets"
                                    icon   = "mdi:alarm-light"
                                    icon_color = "red"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_100160713a"
                                    name   = "Alarm Motion"
                                    icon   = "mdi:alarm-light"
                                    icon_color = "red"
                                    tap_action = @{ action = "toggle" }
                                }
                            )
                        }
                    )
                },
                # Offline devices alert
                @{
                    type    = "markdown"
                    content = "### Unavailable Devices\nCheck these devices - they may be offline or unpowered:\n- `switch.sonoff_100160713a` - Alarm Motion Trigger\n- `switch.sonoff_1000a21e3c` - Tank Pump\n\nGo to **Settings > Devices** to check connectivity."
                }
            )
        }
    )
}

Save-Dashboard -UrlPath "security-dashboard" -Title "Security" -Icon "mdi:shield-home" -DashConfig $securityConfig

# ============================================================
# Step 6: Water & Climate Dashboard
# ============================================================

Write-Step "Step 6: Water & Climate Dashboard"

$waterClimateConfig = @{
    title = "Water & Climate"
    views = @(
        @{
            title = "Water & Climate"
            path  = "water-climate"
            icon  = "mdi:water-thermometer"
            cards = @(
                # --- Geysers ---
                @{
                    type  = "vertical-stack"
                    title = "Geysers"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 3
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_100168f6d9"
                                    name   = "Main Geyser"
                                    icon   = "mdi:water-boiler"
                                    icon_color = "{{ 'red' if is_state('switch.sonoff_100168f6d9', 'on') else 'grey' }}"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_10016b7e5c"
                                    name   = "Flat Geyser"
                                    icon   = "mdi:water-boiler"
                                    icon_color = "{{ 'red' if is_state('switch.sonoff_10016b7e5c', 'on') else 'grey' }}"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_100168eeac"
                                    name   = "Guest Geyser"
                                    icon   = "mdi:water-boiler"
                                    icon_color = "{{ 'red' if is_state('switch.sonoff_100168eeac', 'on') else 'grey' }}"
                                    tap_action = @{ action = "toggle" }
                                }
                            )
                        },
                        @{
                            type     = "entities"
                            title    = "Geyser Power Usage"
                            entities = @(
                                @{ entity = "sensor.sonoff_100168f6d9_power";  name = "Main Geyser Power";  icon = "mdi:flash" },
                                @{ entity = "sensor.sonoff_100168f6d9_energy"; name = "Main Geyser Energy"; icon = "mdi:counter" },
                                @{ entity = "sensor.sonoff_10016b7e5c_power";  name = "Flat Geyser Power";  icon = "mdi:flash" },
                                @{ entity = "sensor.sonoff_10016b7e5c_energy"; name = "Flat Geyser Energy"; icon = "mdi:counter" }
                            )
                        }
                    )
                },
                # --- Irrigation ---
                @{
                    type  = "vertical-stack"
                    title = "Irrigation"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e78aa2"
                                    name   = "Hose Pipe"
                                    icon   = "mdi:water"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e78a75"
                                    name   = "Vegetable Garden"
                                    icon   = "mdi:sprinkler-variant"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e73f12"
                                    name   = "Shed Garden"
                                    icon   = "mdi:sprinkler-variant"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e7a63c"
                                    name   = "Buffer Tank"
                                    icon   = "mdi:water-pump"
                                    tap_action = @{ action = "toggle" }
                                }
                            )
                        },
                        @{
                            type     = "entities"
                            title    = "Water Usage"
                            entities = @(
                                @{ entity = "sensor.sonoff_1000e78aa2_water"; name = "Hose Pipe";        icon = "mdi:water" },
                                @{ entity = "sensor.sonoff_1000e78a75_water"; name = "Vegetable Garden"; icon = "mdi:water" },
                                @{ entity = "sensor.sonoff_1000e73f12_water"; name = "Shed Garden";      icon = "mdi:water" },
                                @{ entity = "sensor.sonoff_1000e7a63c_water"; name = "Buffer Tank";      icon = "mdi:water" }
                            )
                        }
                    )
                },
                # --- Pumps ---
                @{
                    type  = "vertical-stack"
                    title = "Pumps"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 3
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1001604abd"
                                    name   = "Borehole"
                                    icon   = "mdi:water-pump"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_100168e932"
                                    name   = "Pool Pump"
                                    icon   = "mdi:pool"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000a21e3c"
                                    name   = "Tank Pump"
                                    icon   = "mdi:water-pump"
                                    tap_action = @{ action = "toggle" }
                                }
                            )
                        },
                        @{
                            type     = "entities"
                            title    = "Pool Pump Power"
                            entities = @(
                                @{ entity = "sensor.sonoff_100168e932_power";  name = "Pool Pump Power";  icon = "mdi:flash" },
                                @{ entity = "sensor.sonoff_100168e932_energy"; name = "Pool Pump Energy"; icon = "mdi:counter" }
                            )
                        }
                    )
                },
                # --- Climate ---
                @{
                    type  = "vertical-stack"
                    title = "Climate & Temperature"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "sensor.sonoff_th_main_bedroom_temperature"
                                    name   = "Main Bedroom Temp"
                                    icon   = "mdi:thermometer"
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "sensor.sonoff_th_main_bedroom_humidity"
                                    name   = "Main Bedroom Humidity"
                                    icon   = "mdi:water-percent"
                                }
                            )
                        },
                        @{
                            type   = "custom:mushroom-entity-card"
                            entity = "switch.sonoff_100168f5e3"
                            name   = "Aircon"
                            icon   = "mdi:air-conditioner"
                            tap_action = @{ action = "toggle" }
                        }
                    )
                },
                # --- Pool ---
                @{
                    type  = "vertical-stack"
                    title = "Pool"
                    cards = @(
                        @{
                            type = "grid"
                            columns = 2
                            square = $false
                            cards = @(
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_1000e95ca2"
                                    name   = "Pool Lights"
                                    icon   = "mdi:pool"
                                    tap_action = @{ action = "toggle" }
                                },
                                @{
                                    type   = "custom:mushroom-entity-card"
                                    entity = "switch.sonoff_100168e932"
                                    name   = "Pool Pump"
                                    icon   = "mdi:pump"
                                    tap_action = @{ action = "toggle" }
                                }
                            )
                        }
                    )
                }
            )
        }
    )
}

Save-Dashboard -UrlPath "water-climate-dashboard" -Title "Water & Climate" -Icon "mdi:water-thermometer" -DashConfig $waterClimateConfig

# ============================================================
# Step 7: Media Dashboard
# ============================================================

Write-Step "Step 7: Media Dashboard"

$mediaConfig = @{
    title = "Media"
    views = @(
        @{
            title = "Media"
            path  = "media"
            icon  = "mdi:speaker-multiple"
            cards = @(
                # --- Samsung TV ---
                @{
                    type  = "vertical-stack"
                    title = "Samsung TV"
                    cards = @(
                        @{
                            type   = "media-control"
                            entity = "media_player.samsung_qa65q70bakxxa"
                        }
                    )
                },
                # --- Living Area Speakers ---
                @{
                    type  = "vertical-stack"
                    title = "Living Area Speakers"
                    cards = @(
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.kitchen_speaker"
                            name   = "Kitchen"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        },
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.dining_room_speaker"
                            name   = "Dining Room"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        },
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.front_home_speaker"
                            name   = "Front Home"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        },
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.study_speaker"
                            name   = "Study"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        }
                    )
                },
                # --- Bedroom Speakers ---
                @{
                    type  = "vertical-stack"
                    title = "Bedroom Speakers"
                    cards = @(
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.bedroom_speaker"
                            name   = "Bedroom"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        },
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.baby_room_speaker"
                            name   = "Baby Room"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        },
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.guest_room_speaker"
                            name   = "Guest Room"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        }
                    )
                },
                # --- Other ---
                @{
                    type  = "vertical-stack"
                    title = "Other"
                    cards = @(
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.airbnb_speaker"
                            name   = "Airbnb"
                            icon   = "mdi:speaker"
                            group  = $true
                            hide   = @{ power = $true }
                        },
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.home_speakers"
                            name   = "All Speakers (Group)"
                            icon   = "mdi:speaker-multiple"
                            group  = $true
                            hide   = @{ power = $true }
                        },
                        @{
                            type   = "custom:mini-media-player"
                            entity = "media_player.tv_chromecast"
                            name   = "TV Chromecast"
                            icon   = "mdi:cast"
                            group  = $true
                            hide   = @{ power = $true }
                        }
                    )
                },
                # --- TTS ---
                @{
                    type  = "vertical-stack"
                    title = "Announcements"
                    cards = @(
                        @{
                            type    = "markdown"
                            content = "Use Home Assistant **Developer Tools > Services** to test TTS:`n`n``yaml`nservice: tts.google_translate_say`ndata:`n  entity_id: media_player.home_speakers`n  message: 'Hello from Home Assistant'`n``"
                        }
                    )
                }
            )
        }
    )
}

Save-Dashboard -UrlPath "media-dashboard" -Title "Media" -Icon "mdi:speaker-multiple" -DashConfig $mediaConfig

# ============================================================
# Summary
# ============================================================

Write-Step "Dashboard Setup Complete!"

Write-Host ""
Write-Host "  Dashboards created:" -ForegroundColor White
Write-Host "    1. Home Overview (default)     - /lovelace" -ForegroundColor Green
Write-Host "    2. Energy Dashboard            - /energy-dashboard" -ForegroundColor Green
Write-Host "    3. Lighting & Rooms            - /lighting-dashboard" -ForegroundColor Green
Write-Host "    4. Security                    - /security-dashboard" -ForegroundColor Green
Write-Host "    5. Water & Climate             - /water-climate-dashboard" -ForegroundColor Green
Write-Host "    6. Media                       - /media-dashboard" -ForegroundColor Green
Write-Host ""
Write-Host "  HACS Cards:" -ForegroundColor White
Write-Host "    - Mushroom Cards (piitaya/lovelace-mushroom)" -ForegroundColor Green
Write-Host "    - Mini Media Player (kalkih/mini-media-player)" -ForegroundColor Green
Write-Host "    - Sunsynk Power Flow Card (already installed)" -ForegroundColor Green
Write-Host ""
Write-Host "  Template Sensors:" -ForegroundColor White
Write-Host "    - Solar Total Generation, Load, Battery IO, Grid IO" -ForegroundColor Green
Write-Host "    - Solar Daily Production, Daily Load" -ForegroundColor Green
Write-Host "    - Solar Battery SOC Average" -ForegroundColor Green
Write-Host "    - Lights On Count, Doors Open Count" -ForegroundColor Green
Write-Host ""
Write-Host "  IMPORTANT NOTES:" -ForegroundColor Yellow
Write-Host "    - Entity IDs use placeholder names (sonoff_XXXXXXXX)" -ForegroundColor Yellow
Write-Host "    - After first run, verify entity IDs match your actual devices" -ForegroundColor Yellow
Write-Host "    - Edit entity IDs in this script if names don't match" -ForegroundColor Yellow
Write-Host "    - Door/motion sensor entity IDs need updating from actual HA entities" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Open http://$($Config.HA_IP):8123 and verify dashboards" -ForegroundColor Cyan
Write-Host "    2. Update entity IDs for door sensors, motion sensors" -ForegroundColor Cyan
Write-Host "    3. Rename Sonoff devices in HA for cleaner display names" -ForegroundColor Cyan
Write-Host "    4. Consider adding automations (geyser schedules, etc.)" -ForegroundColor Cyan
Write-Host ""

Disconnect-HAWS
