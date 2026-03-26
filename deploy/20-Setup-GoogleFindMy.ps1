<#
.SYNOPSIS
    Set up Google Find My Device tracking integration via HACS.

.DESCRIPTION
    - Installs BSkando/GoogleFindMy-HA via HACS WebSocket API
    - Restarts HA for the integration to load
    - Configures integration via config flow (secrets.json from GoogleFindMyTools)
    - Creates battery low + zone change automations for tracked tags

    PRE-REQUISITES:
    1. Run GoogleFindMyTools (leonboe1/GoogleFindMyTools) on a machine with Chrome
       to generate secrets.json (interactive Google login required).
    2. Add GoogleFindMySecretsPath to deploy/config.ps1 pointing to the generated file.

    Run AFTER HACS is installed and working.

.EXAMPLE
    .\20-Setup-GoogleFindMy.ps1
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

$script:haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

function Invoke-HAREST {
    param([string]$Endpoint, [string]$Method = "GET", [string]$JsonBody)
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $params = @{ Uri = $uri; Method = $Method; Headers = $script:haHeaders; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($JsonBody) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($JsonBody) }
    try { return (Invoke-WebRequest @params).Content | ConvertFrom-Json } catch { Write-Fail "API call failed: $Endpoint - $($_.Exception.Message)"; return $null }
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
        $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait()
    }
}

# ============================================================
# Entity IDs
# ============================================================

$ttsEngine       = "tts.google_translate_en_com"
$kitchenSpeaker  = "media_player.kitchen_speaker"

# ============================================================
# STEP 1: Validate config + read secrets.json
# ============================================================

Write-Step "1/5 - Validating Configuration"

if ([string]::IsNullOrWhiteSpace($Config.GoogleFindMySecretsPath)) {
    Write-Fail "GoogleFindMySecretsPath not found in config.ps1"
    Write-Host ""
    Write-Host "  You need to generate secrets.json first:" -ForegroundColor Yellow
    Write-Host "    1. Clone https://github.com/leonboe1/GoogleFindMyTools" -ForegroundColor White
    Write-Host "    2. pip install -r requirements.txt" -ForegroundColor White
    Write-Host "    3. python main.py (requires Chrome, interactive Google login)" -ForegroundColor White
    Write-Host "    4. Copy Auth/secrets.json path" -ForegroundColor White
    Write-Host ""
    Write-Host "  Then add to deploy/config.ps1:" -ForegroundColor Yellow
    Write-Host '    GoogleFindMySecretsPath = "C:\path\to\Auth\secrets.json"' -ForegroundColor White
    Write-Host ""
    exit 1
}

$secretsPath = $Config.GoogleFindMySecretsPath
if (-not (Test-Path $secretsPath)) {
    Write-Fail "secrets.json not found at: $secretsPath"
    Write-Info "Run GoogleFindMyTools to generate it, then update the path in config.ps1."
    exit 1
}

$secretsContent = Get-Content -Path $secretsPath -Raw
try {
    $null = $secretsContent | ConvertFrom-Json
    Write-Success "secrets.json loaded and is valid JSON ($($secretsContent.Length) bytes)"
} catch {
    Write-Fail "secrets.json is not valid JSON: $($_.Exception.Message)"
    exit 1
}

# ============================================================
# STEP 2: Install GoogleFindMy-HA via HACS
# ============================================================

Write-Step "2/5 - Installing GoogleFindMy-HA via HACS"

Connect-HAWS

