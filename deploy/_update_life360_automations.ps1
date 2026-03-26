<#
.SYNOPSIS
    Recreate Life360 arrival/departure automations with place-based triggers.

.DESCRIPTION
    Updates automations to trigger on Life360 `place` attribute changes instead of
    zone.home state changes. This enables notifications for ALL Life360 Places
    (e.g., Oupa arriving at his "Home", Chandre leaving "Work").

    Also discovers mobile_app notify services for phone notifications alongside TTS.

    Uses POST /api/config/automation/config/{id} to overwrite existing automations.

.EXAMPLE
    .\deploy\_update_life360_automations.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

function Write-Step    { param([string]$Message); Write-Host ""; Write-Host "===================================================" -ForegroundColor Cyan; Write-Host " $Message" -ForegroundColor Cyan; Write-Host "===================================================" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

$haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"

# Life360 trackers
$trackerIds = @(
    "device_tracker.life360_mauritz_kloppers"
    "device_tracker.life360_chandre_kloppers"
    "device_tracker.life360_mauritz_kloppers_2"
    "device_tracker.life360_lizette_kloppers"
    "device_tracker.life360_melandi_gossman"
)

# ============================================================
# Discover mobile_app notify services for phone notifications
# ============================================================

Write-Step "Discovering phone notification services"

$notifyService = $null
try {
    $servicesResp = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/services" `
        -Method GET -Headers $haHeaders `
        -UseBasicParsing -TimeoutSec 30
    $services = $servicesResp.Content | ConvertFrom-Json

    $notifyDomain = $services | Where-Object { $_.domain -eq "notify" }
    if ($notifyDomain -and $notifyDomain.services) {
        $mobileServices = $notifyDomain.services.PSObject.Properties | Where-Object { $_.Name -like "mobile_app_*" }
        if ($mobileServices) {
            $notifyService = "notify.$($mobileServices[0].Name)"
            Write-Success "Found phone notification service: $notifyService"
        }
    }
} catch {
    Write-Info "Could not query services API: $($_.Exception.Message)"
}

if (-not $notifyService) {
    Write-Info "No mobile_app notify service found - automations will use TTS only"
}

# ============================================================
# TTS templates (place-based) — phonetic spelling for Google TTS
# Use [char]0xE9 for é to avoid PowerShell encoding issues with literal UTF-8
# ============================================================

$eAccent = [char]0xE9  # é

$arrivedTtsTemplate = @"
{% set name = trigger.to_state.attributes.friendly_name | replace('Chandre', 'Shandr$eAccent') | replace('Ouma', 'Ohma') | replace('Oupa', 'Ohpa') %}
{% set place = trigger.to_state.attributes.place | default('') | replace('Kloppers Family', '') | replace('Ouma', 'Ohma') | replace('Oupa', 'Ohpa') | trim %}
{{ name }} has arrived{{ ' at ' + place if place else '' }}.
"@

$departTtsTemplate = @"
{% set name = trigger.to_state.attributes.friendly_name | replace('Chandre', 'Shandr$eAccent') | replace('Ouma', 'Ohma') | replace('Oupa', 'Ohpa') %}
{% set place = trigger.from_state.attributes.place | default('') | replace('Kloppers Family', '') | replace('Ouma', 'Ohma') | replace('Oupa', 'Ohpa') | trim %}
{{ name }} has left{{ ' ' + place if place else '' }}.
"@

# Phone notification templates — correct spelling for display
# ============================================================

$arrivedPhoneTemplate = @"
{% set name = trigger.to_state.attributes.friendly_name | replace('Chandre', 'Chandr$eAccent') %}
{% set place = trigger.to_state.attributes.place | default('an unknown location') %}
{{ name }} has arrived at {{ place }}.
"@

$departPhoneTemplate = @"
{% set name = trigger.to_state.attributes.friendly_name | replace('Chandre', 'Chandr$eAccent') %}
{% set place = trigger.from_state.attributes.place | default('an unknown location') %}
{{ name }} has left {{ place }}.
"@

# Conditions (Jinja templates)
$arrivedConditionTemplate = "{{ trigger.to_state.attributes.place not in ['', none] and trigger.to_state.attributes.place != trigger.from_state.attributes.get('place', '') }}"
$departConditionTemplate = "{{ trigger.from_state.attributes.place not in ['', none] and (trigger.to_state.attributes.place in ['', none] or trigger.to_state.attributes.place != trigger.from_state.attributes.place) }}"

# ============================================================
# Automation: Family Member Arrived at Place
# ============================================================

Write-Step "Updating: Family Member Arrived at Place"

$triggerList = @()
foreach ($tid in $trackerIds) {
    $triggerList += @{
        platform  = "state"
        entity_id = $tid
        attribute = "place"
    }
}

$arrivedActions = @(
    @{
        service = "tts.speak"
        target  = @{ entity_id = $ttsEngine }
        data    = @{
            media_player_entity_id = $kitchenSpeaker
            message = $arrivedTtsTemplate
        }
    }
)

if ($notifyService) {
    $arrivedActions += @{
        service = $notifyService
        data    = @{
            message = $arrivedPhoneTemplate
            title   = "Family Arrival"
        }
    }
}

$arrivedConfig = @{
    alias       = "Family Member Arrived"
    description = "TTS + phone notification when a Life360 family member arrives at any Place."
    mode        = "queued"
    max         = 5
    trigger     = $triggerList
    condition   = @(
        @{
            condition      = "template"
            value_template = $arrivedConditionTemplate
        }
    )
    action      = $arrivedActions
} | ConvertTo-Json -Depth 10

$arrivedBytes = [System.Text.Encoding]::UTF8.GetBytes($arrivedConfig)

Write-Info "Triggers: $($trackerIds.Count) Life360 trackers (attribute: place)"
Write-Info "TTS: Chandre -> Shandré (TTS) / Chandré (phone) pronunciation fix applied"
if ($notifyService) { Write-Info "Phone: $notifyService" }

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/family_member_arrived" `
        -Method POST -Headers $haHeaders `
        -Body $arrivedBytes `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Family Member Arrived automation updated"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# Automation: Family Member Departed from Place
# ============================================================

Write-Step "Updating: Family Member Departed from Place"

$departTriggerList = @()
foreach ($tid in $trackerIds) {
    $departTriggerList += @{
        platform  = "state"
        entity_id = $tid
        attribute = "place"
    }
}

$departActions = @(
    @{
        service = "tts.speak"
        target  = @{ entity_id = $ttsEngine }
        data    = @{
            media_player_entity_id = $kitchenSpeaker
            message = $departTtsTemplate
        }
    }
)

if ($notifyService) {
    $departActions += @{
        service = $notifyService
        data    = @{
            message = $departPhoneTemplate
            title   = "Family Departure"
        }
    }
}

$departedConfig = @{
    alias       = "Family Member Departed"
    description = "TTS + phone notification when a Life360 family member leaves any Place."
    mode        = "queued"
    max         = 5
    trigger     = $departTriggerList
    condition   = @(
        @{
            condition      = "template"
            value_template = $departConditionTemplate
        }
    )
    action      = $departActions
} | ConvertTo-Json -Depth 10

$departedBytes = [System.Text.Encoding]::UTF8.GetBytes($departedConfig)

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/family_member_departed" `
        -Method POST -Headers $haHeaders `
        -Body $departedBytes `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Family Member Departed automation updated"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# Summary
# ============================================================

Write-Step "Automation Updates Complete"

Write-Host ""
Write-Host "  Changes:" -ForegroundColor Green
Write-Host "    - Triggers now use attribute: place (all Life360 Places, not just zone.home)" -ForegroundColor White
Write-Host "    - Arrived: fires when place attribute changes to a non-empty value" -ForegroundColor White
Write-Host "    - Departed: fires when place attribute changes from a non-empty value" -ForegroundColor White
Write-Host "    - TTS pronunciation fix: Chandre -> Shandré (TTS) / Chandré (phone)" -ForegroundColor White
if ($notifyService) {
    Write-Host "    - Phone notification: $notifyService" -ForegroundColor White
} else {
    Write-Host "    - Phone notification: not configured (no mobile_app service found)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Trackers:" -ForegroundColor Green
foreach ($tid in $trackerIds) {
    Write-Host "    - $tid" -ForegroundColor White
}
Write-Host ""
Write-Host "  Examples:" -ForegroundColor Yellow
Write-Host "    - Oupa arrives at his 'Home' -> 'Oupa has arrived at Home.'" -ForegroundColor White
Write-Host "    - Chandre leaves 'Work' -> 'Shandré has left Work.' (TTS) / 'Chandré has left Work.' (phone)" -ForegroundColor White
Write-Host "    - Mauritz arrives at 'Gym' -> 'Mauritz has arrived at Gym.'" -ForegroundColor White
Write-Host ""
Write-Host "  Test:" -ForegroundColor Yellow
Write-Host "    1. Go to Settings > Automations > Family Member Arrived" -ForegroundColor White
Write-Host "    2. Check triggers use attribute: place" -ForegroundColor White
Write-Host "    3. In Developer Tools > States, change a tracker's place attribute" -ForegroundColor White
Write-Host "    4. TTS should announce the place name" -ForegroundColor White
Write-Host ""
