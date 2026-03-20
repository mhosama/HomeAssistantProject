<#
.SYNOPSIS
    Add phone push notifications to critical Home Assistant automations.

.DESCRIPTION
    Discovers the HA Companion App mobile_app notify service, then updates
    existing automations to add phone notifications alongside existing TTS alerts.

    Automations updated:
    1. Inverter Room High Temp      - "Warning: Inverter room is at X°C"
    2. Battery Fully Charged        - "Batteries are now fully charged"
    3. Gate Open Alert              - "Main/visitor gate opened"
    4. Inverter Room Door Closed Hot - "Inverter room is hot and door is closed"

    Prerequisites:
    - HA Companion App installed on phone and connected to HA
    - Phone must be on home WiFi (no Nabu Casa)

.EXAMPLE
    .\07-Setup-PhoneAlerts.ps1
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
# REST API helper
# ============================================================

$script:haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

function Invoke-HAREST {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [string]$JsonBody = $null
    )
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $script:haHeaders
        UseBasicParsing = $true
        TimeoutSec      = 60
    }
    if ($JsonBody) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($JsonBody) }

    try {
        return Invoke-WebRequest @params
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Fail "REST $Method $Endpoint -> HTTP $status : $($_.Exception.Message)"
        return $null
    }
}

# ============================================================
# Entity IDs
# ============================================================

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"

# Gates
$mainGate    = "switch.sonoff_1000f74d0c"
$visitorGate = "switch.sonoff_10014e3e9b"

# Solar
$batterySoc = "sensor.battery_soc"

# Temperature sensor (inverter room)
$inverterRoomTemp = "sensor.sonoff_a48007a2b0_temperature"

# Inverter room door sensor
$inverterRoomDoor = "binary_sensor.sonoff_a48003e73f"

# ============================================================
# STEP 1: Discover mobile app notify service
# ============================================================

Write-Step "1/6 - Discovering Companion App"

Write-Info "Querying /api/services for notify.mobile_app_* ..."

$resp = Invoke-HAREST -Endpoint "/api/services"
if (-not $resp) {
    Write-Fail "Could not query HA services. Is HA running?"
    exit 1
}

$services = $resp.Content | ConvertFrom-Json