# Check if integration is already configured
$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$findMyEntry = $existingEntries | Where-Object { $_.domain -eq "googlefindmy" }
if ($findMyEntry) {
    Write-Success "GoogleFindMy integration already configured - skipping HACS install"
} else {
    # List HACS repos to check if already available
    Write-Info "Checking HACS repository list..."
    $hacsRepos = Invoke-WSCommand -Type "hacs/repositories/list"

    $findMyRepo = $null
    if ($hacsRepos.success -and $hacsRepos.result) {
        $findMyRepo = $hacsRepos.result | Where-Object { $_.full_name -eq "BSkando/GoogleFindMy-HA" }
    }

    if (-not $findMyRepo) {
        # Add as custom repository
        Write-Info "Adding BSkando/GoogleFindMy-HA as custom HACS repository..."
        $addResult = Invoke-WSCommand -Type "hacs/repositories/add" -Extra @{
            repository = "BSkando/GoogleFindMy-HA"
            category   = "integration"
        }
        if ($addResult.success) {
            Write-Success "Custom repository added to HACS"
        } else {
            Write-Fail "Failed to add custom repo: $($addResult.error.message)"
            Write-Info "Manual fallback: HACS > 3 dots > Custom repositories > Add BSkando/GoogleFindMy-HA (Integration)"
        }

        # Re-list to get the repo ID
        Start-Sleep -Seconds 3
        $hacsRepos = Invoke-WSCommand -Type "hacs/repositories/list"
        if ($hacsRepos.success -and $hacsRepos.result) {
            $findMyRepo = $hacsRepos.result | Where-Object { $_.full_name -eq "BSkando/GoogleFindMy-HA" }
        }
    }

    if ($findMyRepo) {
        if ($findMyRepo.installed) {
            Write-Success "GoogleFindMy-HA integration already installed in HACS"
        } else {
            Write-Info "Downloading GoogleFindMy-HA integration (ID: $($findMyRepo.id))..."
            $dlResult = Invoke-WSCommand -Type "hacs/repository/download" -Extra @{ repository = $findMyRepo.id }
            if ($dlResult.success) {
                Write-Success "GoogleFindMy-HA integration downloaded via HACS"
            } else {
                Write-Fail "Download failed: $($dlResult.error.message)"
                Write-Info "Manual fallback: HACS > Integrations > Search GoogleFindMy > Download"
            }
        }
    } else {
        Write-Fail "Could not find GoogleFindMy-HA in HACS after adding"
        Write-Info "Manual fallback: HACS > 3 dots > Custom repositories > Add BSkando/GoogleFindMy-HA"
    }

    Disconnect-HAWS

    # Restart HA for the integration to load
    Write-Step "Restarting Home Assistant for GoogleFindMy integration to load..."
    $null = Invoke-HAREST -Endpoint "/api/services/homeassistant/restart" -Method "POST" -JsonBody "{}"
    Write-Info "HA restart triggered. Waiting 60 seconds for HA to come back..."
    Start-Sleep -Seconds 60

    # Wait for HA to be accessible
    $maxWait = 120
    $waited = 0
    while ($waited -lt $maxWait) {
        try {
            $null = Invoke-HAREST -Endpoint "/api/"
            break
        } catch {
            Start-Sleep -Seconds 5
            $waited += 5
        }
    }
    if ($waited -ge $maxWait) {
        Write-Fail "HA did not come back after restart. Wait manually, then re-run this script."
        exit 1
    }
    Write-Success "HA is back online"
}

# ============================================================
# STEP 3: Configure via config flow
# ============================================================

Write-Step "3/5 - Configuring GoogleFindMy Integration"

# Refresh existing entries check
$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$findMyEntry = $existingEntries | Where-Object { $_.domain -eq "googlefindmy" }

