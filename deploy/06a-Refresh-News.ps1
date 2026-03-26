<#
.SYNOPSIS
    Refresh the Sky News Daily episode URL in HA automations and scripts.

.DESCRIPTION
    Fetches the latest Sky News Daily podcast episode from the RSS feed
    and updates the Morning Greeting automation and dashboard scripts
    with the new MP3 URL.

    Run this daily (e.g., via Windows Task Scheduler at 04:30) to ensure
    the morning greeting always plays the latest episode.

    To set up as a scheduled task (run as admin):
    schtasks /create /tn "HA-RefreshNews" /tr "powershell -ExecutionPolicy Bypass -File C:\Work\HomeAssistantProject\deploy\06a-Refresh-News.ps1" /sc daily /st 04:30 /ru SYSTEM

.EXAMPLE
    .\06a-Refresh-News.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

$script:haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

# ============================================================
# Entity IDs
# ============================================================

$kitchenSpeaker = "media_player.kitchen_speaker"
$kitchenDoor    = "binary_sensor.sonoff_a48003de7c"
$ttsEngine      = "tts.google_translate_en_com"
$batterySoc     = "sensor.battery_soc"
$homeGroup      = "media_player.home_speakers"

# ============================================================
# Fetch latest Sky News episode
# ============================================================

$skyRssUrl = "https://feeds.captivate.fm/sky-news-daily/"

Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Fetching Sky News Daily RSS..."
$rssText = (Invoke-WebRequest -Uri $skyRssUrl -UseBasicParsing -TimeoutSec 15).Content

if ($rssText -match 'enclosure[^>]*url="([^"]+)"') {
    $skyMp3 = $matches[1] -replace '&amp;', '&'
} else {
    Write-Host "[ERROR] Could not extract MP3 URL from RSS feed"
    exit 1
}

if ($rssText -match '<item>[\s\S]*?<title>([^<]+)</title>') {
    $episodeTitle = $matches[1]
} else {
    $episodeTitle = "Unknown"
}

Write-Host "[OK] Episode: $episodeTitle"
Write-Host "[OK] MP3: $skyMp3"

# ============================================================
# Update Morning Greeting automation
# ============================================================

Write-Host "Updating Morning Greeting automation..."

$morningJson = @"
{
  "alias": "Morning Greeting",
  "description": "Greets with battery status and plays Sky News Daily when the kitchen hallway door opens (05:00-10:00, once per day)",
  "mode": "single",
  "trigger": [{"platform": "state", "entity_id": "$kitchenDoor", "from": "off", "to": "on"}],
  "condition": [
    {"condition": "time", "after": "05:00:00", "before": "10:00:00"},
    {"condition": "template", "value_template": "{{ (as_timestamp(now()) - as_timestamp(state_attr('automation.morning_greeting', 'last_triggered') | default(0))) > 28800 }}"}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Good morning! Your batteries are at {{ states('$batterySoc') }} percent. {% if state_attr('sensor.weather_briefing', 'tts_briefing') not in [None, ''] %}{{ state_attr('sensor.weather_briefing', 'tts_briefing') }} {% elif state_attr('sensor.weather_briefing', 'tts_text') not in [None, ''] %}{{ state_attr('sensor.weather_briefing', 'tts_text') }} {% elif states('sensor.weather_briefing') not in ['unknown', 'unavailable', 'Waiting for first weather update'] %}{{ states('sensor.weather_briefing') }} {% endif %}{% if state_attr('sensor.energy_schedule', 'tts_summary') not in [None, ''] %}{{ state_attr('sensor.energy_schedule', 'tts_summary') }} {% endif %}Here is Sky News."}},
    {"wait_for_trigger": [{"platform": "state", "entity_id": "media_player.kitchen_speaker", "from": "playing", "to": "idle"}], "timeout": {"seconds": 60}},
    {"service": "media_player.play_media", "target": {"entity_id": "$kitchenSpeaker"}, "data": {"media_content_id": "$skyMp3", "media_content_type": "music"}}
  ]
}
"@

try {
    $resp = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/morning_greeting_kitchen" -Method POST -Headers $script:haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($morningJson)) -UseBasicParsing -TimeoutSec 60
    Write-Host "[OK] Morning Greeting updated"
} catch {
    Write-Host "[WARN] Automation update may have timed out (usually still applies)"
}

# ============================================================
# Update scripts
# ============================================================

Write-Host "Updating scripts..."

$scripts = @(
    @{
        Id = "play_news_kitchen"
        Json = @"
{
  "alias": "Play News Kitchen",
  "description": "Play Sky News Daily on the kitchen speaker",
  "icon": "mdi:newspaper",
  "mode": "single",
  "sequence": [
    {"service": "media_player.play_media", "target": {"entity_id": "$kitchenSpeaker"}, "data": {"media_content_id": "$skyMp3", "media_content_type": "music"}}
  ]
}
"@
    },
    @{
        Id = "play_news_all_speakers"
        Json = @"
{
  "alias": "Play News All Speakers",
  "description": "Play Sky News Daily on all speakers",
  "icon": "mdi:newspaper-variant-multiple",
  "mode": "single",
  "sequence": [
    {"service": "media_player.play_media", "target": {"entity_id": "$homeGroup"}, "data": {"media_content_id": "$skyMp3", "media_content_type": "music"}}
  ]
}
"@
    }
)

foreach ($s in $scripts) {
    try {
        $null = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/script/config/$($s.Id)" -Method POST -Headers $script:haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($s.Json)) -UseBasicParsing -TimeoutSec 60
        Write-Host "[OK] $($s.Id)"
    } catch {
        Write-Host "[WARN] $($s.Id) may have timed out"
    }
}

Write-Host ""
Write-Host "[DONE] Sky News Daily refreshed: $episodeTitle"
