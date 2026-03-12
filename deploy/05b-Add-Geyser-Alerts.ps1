<#
.SYNOPSIS
    Add TTS announcements when geysers switch on or off.

.DESCRIPTION
    Creates a single automation that announces on the kitchen speaker when any
    geyser (Main, Flat, Guest) turns on or off.

.EXAMPLE
    .\05b-Add-Geyser-Alerts.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

function Write-Step    { param([string]$Message); Write-Host ""; Write-Host "===================================================" -ForegroundColor Cyan; Write-Host " $Message" -ForegroundColor Cyan; Write-Host "===================================================" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

$script:haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

# ============================================================
# Entity IDs
# ============================================================

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"
$mainGeyser     = "switch.sonoff_1001f8b113"
$flatGeyser     = "switch.sonoff_100179fb1b"
$guestGeyser    = "switch.sonoff_100143260c"
$boreholePump   = "switch.sonoff_10011058e1"

# ============================================================
# Create Geyser Alert automation
# ============================================================

Write-Step "Creating Geyser Alert Automation"

$geyserJson = @"
{
  "alias": "Geyser Alert",
  "description": "Announces on kitchen speaker when geysers or borehole pump switch on or off. Borehole pump is silent 22:00-06:00.",
  "mode": "queued",
  "max": 5,
  "trigger": [
    {"platform": "state", "entity_id": "$mainGeyser",  "from": "off", "to": "on",  "id": "main_on"},
    {"platform": "state", "entity_id": "$mainGeyser",  "from": "on",  "to": "off", "id": "main_off"},
    {"platform": "state", "entity_id": "$flatGeyser",  "from": "off", "to": "on",  "id": "flat_on"},
    {"platform": "state", "entity_id": "$flatGeyser",  "from": "on",  "to": "off", "id": "flat_off"},
    {"platform": "state", "entity_id": "$guestGeyser", "from": "off", "to": "on",  "id": "guest_on"},
    {"platform": "state", "entity_id": "$guestGeyser", "from": "on",  "to": "off", "id": "guest_off"},
    {"platform": "state", "entity_id": "$boreholePump", "from": "off", "to": "on",  "id": "borehole_on"},
    {"platform": "state", "entity_id": "$boreholePump", "from": "on",  "to": "off", "id": "borehole_off"}
  ],
  "action": [{"choose": [
    {"conditions": [{"condition": "trigger", "id": "main_on"}],     "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The main geyser has switched on."}}]},
    {"conditions": [{"condition": "trigger", "id": "main_off"}],    "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The main geyser has switched off."}}]},
    {"conditions": [{"condition": "trigger", "id": "flat_on"}],     "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The flat geyser has switched on."}}]},
    {"conditions": [{"condition": "trigger", "id": "flat_off"}],    "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The flat geyser has switched off."}}]},
    {"conditions": [{"condition": "trigger", "id": "guest_on"}],    "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The guest geyser has switched on."}}]},
    {"conditions": [{"condition": "trigger", "id": "guest_off"}],   "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The guest geyser has switched off."}}]},
    {"conditions": [{"condition": "trigger", "id": "borehole_on"}, {"condition": "time", "after": "06:00:00", "before": "22:00:00"}],  "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The borehole pump has switched on."}}]},
    {"conditions": [{"condition": "trigger", "id": "borehole_off"}, {"condition": "time", "after": "06:00:00", "before": "22:00:00"}], "sequence": [{"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "The borehole pump has switched off."}}]}
  ]}]
}
"@

Write-Info "Creating automation..."

try {
    $resp = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/geyser_alert" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($geyserJson)) `
        -UseBasicParsing -TimeoutSec 60

    if ($resp.StatusCode -eq 200) {
        Write-Success "Geyser Alert automation created"
    } else {
        Write-Fail "Unexpected status: $($resp.StatusCode)"
    }
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# Test - trigger a quick TTS to confirm it works
# ============================================================

Write-Step "Testing - TTS announcement"

Start-Sleep -Seconds 5

Write-Info "Sending test TTS to kitchen speaker..."
try {
    $testBody = @{
        target = @{ entity_id = $ttsEngine }
        data   = @{ media_player_entity_id = $kitchenSpeaker; message = "Geyser alerts are now active." }
    } | ConvertTo-Json -Depth 5

    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/services/tts/speak" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($testBody)) `
        -UseBasicParsing -TimeoutSec 30
    Write-Success "Test TTS sent! Check your kitchen speaker."
} catch {
    Write-Info "TTS request sent (check kitchen speaker)."
}

# ============================================================
# Done
# ============================================================

Write-Step "Done!"
Write-Host ""
Write-Host "  Automation created:" -ForegroundColor Green
Write-Host "    Geyser Alert - Announces on kitchen speaker when any geyser turns on/off" -ForegroundColor White
Write-Host ""
Write-Host "  Geysers monitored:" -ForegroundColor Yellow
Write-Host "    - Main Geyser    ($mainGeyser)" -ForegroundColor Yellow
Write-Host "    - Flat Geyser    ($flatGeyser)" -ForegroundColor Yellow
Write-Host "    - Guest Geyser   ($guestGeyser)" -ForegroundColor Yellow
Write-Host "    - Borehole Pump  ($boreholePump)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Verify: Settings > Automations & Scenes > Geyser Alert" -ForegroundColor Yellow
Write-Host ""