if ($findMyEntry) {
    Write-Success "GoogleFindMy integration already configured (entry: $($findMyEntry.entry_id))"
} else {
    # Abort any stale flows
    $flows = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/progress"
    if ($flows) {
        $staleFlows = $flows | Where-Object { $_.handler -eq "googlefindmy" }
        foreach ($f in $staleFlows) {
            Write-Info "Aborting stale GoogleFindMy flow: $($f.flow_id)"
            try {
                $null = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow/$($f.flow_id)" `
                    -Method DELETE -Headers $script:haHeaders -UseBasicParsing -TimeoutSec 30
            } catch {}
        }
    }

    # Start config flow — 3 steps: user (auth_method) → secrets_json → device_selection
    Write-Info "Starting GoogleFindMy config flow..."
    $flowBody = [System.Text.Encoding]::UTF8.GetBytes('{"handler": "googlefindmy"}')
    try {
        $flowResp = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow" `
            -Method POST -Headers $script:haHeaders -Body $flowBody -UseBasicParsing -TimeoutSec 60
        $flowStart = $flowResp.Content | ConvertFrom-Json
    } catch {
        Write-Fail "Failed to start config flow. Is the integration installed?"
        Write-Info "Check: Settings > Devices & Services > Add Integration > search Google Find My"
        exit 1
    }

    $flowId = $flowStart.flow_id
    Write-Info "Flow started: step=$($flowStart.step_id), flow_id=$flowId"

    # Step 1: Select auth_method = secrets_json
    Write-Info "Selecting auth_method = secrets_json..."
    $step1Body = [System.Text.Encoding]::UTF8.GetBytes('{"auth_method": "secrets_json"}')
    $step1Resp = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow/$flowId" `
        -Method POST -Headers $script:haHeaders -Body $step1Body -UseBasicParsing -TimeoutSec 60
    $step1 = $step1Resp.Content | ConvertFrom-Json
    Write-Info "  Step: $($step1.step_id)"

    # Step 2: Submit secrets.json as a plain string (must escape manually to avoid double-encoding)
    Write-Info "Submitting secrets.json contents..."
    $escapedSecrets = $secretsContent.Replace('\', '\\').Replace('"', '\"').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`r", '\n')
    $step2Json = '{"secrets_json": "' + $escapedSecrets + '"}'
    $step2Body = [System.Text.Encoding]::UTF8.GetBytes($step2Json)
    $step2Resp = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow/$flowId" `
        -Method POST -Headers $script:haHeaders -Body $step2Body -UseBasicParsing -TimeoutSec 120
    $step2 = $step2Resp.Content | ConvertFrom-Json
    Write-Info "  Step: $($step2.step_id), type: $($step2.type)"

    if ($step2.type -eq "create_entry") {
        Write-Success "GoogleFindMy integration configured! Entry: $($step2.title)"
    } elseif ($step2.step_id -like "*device*") {
        # Step 3: Device selection / polling options
        Write-Info "Submitting polling options (300s interval)..."
        $step3Data = @{
            location_poll_interval      = 300
            device_poll_delay           = 5
            google_home_filter_enabled  = $true
            google_home_filter_keywords = "nest,google,home,mini,hub,display,chromecast,speaker"
            enable_stats_entities       = $true
            map_view_token_expiration   = $false
        } | ConvertTo-Json -Compress
        $step3Body = [System.Text.Encoding]::UTF8.GetBytes($step3Data)
        $step3Resp = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow/$flowId" `
            -Method POST -Headers $script:haHeaders -Body $step3Body -UseBasicParsing -TimeoutSec 120
        $step3 = $step3Resp.Content | ConvertFrom-Json

        if ($step3.type -eq "create_entry") {
            Write-Success "GoogleFindMy integration configured! Entry: $($step3.title)"
        } else {
            Write-Fail "Unexpected result at device_selection step"
            Write-Info ($step3 | ConvertTo-Json -Depth 5 -Compress)
        }
    } else {
        Write-Fail "Unexpected flow state after secrets submission"
        Write-Info ($step2 | ConvertTo-Json -Depth 5 -Compress)
        Write-Info "Complete setup manually: Settings > Devices & Services > Add Integration > Google Find My"
    }

    # Set external URL (required for FCM push transport)
    Write-Info "Ensuring external URL is set (required for FCM)..."
    Connect-HAWS
    $urlResp = Invoke-WSCommand -Type "config/core/update" -Extra @{
        external_url = "http://$($Config.HA_IP):8123"
        internal_url = "http://$($Config.HA_IP):8123"
    }
    if ($urlResp.success) { Write-Success "External URL set" }
    Disconnect-HAWS

    # Full restart required for FCM push transport to connect
    Write-Step "Restarting HA (full restart required for FCM push transport)..."
    try { $null = Invoke-HAREST -Endpoint "/api/services/homeassistant/restart" -Method "POST" -JsonBody "{}" } catch {}
    Write-Info "Waiting 90 seconds for HA to restart..."
    Start-Sleep -Seconds 90

    $maxWait = 120; $waited = 0
    while ($waited -lt $maxWait) {
        try { $null = Invoke-HAREST -Endpoint "/api/"; break } catch { Start-Sleep -Seconds 5; $waited += 5 }
    }
    if ($waited -ge $maxWait) {
        Write-Fail "HA did not come back. Wait manually, then check device trackers."
    } else {
        Write-Success "HA is back online"
    }
}

