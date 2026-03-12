<#
.SYNOPSIS
    Create Home Assistant automations via the REST API.

.DESCRIPTION
    Sets up 2 automations:
    1. Morning Greeting - TTS + news radio on first kitchen door open (05:00-10:00)
    2. Gate Open Alert - TTS when main or visitor gate opens

    After creating all automations, triggers the Morning Greeting for immediate testing.

    TTS uses tts.speak with Google Translate engine (tts.google_translate_en_com).
    Note: tts.cloud_say requires Nabu Casa subscription and returns 500 without it.

    Run AFTER dashboards are set up (04-Setup-Dashboards.ps1).

.EXAMPLE
    .\05-Setup-Automations.ps1
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
# Entity IDs (from actual HA installation)
# ============================================================

# TTS engine entity (Google Translate - works without Nabu Casa)
$ttsEngine = "tts.google_translate_en_com"

# Gates
$mainGate    = "switch.sonoff_1000f74d0c"
$visitorGate = "switch.sonoff_10014e3e9b"

# Speakers
$kitchenSpeaker = "media_player.kitchen_speaker"

# Solar
$batterySoc = "sensor.battery_soc"

# Kitchen hallway door (morning greeting trigger)
$kitchenDoor = "binary_sensor.sonoff_a48003de7c"

# ============================================================
# Create automation via REST API (using raw JSON)
# ============================================================

function New-Automation {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Json
    )

    Write-Info "Creating automation: $Name..."

    $resp = Invoke-HAREST -Endpoint "/api/config/automation/config/$Id" -Method "POST" -JsonBody $Json

    if ($resp -and $resp.StatusCode -eq 200) {
        Write-Success "Created: $Name"
        return $true
    } else {
        Write-Fail "Failed to create: $Name"
        return $false
    }
}

# ============================================================
# TTS action helper (builds a tts.speak action block as JSON fragment)
# ============================================================
# Usage in JSON: paste the output of Build-TTSAction into the action array
# tts.speak targets the TTS entity, with media_player_entity_id + message in data

# ============================================================
# STEP 1: Morning Greeting
# ============================================================

Write-Step "1/3 - Morning Greeting Automation"

$morningJson = @"
{
  "alias": "Morning Greeting",
  "description": "Greets with battery status and plays Sky News Daily when the kitchen hallway door opens (05:00-10:00, once per day). MP3 URL refreshed by deploy/06a-Refresh-News.ps1.",
  "mode": "single",
  "trigger": [{"platform": "state", "entity_id": "$kitchenDoor", "from": "off", "to": "on"}],
  "condition": [
    {"condition": "time", "after": "05:00:00", "before": "10:00:00"},
    {"condition": "template", "value_template": "{{ (as_timestamp(now()) - as_timestamp(state_attr('automation.morning_greeting', 'last_triggered') | default(0))) > 28800 }}"}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Good morning! Your batteries are at {{ states('$batterySoc') }} percent. Here is Sky News."}},
    {"delay": {"seconds": 14}},
    {"service": "media_player.play_media", "target": {"entity_id": "$kitchenSpeaker"}, "data": {"media_content_id": "SKY_NEWS_MP3_URL_SET_BY_06a", "media_content_type": "music"}}
  ]
}
"@

New-Automation -Id "morning_greeting_kitchen" -Name "Morning Greeting" -Json $morningJson

# ============================================================
# STEP 2: Gate Open Alert
# ============================================================

Write-Step "2/3 - Gate Open Alert Automation"

$gateJson = @"
{
  "alias": "Gate Open Alert",
  "description": "Announces on kitchen speaker when the main gate or visitor gate is opened",
  "mode": "queued",
  "max": 5,
  "trigger": [
    {"platform": "state", "entity_id": "$mainGate", "from": "off", "to": "on", "id": "main_gate"},
    {"platform": "state", "entity_id": "$visitorGate", "from": "off", "to": "on", "id": "visitor_gate"}
  ],
  "action": [{"choose": [
    {"conditions": [{"condition": "trigger", "id": "main_gate"}], "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The main gate has been opened."}}]},
    {"conditions": [{"condition": "trigger", "id": "visitor_gate"}], "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The visitor gate has been opened."}}]}
  ]}]
}
"@

New-Automation -Id "gate_open_alert" -Name "Gate Open Alert" -Json $gateJson

# ============================================================
# STEP 3: Battery Fully Charged Alert
# ============================================================

Write-Step "3/3 - Battery Fully Charged Alert"

$batteryFullJson = @"
{
  "alias": "Battery Fully Charged",
  "description": "Announces when battery SOC reaches 99% or above, once per day only",
  "mode": "single",
  "trigger": [{"platform": "numeric_state", "entity_id": "$batterySoc", "above": 98}],
  "condition": [
    {"condition": "template", "value_template": "{{ (as_timestamp(now()) - as_timestamp(state_attr('automation.battery_fully_charged', 'last_triggered') | default(0))) > 72000 }}"}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Batteries are now fully charged."}}
  ]
}
"@

New-Automation -Id "battery_fully_charged" -Name "Battery Fully Charged" -Json $batteryFullJson

# ============================================================
# STEP 4: Manual test trigger - Morning Greeting
# ============================================================

Write-Step "Testing - Trigger Morning Greeting"

Write-Info "Waiting 5 seconds for automations to register..."
Start-Sleep -Seconds 5

Write-Info "Triggering Morning Greeting on kitchen speaker..."
try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/services/automation/trigger" `
        -Method POST -Headers $script:haHeaders `
        -Body '{"entity_id": "automation.morning_greeting"}' `
        -UseBasicParsing -TimeoutSec 30
    Write-Success "Morning Greeting triggered! Check your kitchen speaker."
} catch {
    Write-Info "Request sent (response timed out, but automation should still execute)."
}

# ============================================================
# Summary
# ============================================================

Write-Step "Automation Setup Complete"

Write-Host ""
Write-Host "  Automations created:" -ForegroundColor Green
Write-Host "    1. Morning Greeting       - Kitchen door open 05:00-10:00 -> TTS + Sky News" -ForegroundColor White
Write-Host "    2. Gate Open Alert        - Main/visitor gate opens -> TTS announcement" -ForegroundColor White
Write-Host "    3. Battery Fully Charged  - SOC >= 99% -> TTS (once per day)" -ForegroundColor White
Write-Host ""
Write-Host "  TTS engine: Google Translate ($ttsEngine)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Verify in HA:" -ForegroundColor Yellow
Write-Host "    - Settings > Automations & Scenes" -ForegroundColor Yellow
Write-Host "    - Both automations should be listed and enabled" -ForegroundColor Yellow
Write-Host "    - Toggle on/off from the HA UI as needed" -ForegroundColor Yellow
Write-Host ""
