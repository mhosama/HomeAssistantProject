<#
.SYNOPSIS
    Create the Good Night automation via the HA REST API.

.DESCRIPTION
    Triggered when the kitchen hallway door CLOSES between 20:00-02:00 (once per day).
    Actions:
    1. Turn off kitchen lights
    2. Wait 30 seconds
    3. Set bedroom speaker volume to 40%
    4. TTS "Good night" on bedroom speaker
    5. TTS battery SOC percentage
    6. TTS gate and garage door status

    Run AFTER 05-Setup-Automations.ps1.

.EXAMPLE
    .\05c-Setup-GoodNight.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# Output helpers
# ============================================================

function Write-Step  { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Info  { param([string]$msg) Write-Host "   $msg" -ForegroundColor Gray }
function Write-Success { param([string]$msg) Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Fail  { param([string]$msg) Write-Host "   [FAIL] $msg" -ForegroundColor Red }

# ============================================================
# HA API helpers
# ============================================================

$script:haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

function Invoke-HAREST {
    param([string]$Endpoint, [string]$Method = "GET", [string]$JsonBody)
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $params = @{ Uri = $uri; Method = $Method; Headers = $script:haHeaders; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($JsonBody) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($JsonBody) }
    try { return Invoke-WebRequest @params } catch { Write-Fail "API call failed: $Endpoint - $($_.Exception.Message)"; return $null }
}

# ============================================================
# Entity IDs
# ============================================================

$ttsEngine       = "tts.google_translate_en_com"
$bedroomSpeaker  = "media_player.bedroom_speaker"
$kitchenDoor     = "binary_sensor.sonoff_a48003de7c"
$kitchenLight    = "switch.sonoff_1000feaf53_2"
$batterySoc      = "sensor.battery_soc"

# ============================================================
# Create the Good Night automation
# ============================================================

Write-Step "Creating Good Night Automation"

# Build the TTS message for gate/garage status using Jinja templates
# sensor.main_gate_status / sensor.visitor_gate_status -> "open" or "closed"
# sensor.left_garage_door / sensor.right_garage_door -> "open" or "closed"

$goodNightJson = @"
{
  "alias": "Good Night",
  "description": "Good night routine when kitchen hallway door closes (20:00-02:00, once per day). Turns off kitchen lights, then bedroom TTS with battery/gate/garage status.",
  "mode": "single",
  "trigger": [{"platform": "state", "entity_id": "$kitchenDoor", "from": "on", "to": "off"}],
  "condition": [
    {"condition": "time", "after": "20:00:00", "before": "02:00:00"},
    {"condition": "template", "value_template": "{% set last = state_attr('automation.good_night', 'last_triggered') %}{{ last is none or (as_timestamp(now()) - as_timestamp(last)) > 28800 }}"}
  ],
  "action": [
    {"service": "switch.turn_off", "target": {"entity_id": "$kitchenLight"}},
    {"delay": {"seconds": 30}},
    {"service": "media_player.volume_set", "target": {"entity_id": "$bedroomSpeaker"}, "data": {"volume_level": 0.4}},
    {"delay": {"seconds": 2}},
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$bedroomSpeaker", "message": "Good night. Your batteries are at {{ states('$batterySoc') }} percent. {% set mg = states('sensor.main_gate_status') %}{% set vg = states('sensor.visitor_gate_status') %}{% set lg = states('sensor.left_garage_door') %}{% set rg = states('sensor.right_garage_door') %}{% set issues = [] %}{% if mg == 'open' %}{% set issues = issues + ['The main gate is open'] %}{% endif %}{% if vg == 'open' %}{% set issues = issues + ['The visitor gate is open'] %}{% endif %}{% if lg == 'open' %}{% set issues = issues + ['The left garage door is open'] %}{% endif %}{% if rg == 'open' %}{% set issues = issues + ['The right garage door is open'] %}{% endif %}{% if issues | length > 0 %}{{ issues | join('. ') }}.{% else %}All gates and garage doors are closed.{% endif %}"}}
  ]
}
"@

Write-Info "Sending automation config..."
$resp = Invoke-HAREST -Endpoint "/api/config/automation/config/good_night_routine" -Method "POST" -JsonBody $goodNightJson

if ($resp -and $resp.StatusCode -eq 200) {
    Write-Success "Created: Good Night automation"
} else {
    Write-Fail "Failed to create Good Night automation"
}

# ============================================================
# Summary
# ============================================================

Write-Step "Good Night Automation Setup Complete"

Write-Host ""
Write-Host "  Automation created:" -ForegroundColor Green
Write-Host "    Good Night - Kitchen door closes 20:00-02:00 -> lights off + bedroom TTS" -ForegroundColor White
Write-Host ""
Write-Host "  Actions:" -ForegroundColor Yellow
Write-Host "    1. Turn off kitchen light ($kitchenLight)" -ForegroundColor White
Write-Host "    2. Wait 30 seconds" -ForegroundColor White
Write-Host "    3. Set bedroom speaker volume to 40%" -ForegroundColor White
Write-Host "    4. TTS: Good night" -ForegroundColor White
Write-Host "    5. TTS: Battery percentage" -ForegroundColor White
Write-Host "    6. TTS: Gate and garage door status" -ForegroundColor White
Write-Host ""
Write-Host "  Trigger: Kitchen hallway door closes ($kitchenDoor)" -ForegroundColor Yellow
Write-Host "  Window:  20:00 - 02:00 (once per day, 8h cooldown)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Verify in HA: Settings > Automations & Scenes" -ForegroundColor Yellow
Write-Host ""