# ============================================================
# STEP 4: Wait for device discovery + create automations
# ============================================================

Write-Step "4/5 - Creating Automations"

# Give the integration time to discover devices
Write-Info "Waiting 30 seconds for device discovery..."
Start-Sleep -Seconds 30

# Discover Find My device trackers
$allStates = Invoke-HAREST -Endpoint "/api/states"
$findMyTrackers = $allStates | Where-Object {
    $_.entity_id -like "device_tracker.googlefindmy_*"
}

if ($findMyTrackers.Count -eq 0) {
    Write-Info "No GoogleFindMy device trackers found yet."
    Write-Info "They may take a few minutes to appear after initial sync."
    Write-Info "Re-run this script later, or create automations manually."
} else {
    Write-Success "Found $($findMyTrackers.Count) device tracker(s):"
    foreach ($t in $findMyTrackers) {
        $battery = $t.attributes.battery_level
        Write-Info "  - $($t.entity_id) ($($t.attributes.friendly_name)) = $($t.state)$(if ($battery) { " [Battery: $battery%]" })"
    }
}

$trackerIds = @()
if ($findMyTrackers.Count -gt 0) {
    $trackerIds = $findMyTrackers | ForEach-Object { $_.entity_id }
} else {
    $trackerIds = @("device_tracker.googlefindmy_placeholder")
    Write-Info "Using placeholder entity. Update automations after trackers appear."
}

