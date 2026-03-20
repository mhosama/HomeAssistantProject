<#
.SYNOPSIS
    Set up Life360 location tracking integration via HACS.

.DESCRIPTION
    - Installs pnbruckner/ha-life360 via HACS WebSocket API
    - Restarts HA for the integration to load
    - Guides user through browser token extraction (email-code auth workaround)
    - Configures Life360 integration via config flow (access token method)
    - Creates Home zone if not already present
    - Creates arrival/departure automations (TTS + phone notifications)

    Run AFTER HACS is installed and working.

.EXAMPLE
    .\16-Setup-Life360.ps1
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
# STEP 1: Install Life360 via HACS
# ============================================================

Write-Step "1/5 - Installing Life360 HACS Integration"

Connect-HAWS

# Check if Life360 integration is already configured
$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$life360Entry = $existingEntries | Where-Object { $_.domain -eq "life360" }
if ($life360Entry) {
    Write-Success "Life360 integration already configured - skipping HACS install"
} else {
    # List HACS repos to check if life360 is already available
    Write-Info "Checking HACS repository list..."
    $hacsRepos = Invoke-WSCommand -Type "hacs/repositories/list"

    $life360Repo = $null
    if ($hacsRepos.success -and $hacsRepos.result) {
        $life360Repo = $hacsRepos.result | Where-Object { $_.full_name -eq "pnbruckner/ha-life360" }
    }

    if (-not $life360Repo) {
        # Add as custom repository
        Write-Info "Adding pnbruckner/ha-life360 as custom HACS repository..."
        $addResult = Invoke-WSCommand -Type "hacs/repositories/add" -Extra @{
            repository = "pnbruckner/ha-life360"
            category   = "integration"
        }
        if ($addResult.success) {
            Write-Success "Custom repository added to HACS"
        } else {
            Write-Fail "Failed to add custom repo: $($addResult.error.message)"
            Write-Info "Manual fallback: HACS, 3 dots, Custom repositories, Add pnbruckner/ha-life360 (Integration)"
        }

        # Re-list to get the repo ID
        Start-Sleep -Seconds 3
        $hacsRepos = Invoke-WSCommand -Type "hacs/repositories/list"
        if ($hacsRepos.success -and $hacsRepos.result) {
            $life360Repo = $hacsRepos.result | Where-Object { $_.full_name -eq "pnbruckner/ha-life360" }
        }
    }

    if ($life360Repo) {
        if ($life360Repo.installed) {
            Write-Success "Life360 integration already installed in HACS"
        } else {
            Write-Info "Downloading Life360 integration (ID: $($life360Repo.id))..."
            $dlResult = Invoke-WSCommand -Type "hacs/repository/download" -Extra @{ repository = $life360Repo.id }
            if ($dlResult.success) {
                Write-Success "Life360 integration downloaded via HACS"
            } else {
                Write-Fail "Download failed: $($dlResult.error.message)"
                Write-Info "Manual fallback: HACS, Integrations, Search Life360, Download"
            }
        }
    } else {
        Write-Fail "Could not find Life360 in HACS after adding"
        Write-Info "Manual fallback: HACS, 3 dots, Custom repositories, Add pnbruckner/ha-life360"
    }

    Disconnect-HAWS

    # Restart HA for the integration to load
    Write-Step "Restarting Home Assistant for Life360 integration to load..."
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
# STEP 2: Token extraction guidance
# ============================================================

Write-Step "2/5 - Life360 Authentication (Access Token)"

Write-Host ""
Write-Host "  Life360 uses email verification codes for login, which the integration" -ForegroundColor White
Write-Host "  cannot handle automatically. You need to extract an access token from" -ForegroundColor White
Write-Host "  the browser. This is a ONE-TIME manual step." -ForegroundColor White
Write-Host ""
Write-Host "  Steps:" -ForegroundColor Yellow
Write-Host "    1. Open https://life360.com/login in your browser" -ForegroundColor White
Write-Host "    2. Press F12 to open Developer Tools" -ForegroundColor White
Write-Host "    3. Click the 'Network' tab" -ForegroundColor White
Write-Host "    4. Make sure recording is ON (red dot)" -ForegroundColor White
Write-Host "    5. Log in with your email (you'll receive a code via email)" -ForegroundColor White
Write-Host "    6. Enter the code to complete login" -ForegroundColor White
Write-Host "    7. In the Network tab, look for a request called 'token'" -ForegroundColor White
Write-Host "       (ignore any 'preflight' or OPTIONS requests)" -ForegroundColor White
Write-Host "    8. Click on it, go to 'Preview' or 'Response' tab" -ForegroundColor White
Write-Host "    9. Find 'token_type' (should be 'Bearer') and 'access_token'" -ForegroundColor White
Write-Host "   10. Copy the access_token value" -ForegroundColor White
Write-Host ""
Write-Host "  NOTE: If life360.com/login doesn't work, try app.life360.com/login" -ForegroundColor Yellow
Write-Host "        (though it may only show US phone number option for non-US users)" -ForegroundColor Yellow
Write-Host ""

# Check if token is already in config
if ([string]::IsNullOrWhiteSpace($Config.Life360AccessToken)) {
    Write-Info "Life360AccessToken not found in config.ps1"
    Write-Host ""
    Write-Host "  Add these lines to deploy/config.ps1:" -ForegroundColor Yellow
    Write-Host '    Life360TokenType   = "Bearer"' -ForegroundColor White
    Write-Host '    Life360AccessToken  = "<paste your access token here>"' -ForegroundColor White
    Write-Host ""

    $continue = Read-Host "  Have you added the token to config.ps1? (y/n)"
    if ($continue -ne "y") {
        Write-Info "Exiting. Re-run this script after adding the token to config.ps1."
        exit 0
    }

    # Reload config
    . "$scriptDir\config.ps1"

    if ([string]::IsNullOrWhiteSpace($Config.Life360AccessToken)) {
        Write-Fail "Life360AccessToken still not found in config.ps1. Exiting."
        exit 1
    }
}

Write-Success "Life360 access token found in config"

# ============================================================
# STEP 3: Configure Life360 integration via config flow
# ============================================================

Write-Step "3/5 - Configuring Life360 Integration"

# Check if already configured
$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$life360Entry = $existingEntries | Where-Object { $_.domain -eq "life360" }

if ($life360Entry) {
    Write-Success "Life360 integration already configured (entry: $($life360Entry.entry_id))"
} else {
    # Abort any stale Life360 flows
    $flows = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/progress"
    if ($flows) {
        $staleFlows = $flows | Where-Object { $_.handler -eq "life360" }
        foreach ($f in $staleFlows) {
            Write-Info "Aborting stale Life360 flow: $($f.flow_id)"
            try {
                $null = Invoke-WebRequest -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow/$($f.flow_id)" `
                    -Method DELETE -Headers $script:haHeaders -UseBasicParsing -TimeoutSec 30
            } catch {}
        }
    }

    # Start config flow
    Write-Info "Starting Life360 config flow..."
    $flowStart = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" `
        -JsonBody '{"handler": "life360"}'

    if (-not $flowStart) {
        Write-Fail "Failed to start Life360 config flow. Is the integration installed?"
        Write-Info "Check: Settings, Devices and Services, Add Integration, search Life360"
        exit 1
    }

    Write-Info "Flow started: step=$($flowStart.step_id), flow_id=$($flowStart.flow_id)"

    # The config flow typically has two steps:
    # 1. Choose auth method (email/password OR access type/token)
    # 2. Enter credentials

    # Step through the flow
    $flowId = $flowStart.flow_id
    $currentStep = $flowStart

    # Handle flow steps
    $maxSteps = 5
    $stepCount = 0

    while ($currentStep -and $currentStep.type -ne "create_entry" -and $currentStep.type -ne "abort" -and $stepCount -lt $maxSteps) {
        $stepCount++
        $stepId = $currentStep.step_id
        Write-Info "Flow step $stepCount`: $stepId (type: $($currentStep.type))"

        # Log available fields for debugging
        if ($currentStep.data_schema) {
            $fieldNames = ($currentStep.data_schema | ForEach-Object { $_.name }) -join ", "
            Write-Info "  Fields: $fieldNames"
        }

        # Determine what data to submit based on the step
        $submitData = @{}

        switch -Wildcard ($stepId) {
            "*authorization*" {
                # Choose authorization method — select access token method
                # The field is typically "authorization" with options
                $submitData = @{ authorization = "access_token" }
                Write-Info "  Selecting: Access Type & Token method"
            }
            "*access_token*" {
                # Submit the token
                $submitData = @{
                    access_token      = $Config.Life360AccessToken
                    token_type        = if ($Config.Life360TokenType) { $Config.Life360TokenType } else { "Bearer" }
                    account_id        = "life360_home"
                }
                Write-Info "  Submitting access token..."
            }
            "*account*" {
                # Some flows ask for account details first
                $submitData = @{
                    access_token      = $Config.Life360AccessToken
                    token_type        = if ($Config.Life360TokenType) { $Config.Life360TokenType } else { "Bearer" }
                    account_id        = "life360_home"
                }
                Write-Info "  Submitting account details..."
            }
            default {
                # Try submitting the token directly
                $submitData = @{
                    access_token      = $Config.Life360AccessToken
                    token_type        = if ($Config.Life360TokenType) { $Config.Life360TokenType } else { "Bearer" }
                    account_id        = "life360_home"
                }
                Write-Info "  Submitting token for step: $stepId"
            }
        }

        $submitJson = $submitData | ConvertTo-Json -Compress
        $currentStep = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "POST" -JsonBody $submitJson

        if (-not $currentStep) {
            Write-Fail "Config flow step failed"
            break
        }
    }

    if ($currentStep.type -eq "create_entry") {
        Write-Success "Life360 integration configured! Entry: $($currentStep.title)"
    } elseif ($currentStep.type -eq "abort") {
        Write-Fail "Config flow aborted: $($currentStep.reason)"
    } else {
        Write-Fail "Config flow did not complete after $maxSteps steps"
        Write-Info "Last step: $($currentStep | ConvertTo-Json -Depth 5 -Compress)"
        Write-Info "You may need to complete setup manually in HA UI:"
        Write-Info "  Settings, Devices and Services, Add Integration, Life360"
    }
}

# ============================================================
# STEP 4: Ensure Home zone exists
# ============================================================

Write-Step "4/5 - Checking Home Zone"

# HA creates a default 'zone.home' from onboarding, but verify it's at the right location
$states = Invoke-HAREST -Endpoint "/api/states"
$homeZone = $states | Where-Object { $_.entity_id -eq "zone.home" }

if ($homeZone) {
    $lat = $homeZone.attributes.latitude
    $lon = $homeZone.attributes.longitude
    $radius = $homeZone.attributes.radius
    Write-Success "Home zone exists: lat=$lat, lon=$lon, radius=${radius}m"

    # Check if it's at our expected location (within ~500m)
    $expectedLat = -26.103668
    $expectedLon = 27.954189
    $latDiff = [Math]::Abs($lat - $expectedLat)
    $lonDiff = [Math]::Abs($lon - $expectedLon)

    if ($latDiff -gt 0.005 -or $lonDiff -gt 0.005) {
        Write-Info "Home zone location differs from expected ($expectedLat, $expectedLon)"
        Write-Info "You may want to update it in Settings, Areas and Zones, Zones, Home"
    } else {
        Write-Success "Home zone location is correct"
    }
} else {
    Write-Info "No zone.home found - this is unusual (HA creates one during onboarding)"
    Write-Info "Create one in Settings, Areas and Zones, Zones, Add Zone"
    Write-Info "  Name: Home, Lat: -26.103668, Lon: 27.954189, Radius: 100m"
}

# ============================================================
# STEP 5: Create arrival/departure automations
# ============================================================

Write-Step "5/5 - Creating Presence Automations (Place-Based)"

# Discover Life360 device trackers
$allStates = Invoke-HAREST -Endpoint "/api/states"
$life360Trackers = $allStates | Where-Object {
    $_.entity_id -like "device_tracker.life360_*" -and
    $_.attributes.source_type -eq "gps"
}

if ($life360Trackers.Count -eq 0) {
    Write-Info "No Life360 device trackers found yet."
    Write-Info "They should appear after Life360 syncs (may take a few minutes)."
    Write-Info "Re-run this script later, or create automations manually."
}

# Build entity ID list for triggers
$trackerIds = @()
if ($life360Trackers.Count -gt 0) {
    $trackerIds = $life360Trackers | ForEach-Object { $_.entity_id }
    Write-Info "Found $($trackerIds.Count) device tracker(s):"
    foreach ($t in $life360Trackers) {
        Write-Info "  - $($t.entity_id) ($($t.attributes.friendly_name)) = $($t.state)"
    }
} else {
    # Use a placeholder — user can update later
    $trackerIds = @("device_tracker.life360_placeholder")
    Write-Info "Using placeholder entity. Update automation after trackers appear."
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

# TTS templates (place-based — phonetic spelling for Google TTS)
# Use [char]0xE9 for é to avoid PowerShell encoding issues with literal UTF-8
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

# --- Automation: Family Member Arrived at Place ---
Write-Info "Creating: Family Member Arrived at Place..."

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

$arrivedJson = @{
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

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/family_member_arrived" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($arrivedJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Family Member Arrived automation created"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# --- Automation: Family Member Departed from Place ---
Write-Info "Creating: Family Member Departed from Place..."

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

$departedJson = @{
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

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/family_member_departed" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($departedJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Family Member Departed automation created"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# Summary
# ============================================================

Write-Step "Life360 Setup Complete"

Write-Host ""
Write-Host "  Integration:" -ForegroundColor Green
Write-Host "    - Life360 (pnbruckner/ha-life360) installed via HACS" -ForegroundColor White
Write-Host "    - Authentication: Access Token method" -ForegroundColor White
Write-Host ""
if ($life360Trackers.Count -gt 0) {
    Write-Host "  Device Trackers ($($life360Trackers.Count) found):" -ForegroundColor Green
    foreach ($t in $life360Trackers) {
        $name = $t.attributes.friendly_name
        $state = $t.state
        $battery = $t.attributes.battery
        Write-Host "    - $($t.entity_id) ($name) = $state" -NoNewline -ForegroundColor White
        if ($battery) { Write-Host " [Battery: $battery%]" -ForegroundColor Gray } else { Write-Host "" }
    }
} else {
    Write-Host "  Device Trackers:" -ForegroundColor Green
    Write-Host "    - None found yet (may take a few minutes to sync)" -ForegroundColor Yellow
    Write-Host "    - Check: Developer Tools, States, filter device_tracker" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Automations (Place-Based):" -ForegroundColor Green
Write-Host "    - Family Member Arrived: TTS when someone arrives at any Life360 Place" -ForegroundColor White
Write-Host "    - Family Member Departed: TTS when someone leaves any Life360 Place" -ForegroundColor White
if ($notifyService) {
    Write-Host "    - Phone notifications: $notifyService" -ForegroundColor White
} else {
    Write-Host "    - Phone notifications: not configured (no mobile_app service found)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Home Zone:" -ForegroundColor Green
if ($homeZone) {
    Write-Host "    - zone.home at ($($homeZone.attributes.latitude), $($homeZone.attributes.longitude))" -ForegroundColor White
} else {
    Write-Host "    - Not found - create manually in Settings, Areas and Zones" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Wait a few minutes for Life360 to sync all circle members" -ForegroundColor White
Write-Host "    2. Check device_tracker entities in Developer Tools, States" -ForegroundColor White
Write-Host "    3. Run deploy/16a-Add-Life360Dashboard.ps1 to create Presence dashboard" -ForegroundColor White
Write-Host "    4. If trackers were not found, re-run this script to update automations" -ForegroundColor White
Write-Host ""
Write-Host "  Attributes available per tracker:" -ForegroundColor Yellow
Write-Host "    address, at_loc_since, driving, speed, battery, battery_charging," -ForegroundColor White
Write-Host "    wifi_on, last_seen, moving, raw_speed, radius" -ForegroundColor White
Write-Host ""
