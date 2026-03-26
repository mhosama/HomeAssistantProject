<#
.SYNOPSIS
    Set up Smart Energy Scheduler -input_booleans, sensors, automations, scheduled tasks, dashboard.

.DESCRIPTION
    One-time setup for HA-controlled energy scheduling:
    1. Adds input_boolean entries to configuration.yaml via Samba (requires restart)
    2. Creates sensor.energy_schedule and sensor.energy_schedule_log via POST /api/states
    3. Creates automation.borehole_pump_schedule (8x daily cyclic)
    4. Creates automation.irrigation_veggie_garden (3x daily, weather-aware)
    5. Registers Windows Scheduled Tasks: HA-RefreshEnergySchedule (daily 04:20), HA-RunEnergySchedule (5 min)
    6. Adds Energy Schedule section to Overview dashboard (additive merge via WebSocket)

.EXAMPLE
    .\18-Setup-EnergySchedule.ps1
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

$haBase = "http://$($Config.HA_IP):8123"
$haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
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
        try { $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait() } catch {}
    }
}

# ============================================================
# Entity IDs
# ============================================================

$kitchenSpeaker = "media_player.kitchen_speaker"
$ttsEngine      = "tts.google_translate_en_com"

# ============================================================
# Step 1: Add input_booleans to configuration.yaml via Samba
# ============================================================

Write-Step "Step 1: Add input_booleans to configuration.yaml"

$sambaPath = "\\192.168.0.239\config"
$configYaml = Join-Path $sambaPath "configuration.yaml"

# Ensure Samba connection
try {
    $null = net use $sambaPath /user:homeassistant terrabyte 2>&1
} catch {}

if (-not (Test-Path $configYaml)) {
    Write-Fail "Cannot access $configYaml -check Samba connection"
    Write-Info "Try: net use * /delete /y; net use $sambaPath /user:homeassistant terrabyte"
    exit 1
}

$yamlContent = Get-Content $configYaml -Raw

# Build full list of input_boolean entries (base + 45 overrides)
$needsRestart = $false

$newEntries = @(
    "  energy_schedule_active:"
    "    name: Energy Schedule Active"
    "    icon: mdi:lightning-bolt"
    "  borehole_pump_schedule:"
    "    name: Borehole Pump Schedule"
    "    icon: mdi:water-pump"
)

# Add 45 override booleans: 3 devices x 15 hours (06-20)
$overrideDevices = @(
    @{ key = "main_geyser"; label = "Main Geyser" }
    @{ key = "flat_geyser"; label = "Flat Geyser" }
    @{ key = "pool_pump";   label = "Pool Pump" }
)
foreach ($dev in $overrideDevices) {
    for ($h = 6; $h -le 20; $h++) {
        $hh = $h.ToString("D2")
        $newEntries += "  override_$($dev.key)_${hh}:"
        $newEntries += "    name: `"Override $($dev.label) ${hh}:00`""
        $newEntries += "    icon: mdi:clock-outline"
    }
}

# Check if override booleans already exist (use last override as marker)
if ($yamlContent -match "override_pool_pump_20") {
    Write-Info "Override input_boolean entries already exist in configuration.yaml"
} elseif ($yamlContent -match "energy_schedule_active") {
    # Base entries exist but overrides don't — add only override entries
    Write-Info "Adding override input_boolean entries..."
    $overrideEntries = $newEntries | Select-Object -Skip 6  # skip the 2 base entries (3 lines each)
    if ($yamlContent -match "(?m)(^  borehole_pump_schedule:\s*\n    name:.*\n    icon:.*\n)") {
        $yamlContent = $yamlContent -replace "(?m)(^  borehole_pump_schedule:\s*\n    name:.*\n    icon:.*\n)", "`$1$($overrideEntries -join "`n")`n"
    }
    [System.IO.File]::WriteAllText($configYaml, $yamlContent, [System.Text.Encoding]::UTF8)
    Write-Success "Added 45 override input_boolean entries to configuration.yaml"
    $needsRestart = $true
} else {
    # Nothing exists yet — add entire input_boolean section
    if ($yamlContent -match "(?m)^input_boolean:") {
        $yamlContent = $yamlContent -replace "(?m)(^input_boolean:\s*\n)", "`$1$($newEntries -join "`n")`n"
    } else {
        $yamlContent += "`n`ninput_boolean:`n$($newEntries -join "`n")"
    }
    [System.IO.File]::WriteAllText($configYaml, $yamlContent, [System.Text.Encoding]::UTF8)
    Write-Success "Added all input_boolean entries to configuration.yaml"
    $needsRestart = $true
}