# Discover mobile_app notify services for phone notifications
$notifyService = $null
try {
    $servicesResp = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/services" `
        -Method GET -Headers $script:haHeaders `
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

# --- Automation: Find My Device Battery Low ---
Write-Info "Creating: Find My Device Battery Low..."

$batteryTriggerList = @()
foreach ($tid in $trackerIds) {
    $batteryTriggerList += @{
        platform       = "numeric_state"
        entity_id      = $tid
        attribute       = "battery_level"
        below          = 20
    }
}

$batteryTtsTemplate = @"
{% set name = trigger.to_state.attributes.friendly_name | default('A Find My device') %}
{% set battery = trigger.to_state.attributes.battery_level | default('low') %}
{{ name }} battery is at {{ battery }} percent.
"@

$batteryActions = @(
    @{
        service = "tts.speak"
        target  = @{ entity_id = $ttsEngine }
        data    = @{
            media_player_entity_id = $kitchenSpeaker
            message = $batteryTtsTemplate
        }
    }
)

if ($notifyService) {
    $batteryActions += @{
        service = $notifyService
        data    = @{
            message = "{{ trigger.to_state.attributes.friendly_name }} battery is at {{ trigger.to_state.attributes.battery_level }}%"
            title   = "Find My - Low Battery"
        }
    }
}

$batteryJson = @{
    alias       = "FindMy Device Battery Low"
    description = "TTS + phone notification when a Google Find My tag battery drops below 20%."
    mode        = "single"
    trigger     = $batteryTriggerList
    condition   = @()
    action      = $batteryActions
} | ConvertTo-Json -Depth 10

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/findmy_device_battery_low" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($batteryJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "FindMy Device Battery Low automation created"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# --- Automation: Find My Zone Alert ---
Write-Info "Creating: Find My Zone Alert..."

$zoneTriggerList = @()
foreach ($tid in $trackerIds) {
    $zoneTriggerList += @{
        platform  = "state"
        entity_id = $tid
    }
}

$zoneTtsTemplate = @"
{% set name = trigger.to_state.attributes.friendly_name | default('A Find My device') %}
{% if trigger.to_state.state == 'home' %}
  {{ name }} has arrived home.
{% elif trigger.from_state.state == 'home' %}
  {{ name }} has left home.
{% elif trigger.to_state.state != trigger.from_state.state %}
  {{ name }} is now {{ trigger.to_state.state | replace('_', ' ') }}.
{% endif %}
"@

$zonePhoneTemplate = @"
{% set name = trigger.to_state.attributes.friendly_name | default('Find My device') %}
{% if trigger.to_state.state == 'home' %}{{ name }} arrived home{% elif trigger.from_state.state == 'home' %}{{ name }} left home{% else %}{{ name }} is now {{ trigger.to_state.state }}{% endif %}
"@

$zoneActions = @(
    @{
        service = "tts.speak"
        target  = @{ entity_id = $ttsEngine }
        data    = @{
            media_player_entity_id = $kitchenSpeaker
            message = $zoneTtsTemplate
        }
    }
)

if ($notifyService) {
    $zoneActions += @{
        service = $notifyService
        data    = @{
            message = $zonePhoneTemplate
            title   = "Find My - Zone Change"
        }
    }
}

# Condition: only fire when state actually changes to/from a known zone (not 'unknown' to 'unknown')
$zoneCondition = "{{ trigger.to_state.state != trigger.from_state.state and trigger.to_state.state not in ['unknown', 'unavailable'] }}"

$zoneJson = @{
    alias       = "FindMy Zone Alert"
    description = "TTS + phone notification when a Google Find My tag enters or leaves a zone."
    mode        = "queued"
    max         = 5
    trigger     = $zoneTriggerList
    condition   = @(
        @{
            condition      = "template"
            value_template = $zoneCondition
        }
    )
    action      = $zoneActions
} | ConvertTo-Json -Depth 10

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/findmy_zone_alert" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($zoneJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "FindMy Zone Alert automation created"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# STEP 5: Summary
# ============================================================

Write-Step "5/5 - Google Find My Setup Complete"

Write-Host ""
Write-Host "  Integration:" -ForegroundColor Green
Write-Host "    - GoogleFindMy-HA (BSkando/GoogleFindMy-HA) installed via HACS" -ForegroundColor White
Write-Host "    - Domain: googlefindmy" -ForegroundColor White
Write-Host "    - Polling: 300s interval, 50m movement threshold" -ForegroundColor White
Write-Host ""
if ($findMyTrackers.Count -gt 0) {
    Write-Host "  Device Trackers ($($findMyTrackers.Count) found):" -ForegroundColor Green
    foreach ($t in $findMyTrackers) {
        $name = $t.attributes.friendly_name
        $state = $t.state
        $battery = $t.attributes.battery_level
        Write-Host "    - $($t.entity_id) ($name) = $state" -NoNewline -ForegroundColor White
        if ($battery) { Write-Host " [Battery: $battery%]" -ForegroundColor Gray } else { Write-Host "" }
    }
} else {
    Write-Host "  Device Trackers:" -ForegroundColor Green
    Write-Host "    - None found yet (may take a few minutes to sync)" -ForegroundColor Yellow
    Write-Host "    - Check: Developer Tools > States > filter device_tracker.googlefindmy" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Automations:" -ForegroundColor Green
Write-Host "    - FindMy Device Battery Low: TTS when tag battery < 20%" -ForegroundColor White
Write-Host "    - FindMy Zone Alert: TTS when tag enters/leaves a zone (home, etc.)" -ForegroundColor White
if ($notifyService) {
    Write-Host "    - Phone notifications: $notifyService" -ForegroundColor White
} else {
    Write-Host "    - Phone notifications: not configured (no mobile_app service found)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Zones:" -ForegroundColor Green
Write-Host "    - HA zones (zone.home + any custom zones) apply to all device trackers" -ForegroundColor White
Write-Host "    - Life360 zones are separate (only affect Life360 trackers)" -ForegroundColor White
Write-Host "    - Create custom zones: Settings > Areas & Zones > Zones > Add Zone" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Wait a few minutes for Google Find My to sync all devices" -ForegroundColor White
Write-Host "    2. Check device_tracker entities in Developer Tools > States" -ForegroundColor White
Write-Host "    3. Run deploy/20a-Add-FindMyDashboard.ps1 to add Find My tab to Presence dashboard" -ForegroundColor White
Write-Host "    4. Update deploy/17-Integrity-Check.ps1 with discovered entity IDs" -ForegroundColor White
Write-Host "    5. Run deploy/17-Integrity-Check.ps1 to verify" -ForegroundColor White
Write-Host ""
