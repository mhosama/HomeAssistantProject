<#
.SYNOPSIS
    Set up Sky News Daily playback on Google Cast speakers.

.DESCRIPTION
    Fetches the latest Sky News Daily podcast episode from the RSS feed,
    then updates the Morning Greeting automation, dashboard scripts, and
    Media Dashboard to play Sky News.

    Also creates a companion script (06a-Refresh-News.ps1) that can be
    run daily via Windows Task Scheduler to keep the episode URL fresh.

    Google Cast speakers can't play RSS feed URLs directly or queue media,
    so we fetch the direct MP3 URL and hardcode it in the automation/scripts.

.EXAMPLE
    .\06-Setup-News.ps1
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

$kitchenSpeaker = "media_player.kitchen_speaker"
$kitchenDoor    = "binary_sensor.sonoff_a48003de7c"
$ttsEngine      = "tts.google_translate_en_com"
$batterySoc     = "sensor.battery_soc"

$media = @{
    SamsungTV       = "media_player.samsung_qa65q70bakxxa"
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
# STEP 1: Fetch latest Sky News Daily episode
# ============================================================

Write-Step "Step 1: Fetching Latest Sky News Daily Episode"

$skyRssUrl = "https://feeds.captivate.fm/sky-news-daily/"

Write-Info "Fetching RSS feed: $skyRssUrl"
$rssText = (Invoke-WebRequest -Uri $skyRssUrl -UseBasicParsing -TimeoutSec 15).Content

if ($rssText -match 'enclosure[^>]*url="([^"]+)"') {
    $skyMp3 = $matches[1] -replace '&amp;', '&'
} else {
    Write-Fail "Could not extract MP3 URL from Sky News RSS feed"
    exit 1
}

if ($rssText -match '<item>[\s\S]*?<title>([^<]+)</title>') {
    $episodeTitle = $matches[1]
} else {
    $episodeTitle = "Unknown"
}

Write-Success "Latest episode: $episodeTitle"
Write-Info "MP3 URL: $skyMp3"

# ============================================================
# STEP 2: Connect + Update Morning Greeting Automation
# ============================================================

Write-Step "Step 2: Updating Morning Greeting Automation"

Connect-HAWS

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
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Good morning! Your batteries are at {{ states('$batterySoc') }} percent. Here is Sky News."}},
    {"delay": {"seconds": 14}},
    {"service": "media_player.play_media", "target": {"entity_id": "$kitchenSpeaker"}, "data": {"media_content_id": "$skyMp3", "media_content_type": "music"}}
  ]
}
"@

Write-Info "Updating Morning Greeting automation..."
$resp = Invoke-HAREST -Endpoint "/api/config/automation/config/morning_greeting_kitchen" -Method "POST" -JsonBody $morningJson

if ($resp -and $resp.StatusCode -eq 200) {
    Write-Success "Morning Greeting updated with Sky News Daily"
} else {
    Write-Fail "Failed to update Morning Greeting"
}

# ============================================================
# STEP 3: Update Script Entities
# ============================================================

Write-Step "Step 3: Updating Script Entities"

$scripts = @(
    @{
        Id = "play_news_kitchen"
        Name = "Play News Kitchen"
        Json = @"
{
  "alias": "Play News Kitchen",
  "description": "Play Sky News Daily on the kitchen speaker",
  "icon": "mdi:newspaper",
  "mode": "single",
  "sequence": [
    {"service": "media_player.play_media", "target": {"entity_id": "$($media.Kitchen)"}, "data": {"media_content_id": "$skyMp3", "media_content_type": "music"}}
  ]
}
"@
    },
    @{
        Id = "play_news_all_speakers"
        Name = "Play News All Speakers"
        Json = @"
{
  "alias": "Play News All Speakers",
  "description": "Play Sky News Daily on all speakers",
  "icon": "mdi:newspaper-variant-multiple",
  "mode": "single",
  "sequence": [
    {"service": "media_player.play_media", "target": {"entity_id": "$($media.HomeGroup)"}, "data": {"media_content_id": "$skyMp3", "media_content_type": "music"}}
  ]
}
"@
    },
    @{
        Id = "stop_news"
        Name = "Stop News"
        Json = @"
{
  "alias": "Stop News",
  "description": "Stop whatever is playing on the kitchen speaker",
  "icon": "mdi:stop-circle",
  "mode": "single",
  "sequence": [
    {"service": "media_player.media_stop", "target": {"entity_id": "$($media.Kitchen)"}}
  ]
}
"@
    }
)

foreach ($s in $scripts) {
    Write-Info "Updating script: $($s.Name)..."
    $resp = Invoke-HAREST -Endpoint "/api/config/script/config/$($s.Id)" -Method "POST" -JsonBody $s.Json
    if ($resp -and $resp.StatusCode -eq 200) {
        Write-Success "Updated: $($s.Name)"
    } else {
        Write-Fail "Failed: $($s.Name)"
    }
}

# ============================================================
# STEP 4: Update Media Dashboard
# ============================================================

Write-Step "Step 4: Updating Media Dashboard"

$newsCard = @{
    type = "vertical-stack"
    title = "Sky News Daily"
    cards = @(
        @{
            type = "horizontal-stack"
            cards = @(
                @{
                    type = "button"
                    name = "Play News (Kitchen)"
                    icon = "mdi:newspaper"
                    tap_action = @{ action = "call-service"; service = "script/play_news_kitchen" }
                },
                @{
                    type = "button"
                    name = "Play News (All)"
                    icon = "mdi:newspaper-variant-multiple"
                    tap_action = @{ action = "call-service"; service = "script/play_news_all_speakers" }
                },
                @{
                    type = "button"
                    name = "Stop"
                    icon = "mdi:stop-circle"
                    tap_action = @{ action = "call-service"; service = "script/stop_news" }
                }
            )
        },
        @{
            type = "markdown"
            content = "Sky News Daily podcast. Episode refreshed automatically each morning."
        }
    )
}

$mediaConfig = @{
    title = "Media"
    views = @(
        @{
            title = "Media"; path = "media"; icon = "mdi:speaker-multiple"
            cards = @(
                $newsCard,
                @{
                    type = "vertical-stack"; title = "Samsung TV"
                    cards = @( @{ type = "media-control"; entity = $media.SamsungTV } )
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
if ($saveResp.success) { Write-Success "Media dashboard updated" } else { Write-Fail "Dashboard: $($saveResp.error.message)" }

# ============================================================
# Cleanup
# ============================================================

Disconnect-HAWS

# ============================================================
# Summary
# ============================================================

Write-Step "Sky News Setup Complete"

Write-Host ""
Write-Host "  Updated:" -ForegroundColor Green
Write-Host "    1. Morning Greeting automation  - TTS + Sky News Daily" -ForegroundColor White
Write-Host "    2. script.play_news_kitchen      - Play on kitchen speaker" -ForegroundColor White
Write-Host "    3. script.play_news_all_speakers  - Play on all speakers" -ForegroundColor White
Write-Host "    4. script.stop_news               - Stop playback" -ForegroundColor White
Write-Host "    5. Media Dashboard                - Sky News Daily card" -ForegroundColor White
Write-Host ""
Write-Host "  Current episode: $episodeTitle" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To keep the episode URL fresh, run 06a-Refresh-News.ps1 daily" -ForegroundColor Yellow
Write-Host "  or set up a Windows Scheduled Task (see script header for details)." -ForegroundColor Yellow
Write-Host ""