if ($needsRestart) {
    Write-Info "Restarting Home Assistant for input_booleans..."
    try {
        $null = Invoke-WebRequest -Uri "$haBase/api/services/homeassistant/restart" -Method POST -Headers $haHeaders -Body "{}" -UseBasicParsing -TimeoutSec 10
        Write-Success "Restart triggered"
    } catch {
        Write-Info "Restart request sent (connection closed as expected)"
    }

    Write-Info "Waiting for HA to restart..."
    Start-Sleep -Seconds 30
    $maxWait = 180
    $waited = 0
    while ($waited -lt $maxWait) {
        try {
            $null = Invoke-RestMethod -Uri "$haBase/api/" -Headers $haHeaders -TimeoutSec 5
            break
        } catch {
            Start-Sleep -Seconds 10
            $waited += 10
        }
    }
    if ($waited -ge $maxWait) {
        Write-Fail "HA did not come back after restart"
        exit 1
    }
    Write-Success "HA is back online"
}

# ============================================================
# Step 2: Create sensors via POST /api/states
# ============================================================

Write-Step "Step 2: Create energy schedule sensors"

$sensors = @(
    @{
        entity_id = "sensor.energy_schedule"
        state     = "pending"
        attributes = @{
            friendly_name      = "Energy Schedule"
            icon               = "mdi:lightning-bolt-circle"
            hourly_plan        = @()
            device_summary     = ""
            total_solar_kwh    = 0
            tts_summary        = ""
            irrigation_disabled = $false
            schedule_date      = ""
            confidence         = ""
            last_updated       = ""
        }
    }
    @{
        entity_id = "sensor.energy_schedule_log"
        state     = "0"
        attributes = @{
            friendly_name = "Energy Schedule Log"
            icon          = "mdi:format-list-bulleted"
            events        = @()
            last_updated  = ""
        }
    }
)

foreach ($sensor in $sensors) {
    $body = @{
        state      = $sensor.state
        attributes = $sensor.attributes
    } | ConvertTo-Json -Depth 5

    try {
        $null = Invoke-WebRequest `
            -Uri "$haBase/api/states/$($sensor.entity_id)" `
            -Method POST -Headers $haHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 15
        Write-Success "$($sensor.entity_id) created"
    } catch {
        Write-Fail "$($sensor.entity_id): $($_.Exception.Message)"
    }
}

# ============================================================
# Step 3: Create automations
# ============================================================

Write-Step "Step 3: Create automations"