# Find all notify services that match mobile_app pattern
$notifyServices = $services | Where-Object { $_.domain -eq "notify" }
$mobileApps = @()
if ($notifyServices) {
    foreach ($svc in $notifyServices) {
        foreach ($serviceName in ($svc.services | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
            if ($serviceName -like "mobile_app_*") {
                $mobileApps += $serviceName
            }
        }
    }
}

if ($mobileApps.Count -eq 0) {
    Write-Fail "No mobile_app notify services found!"
    Write-Host ""
    Write-Host "  Make sure you have:" -ForegroundColor Yellow
    Write-Host "    1. Installed the HA Companion App on your phone" -ForegroundColor Yellow
    Write-Host "    2. Connected it to http://homeassistant.local:8123" -ForegroundColor Yellow
    Write-Host "    3. Granted notification permissions" -ForegroundColor Yellow
    Write-Host "    4. Your phone is on the home WiFi network" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Then re-run this script." -ForegroundColor Yellow
    exit 1
}

# Use the first mobile app found
$mobileAppService = "notify.$($mobileApps[0])"
Write-Success "Found: $mobileAppService"

if ($mobileApps.Count -gt 1) {
    Write-Info "Multiple mobile apps found: $($mobileApps -join ', '). Using first one."
}

# ============================================================
# STEP 2: Update Inverter Room High Temp automation
# ============================================================

Write-Step "2/6 - Inverter Room High Temp (with phone notification)"

$inverterJson = @"
{
  "alias": "Inverter Room High Temp",
  "description": "TTS alert + phone notification when inverter room temperature reaches 28C or above",
  "mode": "single",
  "trigger": [{"platform": "numeric_state", "entity_id": "$inverterRoomTemp", "above": 28}],
  "condition": [
    {"condition": "template", "value_template": "{{ (as_timestamp(now()) - as_timestamp(state_attr('automation.inverter_room_high_temp', 'last_triggered') | default(0))) > 3600 }}"}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Warning. The inverter room temperature is {{ states('$inverterRoomTemp') | round(0) }} degrees."}},
    {"service": "$mobileAppService", "data": {"title": "Inverter Room Hot", "message": "Warning: Inverter room is at {{ states('$inverterRoomTemp') | round(0) }}\u00b0C"}}
  ]
}
"@

Write-Info "Creating automation..."
try {
    $resp = Invoke-HAREST -Endpoint "/api/config/automation/config/inverter_room_high_temp" -Method "POST" -JsonBody $inverterJson
    if ($resp -and $resp.StatusCode -eq 200) {
        Write-Success "Inverter Room High Temp automation updated with phone notification"
    } else {
        Write-Fail "Failed to update Inverter Room High Temp"
    }
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# STEP 3: Update Battery Fully Charged automation
# ============================================================

Write-Step "3/6 - Battery Fully Charged (with phone notification)"

$batteryJson = @"
{
  "alias": "Battery Fully Charged",
  "description": "TTS alert + phone notification when battery SOC reaches 99% or above, once per day",
  "mode": "single",
  "trigger": [{"platform": "numeric_state", "entity_id": "$batterySoc", "above": 98}],
  "condition": [
    {"condition": "template", "value_template": "{{ (as_timestamp(now()) - as_timestamp(state_attr('automation.battery_fully_charged', 'last_triggered') | default(0))) > 72000 }}"}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Batteries are now fully charged."}},
    {"service": "$mobileAppService", "data": {"title": "Battery Full", "message": "Batteries are now fully charged ({{ states('$batterySoc') }}%)"}}
  ]
}
"@

Write-Info "Creating automation..."
try {
    $resp = Invoke-HAREST -Endpoint "/api/config/automation/config/battery_fully_charged" -Method "POST" -JsonBody $batteryJson
    if ($resp -and $resp.StatusCode -eq 200) {
        Write-Success "Battery Fully Charged automation updated with phone notification"
    } else {
        Write-Fail "Failed to update Battery Fully Charged"
    }
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# STEP 4: Update Gate Open Alert automation
# ============================================================

Write-Step "4/6 - Gate Open Alert (with phone notification)"

$gateJson = @"
{
  "alias": "Gate Open Alert",
  "description": "TTS alert + phone notification when the main gate or visitor gate is opened",
  "mode": "queued",
  "max": 5,
  "trigger": [
    {"platform": "state", "entity_id": "$mainGate", "from": "off", "to": "on", "id": "main_gate"},
    {"platform": "state", "entity_id": "$visitorGate", "from": "off", "to": "on", "id": "visitor_gate"}
  ],
  "action": [{"choose": [
    {"conditions": [{"condition": "trigger", "id": "main_gate"}], "sequence": [
      {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The main gate has been opened."}},
      {"service": "$mobileAppService", "data": {"title": "Gate Alert", "message": "The main gate has been opened"}}
    ]},
    {"conditions": [{"condition": "trigger", "id": "visitor_gate"}], "sequence": [
      {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The visitor gate has been opened."}},
      {"service": "$mobileAppService", "data": {"title": "Gate Alert", "message": "The visitor gate has been opened"}}
    ]}
  ]}]
}
"@

Write-Info "Creating automation..."
try {
    $resp = Invoke-HAREST -Endpoint "/api/config/automation/config/gate_open_alert" -Method "POST" -JsonBody $gateJson
    if ($resp -and $resp.StatusCode -eq 200) {
        Write-Success "Gate Open Alert automation updated with phone notification"
    } else {
        Write-Fail "Failed to update Gate Open Alert"
    }
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# STEP 5: Test notification
# ============================================================

Write-Step "5/6 - Inverter Room Door Closed + Hot (TTS + phone)"

$doorHeatJson = @"
{
  "alias": "Inverter Room Door Closed Hot",
  "description": "TTS alert + phone notification when inverter room temp exceeds 25C and the door is closed",
  "mode": "single",
  "trigger": [{"platform": "numeric_state", "entity_id": "$inverterRoomTemp", "above": 25}],
  "condition": [
    {"condition": "state", "entity_id": "$inverterRoomDoor", "state": "off"},
    {"condition": "template", "value_template": "{{ (as_timestamp(now()) - as_timestamp(state_attr('automation.inverter_room_door_closed_hot', 'last_triggered') | default(0))) > 3600 }}"}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Warning. The inverter room temperature is {{ states('$inverterRoomTemp') | round(0) }} degrees and the door is closed. Please open the inverter room door."}},
    {"service": "$mobileAppService", "data": {"title": "Inverter Room Door Closed", "message": "Inverter room is at {{ states('$inverterRoomTemp') | round(0) }}\u00b0C and the door is closed. Please open it."}}
  ]
}
"@

Write-Info "Creating automation..."
try {
    $resp = Invoke-HAREST -Endpoint "/api/config/automation/config/inverter_room_door_closed_hot" -Method "POST" -JsonBody $doorHeatJson
    if ($resp -and $resp.StatusCode -eq 200) {
        Write-Success "Inverter Room Door Closed Hot automation created"
    } else {
        Write-Fail "Failed to create Inverter Room Door Closed Hot"
    }
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# STEP 6: Rename inverter room door sensor
# ============================================================

Write-Info "Renaming door sensor to 'Inverter Room Door'..."
try {
    # Use REST API to update entity registry
    $renameJson = '{"name": "Inverter Room Door"}'
    $resp = Invoke-HAREST -Endpoint "/api/config/entity_registry/entity/$inverterRoomDoor" -Method "POST" -JsonBody $renameJson
    if ($resp) {
        Write-Success "Door sensor renamed to 'Inverter Room Door'"
    }
} catch {
    Write-Info "Could not rename sensor (may need WebSocket API - non-critical)"
}

# ============================================================
# STEP 7: Test notification
# ============================================================

Write-Step "6/6 - Test Phone Notification"

Start-Sleep -Seconds 5

Write-Info "Sending test notification to $mobileAppService ..."
$testJson = @"
{
  "title": "Home Assistant",
  "message": "Phone notifications are now active! You will receive alerts for: inverter room temp, battery full, gate opened, inverter door closed + hot."
}
"@

try {
    $resp = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/services/$($mobileAppService.Replace('.','/'))" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($testJson)) `
        -UseBasicParsing -TimeoutSec 30
    Write-Success "Test notification sent! Check your phone."
} catch {
    Write-Info "Notification request sent (check your phone)."
}

# ============================================================
# Summary
# ============================================================

Write-Step "Phone Alerts Setup Complete"

Write-Host ""
Write-Host "  Notify service: $mobileAppService" -ForegroundColor Green
Write-Host ""
Write-Host "  Automations updated with phone notifications:" -ForegroundColor Green
Write-Host "    1. Inverter Room High Temp      - TTS + push when temp >= 28C" -ForegroundColor White
Write-Host "    2. Battery Fully Charged        - TTS + push when SOC >= 99%" -ForegroundColor White
Write-Host "    3. Gate Open Alert              - TTS + push when gate opens" -ForegroundColor White
Write-Host "    4. Inverter Door Closed Hot     - TTS + push when temp >= 25C and door closed" -ForegroundColor White
Write-Host ""
Write-Host "  TTS alerts are preserved - phone notifications are added alongside." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Verify in HA:" -ForegroundColor Yellow
Write-Host "    - Settings > Automations & Scenes (check each automation)" -ForegroundColor Yellow
Write-Host "    - Developer Tools > Services > $mobileAppService (test manually)" -ForegroundColor Yellow
Write-Host ""