# Borehole pump schedule -8x daily with inching (auto-off via Sonoff)
$boreholeJson = @"
{
  "alias": "Borehole Pump Schedule",
  "description": "Runs borehole pump 8 times per day on a 3-hour cycle. Condition: input_boolean.borehole_pump_schedule is on.",
  "mode": "single",
  "trigger": [
    {"platform": "time", "at": "02:00:00"},
    {"platform": "time", "at": "05:00:00"},
    {"platform": "time", "at": "08:00:00"},
    {"platform": "time", "at": "11:00:00"},
    {"platform": "time", "at": "14:00:00"},
    {"platform": "time", "at": "17:00:00"},
    {"platform": "time", "at": "20:00:00"},
    {"platform": "time", "at": "23:00:00"}
  ],
  "condition": [
    {"condition": "state", "entity_id": "input_boolean.borehole_pump_schedule", "state": "on"}
  ],
  "action": [
    {"service": "switch.turn_on", "target": {"entity_id": "switch.sonoff_10011058e1"}},
    {"choose": [
      {
        "conditions": [{"condition": "time", "after": "06:00:00", "before": "22:00:00"}],
        "sequence": [
          {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Borehole pump is running."}}
        ]
      }
    ]},
    {"service": "notify.mobile_app_sm_s921b", "data": {"title": "Borehole Pump", "message": "Borehole pump started at {{ now().strftime('%H:%M') }}"}}
  ]
}
"@

try {
    $null = Invoke-WebRequest -Uri "$haBase/api/config/automation/config/borehole_pump_schedule" `
        -Method POST -Headers $haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($boreholeJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "automation.borehole_pump_schedule created"
} catch {
    Write-Info "automation.borehole_pump_schedule may have timed out (usually still applies)"
}

# Irrigation veggie garden -3x daily, weather-aware
$irrigationJson = @"
{
  "alias": "Irrigation Veggie Garden",
  "description": "Runs veggie garden irrigation 3x daily. Disabled when rain expected (via energy schedule) or energy_schedule_active is off.",
  "mode": "single",
  "trigger": [
    {"platform": "time", "at": "08:00:00"},
    {"platform": "time", "at": "12:00:00"},
    {"platform": "time", "at": "17:00:00"}
  ],
  "condition": [
    {"condition": "state", "entity_id": "input_boolean.energy_schedule_active", "state": "on"},
    {"condition": "template", "value_template": "{{ state_attr('sensor.energy_schedule', 'irrigation_disabled') != true }}"}
  ],
  "action": [
    {"service": "switch.turn_on", "target": {"entity_id": "switch.sonoff_a4800bd719_switch"}},
    {"delay": {"seconds": 420}},
    {"service": "switch.turn_off", "target": {"entity_id": "switch.sonoff_a4800bd719_switch"}},
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Veggie garden irrigation complete."}},
    {"service": "notify.mobile_app_sm_s921b", "data": {"title": "Irrigation", "message": "Veggie garden watered at {{ now().strftime('%H:%M') }}"}}
  ]
}
"@

try {
    $null = Invoke-WebRequest -Uri "$haBase/api/config/automation/config/irrigation_veggie_garden" `
        -Method POST -Headers $haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($irrigationJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "automation.irrigation_veggie_garden created"
} catch {
    Write-Info "automation.irrigation_veggie_garden may have timed out (usually still applies)"
}

# ============================================================
# Step 4: Register Windows Scheduled Tasks
# ============================================================

Write-Step "Step 4: Register scheduled tasks"

$projectRoot = Split-Path -Parent $scriptDir

# HA-RefreshEnergySchedule -daily at 04:20
$taskName1 = "HA-RefreshEnergySchedule"
$taskAction1 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$scriptDir\18a-Refresh-EnergySchedule.ps1`""
$taskTrigger1 = New-ScheduledTaskTrigger -Daily -At "04:20"
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

try {
    $existing = Get-ScheduledTask -TaskName $taskName1 -ErrorAction SilentlyContinue
    if ($existing) {
        Set-ScheduledTask -TaskName $taskName1 -Action $taskAction1 -Trigger $taskTrigger1 -Settings $taskSettings | Out-Null
        Write-Success "$taskName1 updated"
    } else {
        Register-ScheduledTask -TaskName $taskName1 -Action $taskAction1 -Trigger $taskTrigger1 -Settings $taskSettings -User "SYSTEM" -RunLevel Highest | Out-Null
        Write-Success "$taskName1 registered"
    }
} catch {
    Write-Fail "$taskName1 : $($_.Exception.Message)"
}

# HA-RunEnergySchedule -every 5 minutes
$taskName2 = "HA-RunEnergySchedule"
$taskAction2 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$scriptDir\18b-Run-EnergySchedule.ps1`""
$taskTrigger2 = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Minutes 5)
$taskSettings2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

try {
    $existing = Get-ScheduledTask -TaskName $taskName2 -ErrorAction SilentlyContinue
    if ($existing) {
        Set-ScheduledTask -TaskName $taskName2 -Action $taskAction2 -Trigger $taskTrigger2 -Settings $taskSettings2 | Out-Null
        Write-Success "$taskName2 updated"
    } else {
        Register-ScheduledTask -TaskName $taskName2 -Action $taskAction2 -Trigger $taskTrigger2 -Settings $taskSettings2 -User "SYSTEM" -RunLevel Highest | Out-Null
        Write-Success "$taskName2 registered"
    }
} catch {
    Write-Fail "$taskName2 : $($_.Exception.Message)"
}

# ============================================================
# Step 5: Add Energy Schedule section to Overview dashboard
# ============================================================

Write-Step "Step 5: Add Energy Schedule section to Overview dashboard"

Connect-HAWS

$currentConfig = Invoke-WSCommand -Type "lovelace/config"

if (-not $currentConfig.success) {
    Write-Fail "Could not load Overview dashboard: $($currentConfig.error.message)"
    Disconnect-HAWS
    exit 1
}

$dashConfig = $currentConfig.result
$views = @($dashConfig.views)
Write-Info "Overview dashboard has $($views.Count) view(s)"

# Find the main view (index 0)
$mainView = $views[0]
$existingCards = @($mainView.cards)

# Remove any existing Energy Schedule section (for re-run safety)
$filteredCards = @()
$skipNext = $false
foreach ($card in $existingCards) {
    if ($card.type -eq "vertical-stack" -and $card.cards) {
        $firstCard = $card.cards | Select-Object -First 1
        if ($firstCard.primary -eq "Energy Schedule") {
            continue
        }
    }
    $filteredCards += $card
}

# Build slim Energy Schedule summary card (full dashboard at /energy-schedule)
$energyScheduleSection = @{
    type  = "vertical-stack"
    cards = @(
        @{
            type       = "custom:mushroom-template-card"
            primary    = "Energy Schedule"
            icon       = "mdi:lightning-bolt-circle"
            icon_color = "amber"
            secondary  = "{{ state_attr('sensor.energy_schedule', 'confidence') | default('pending') | title }} | {{ state_attr('sensor.energy_schedule', 'total_solar_kwh') | default(0) }} kWh solar"
            tap_action = @{ action = "navigate"; navigation_path = "/energy-schedule/schedule" }
        }
        @{
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
    )
}

$filteredCards += $energyScheduleSection
$mainView.cards = $filteredCards
$views[0] = $mainView
$dashConfig.views = $views

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{ config = $dashConfig }
if ($saveResp.success) {
    Write-Success "Energy Schedule section added to Overview dashboard"
} else {
    Write-Fail "Dashboard save failed: $($saveResp.error.message)"
}

Disconnect-HAWS

# ============================================================
# Step 6: Turn on input_booleans (default: on)
# ============================================================

Write-Step "Step 6: Enable input_booleans"

foreach ($entity in @("input_boolean.energy_schedule_active", "input_boolean.borehole_pump_schedule")) {
    try {
        $body = @{ entity_id = $entity } | ConvertTo-Json
        $null = Invoke-WebRequest -Uri "$haBase/api/services/input_boolean/turn_on" `
            -Method POST -Headers $haHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 10
        Write-Success "$entity turned on"
    } catch {
        Write-Fail "$entity : $($_.Exception.Message)"
    }
}

# Initialize all 45 override booleans to OFF (will be synced by 18a on first run)
Write-Info "Initializing override booleans to OFF..."
$allOverrides = @()
$overrideDevKeys = @("main_geyser", "flat_geyser", "pool_pump")
foreach ($dev in $overrideDevKeys) {
    for ($h = 6; $h -le 20; $h++) {
        $allOverrides += "input_boolean.override_${dev}_$($h.ToString('D2'))"
    }
}
try {
    $body = @{ entity_id = $allOverrides } | ConvertTo-Json -Depth 5
    $null = Invoke-WebRequest -Uri "$haBase/api/services/input_boolean/turn_off" `
        -Method POST -Headers $haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -UseBasicParsing -TimeoutSec 15
    Write-Success "All $($allOverrides.Count) override booleans initialized to OFF"
} catch {
    Write-Fail "Override init: $($_.Exception.Message)"
}

# ============================================================
# Done
# ============================================================

Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host " Energy Schedule setup complete!" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Verify input_booleans in HA Developer Tools > States" -ForegroundColor White
Write-Host "  2. Run 19-Setup-EnergyDashboard.ps1 to create the dedicated dashboard" -ForegroundColor White
Write-Host "  3. Run 18a-Refresh-EnergySchedule.ps1 manually to generate first schedule" -ForegroundColor White
Write-Host "  4. Run 18b-Run-EnergySchedule.ps1 to test device switching" -ForegroundColor White
Write-Host "  5. Deploy scheduled tasks to server via PS Remoting" -ForegroundColor White
Write-Host "  6. Run 17-Integrity-Check.ps1 to verify" -ForegroundColor White
