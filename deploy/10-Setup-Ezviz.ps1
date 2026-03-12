<#
.SYNOPSIS
    One-time setup for EZVIZ farm camera integration + vision analysis.

.DESCRIPTION
    1. Adds the EZVIZ integration via config flow (built-in, no HACS needed)
    2. Discovers EZVIZ entities and displays them for user to confirm
    3. Creates HA sensors for farm vision analysis (fire/smoke, rain, animals, humans/vehicles, per-camera)
    4. Creates HA automations (fire alert, intruder alert)
    5. Registers a Windows Scheduled Task to run 10a-Run-EzvizVision.ps1 every 5 minutes

    Run this ONCE after EZVIZ account is ready (2FA disabled, direct email/password login).

.EXAMPLE
    .\10-Setup-Ezviz.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN", "EzvizUsername", "EzvizPassword", "GeminiApiKey")

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

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"

# ============================================================
# STEP 1: Add EZVIZ integration via config flow
# ============================================================

Write-Step "1/5 - Adding EZVIZ Integration"

# Check if EZVIZ integration already exists
Write-Info "Checking for existing EZVIZ integration..."
$existingEntries = Invoke-RestMethod -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/entry" -Headers $script:haHeaders -UseBasicParsing -TimeoutSec 30
$ezvizEntry = $existingEntries | Where-Object { $_.domain -eq "ezviz" }

if ($ezvizEntry) {
    Write-Success "EZVIZ integration already exists (entry: $($ezvizEntry.entry_id))"
} else {
    Write-Info "Starting EZVIZ config flow..."

    # Step 1: Initialize config flow
    $initBody = @{ handler = "ezviz" } | ConvertTo-Json
    try {
        $flowResp = Invoke-RestMethod `
            -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow" `
            -Method POST -Headers $script:haHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($initBody)) `
            -UseBasicParsing -TimeoutSec 30

        $flowId = $flowResp.flow_id
        $stepType = $flowResp.type

        if ($stepType -eq "form") {
            Write-Info "Config flow started (flow_id: $flowId), completing with credentials..."

            # Step 2: Complete the flow with username/password
            $credBody = @{
                username = $Config.EzvizUsername
                password = $Config.EzvizPassword
            } | ConvertTo-Json

            $completeResp = Invoke-RestMethod `
                -Uri "http://$($Config.HA_IP):8123/api/config/config_entries/flow/$flowId" `
                -Method POST -Headers $script:haHeaders `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($credBody)) `
                -UseBasicParsing -TimeoutSec 60

            if ($completeResp.type -eq "create_entry") {
                Write-Success "EZVIZ integration added successfully!"
                Write-Success "Entry ID: $($completeResp.result.entry_id)"
            } elseif ($completeResp.type -eq "form") {
                Write-Info "Config flow needs additional input. Step: $($completeResp.step_id)"
                Write-Info "Data schema: $($completeResp.data_schema | ConvertTo-Json -Compress)"
                Write-Info "Complete this manually in HA Settings > Integrations"
            } elseif ($completeResp.type -eq "abort") {
                Write-Fail "Config flow aborted: $($completeResp.reason)"
            } else {
                Write-Info "Unexpected flow response type: $($completeResp.type)"
                Write-Info "Response: $($completeResp | ConvertTo-Json -Depth 5)"
            }
        } elseif ($stepType -eq "abort") {
            Write-Fail "Config flow aborted: $($flowResp.reason)"
        } else {
            Write-Info "Unexpected initial flow type: $stepType"
            Write-Info "Response: $($flowResp | ConvertTo-Json -Depth 5)"
        }
    } catch {
        Write-Fail "Config flow failed: $($_.Exception.Message)"
        Write-Info "You may need to add the EZVIZ integration manually via HA Settings > Integrations"
    }
}

# ============================================================
# STEP 2: Discover EZVIZ entities
# ============================================================

Write-Step "2/5 - Discovering EZVIZ Entities"

Write-Info "Waiting 10 seconds for entities to register..."
Start-Sleep -Seconds 10

Write-Info "Fetching all entities..."
$allStates = Invoke-RestMethod -Uri "http://$($Config.HA_IP):8123/api/states" -Headers $script:haHeaders -UseBasicParsing -TimeoutSec 30

$ezvizEntities = $allStates | Where-Object { $_.entity_id -match "ezviz" }

if ($ezvizEntities.Count -gt 0) {
    Write-Success "Found $($ezvizEntities.Count) EZVIZ entities:"
    Write-Host ""
    foreach ($e in ($ezvizEntities | Sort-Object entity_id)) {
        $type = ($e.entity_id -split "\.")[0]
        Write-Host "    $($e.entity_id)" -ForegroundColor White -NoNewline
        Write-Host "  ($type, state: $($e.state))" -ForegroundColor Gray
    }
    Write-Host ""

    # Show camera and image entities specifically
    $cameraEntities = $ezvizEntities | Where-Object { $_.entity_id -match "^(camera|image)\." }
    if ($cameraEntities.Count -gt 0) {
        Write-Info "Camera/Image entities (use these in 10a-Run-EzvizVision.ps1):"
        foreach ($c in ($cameraEntities | Sort-Object entity_id)) {
            Write-Host "    $($c.entity_id)" -ForegroundColor Cyan
        }
        Write-Host ""
    }
} else {
    Write-Info "No EZVIZ entities found yet."
    Write-Info "The integration may need time to discover cameras, or it may not have connected."
    Write-Info "Check HA Settings > Integrations > EZVIZ for status."
    Write-Info ""
    Write-Info "Once entities appear, update the camera list in 10a-Run-EzvizVision.ps1"
}

# ============================================================
# STEP 3: Create sensors
# ============================================================

Write-Step "3/5 - Creating Farm Vision Analysis Sensors"

$sensors = @(
    @{ entity_id = "sensor.farm_cam_1_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 1"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_2_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 2"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_3_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 3"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_4_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 4"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_5_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 5"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_6_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 6"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_fire_smoke";   state = "none";    attributes = @{ friendly_name = "Farm Fire/Smoke"; icon = "mdi:fire-alert"; cameras_detecting = "" } }
    @{ entity_id = "sensor.farm_rain_status";  state = "none";    attributes = @{ friendly_name = "Farm Rain Status"; icon = "mdi:weather-rainy"; intensity = "none" } }
    @{ entity_id = "sensor.farm_animal_summary"; state = "unknown"; attributes = @{ friendly_name = "Farm Animals"; icon = "mdi:cow"; total_count = 0 } }
    @{ entity_id = "sensor.farm_human_vehicle_summary"; state = "clear"; attributes = @{ friendly_name = "Farm Humans/Vehicles"; icon = "mdi:account-alert"; human_count = 0; vehicle_count = 0 } }
)

foreach ($sensor in $sensors) {
    $body = @{
        state      = $sensor.state
        attributes = $sensor.attributes
    } | ConvertTo-Json -Depth 5

    try {
        $null = Invoke-WebRequest `
            -Uri "http://$($Config.HA_IP):8123/api/states/$($sensor.entity_id)" `
            -Method POST -Headers $script:haHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 30
        Write-Success "$($sensor.entity_id)"
    } catch {
        Write-Fail "$($sensor.entity_id): $($_.Exception.Message)"
    }
}

# ============================================================
# STEP 4: Create automations
# ============================================================

Write-Step "4/5 - Creating Farm Vision Automations"

# --- Farm Fire/Smoke Detected ---
Write-Info "Creating: Farm Fire Smoke Detected..."

$fireAutoJson = @"
{
  "alias": "Farm Fire Smoke Detected",
  "description": "Alerts immediately when fire or smoke is detected at any farm camera (via Gemini vision analysis)",
  "mode": "single",
  "trigger": [
    {"platform": "state", "entity_id": "sensor.farm_fire_smoke", "from": "none"}
  ],
  "condition": [
    {"condition": "not", "conditions": [{"condition": "state", "entity_id": "sensor.farm_fire_smoke", "state": "none"}]}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Warning! Fire or smoke has been detected at the farm. Check the farm cameras immediately."}}
  ]
}
"@

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/farm_fire_smoke_detected" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($fireAutoJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Farm Fire Smoke Detected"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# --- Farm Intruder Detected ---
Write-Info "Creating: Farm Intruder Detected..."

$intruderAutoJson = @"
{
  "alias": "Farm Intruder Detected",
  "description": "Alerts when a human is detected at farm cameras during night hours (8PM-6AM, via Gemini vision analysis)",
  "mode": "single",
  "trigger": [
    {"platform": "state", "entity_id": "sensor.farm_human_vehicle_summary"}
  ],
  "condition": [
    {"condition": "time", "after": "20:00:00", "before": "06:00:00"},
    {"condition": "not", "conditions": [{"condition": "state", "entity_id": "sensor.farm_human_vehicle_summary", "state": "clear"}]}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Security alert. A person or vehicle has been detected at the farm."}}
  ]
}
"@

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/farm_intruder_detected" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($intruderAutoJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Farm Intruder Detected"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# STEP 5: Register Windows Scheduled Task
# ============================================================

Write-Step "5/5 - Registering Scheduled Task"

$taskName = "HA-EzvizVision"
$scriptPath = Join-Path $scriptDir "10a-Run-EzvizVision.ps1"

Write-Info "Script path: $scriptPath"

# Check if task already exists
try {
    $existingTask = schtasks /query /tn $taskName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Task '$taskName' already exists, deleting..."
        schtasks /delete /tn $taskName /f 2>&1 | Out-Null
    }
} catch {
    # Task doesn't exist, that's fine
}

Write-Info "Creating scheduled task '$taskName' (every 5 minutes)..."
$result = schtasks /create /tn $taskName /tr "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" /sc minute /mo 5 /ru SYSTEM /f
if ($LASTEXITCODE -eq 0) {
    Write-Success "Scheduled task '$taskName' created"
} else {
    Write-Fail "Failed to create scheduled task (run as admin for SYSTEM account, or remove /ru SYSTEM)"
    Write-Info "Manual command: schtasks /create /tn `"$taskName`" /tr `"powershell -ExecutionPolicy Bypass -File $scriptPath`" /sc minute /mo 5"
}

# ============================================================
# Create logs directory
# ============================================================

$logsDir = Join-Path $scriptDir "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    Write-Success "Created logs directory: $logsDir"
}

# ============================================================
# Summary
# ============================================================

Write-Step "EZVIZ Farm Camera Setup Complete"

Write-Host ""
Write-Host "  Sensors created:" -ForegroundColor Green
Write-Host "    - sensor.farm_cam_1_status .. sensor.farm_cam_6_status  (per-camera summary)" -ForegroundColor White
Write-Host "    - sensor.farm_fire_smoke           (fire/smoke detection)" -ForegroundColor White
Write-Host "    - sensor.farm_rain_status           (rain detection)" -ForegroundColor White
Write-Host "    - sensor.farm_animal_summary        (animal detection)" -ForegroundColor White
Write-Host "    - sensor.farm_human_vehicle_summary (human/vehicle detection)" -ForegroundColor White
Write-Host ""
Write-Host "  Automations created:" -ForegroundColor Green
Write-Host "    1. Farm Fire Smoke Detected  - fire/smoke detected at any camera -> TTS" -ForegroundColor White
Write-Host "    2. Farm Intruder Detected    - human/vehicle at night (8PM-6AM) -> TTS" -ForegroundColor White
Write-Host ""
Write-Host "  Scheduled task: $taskName (every 5 minutes)" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Update camera entity IDs in 10a-Run-EzvizVision.ps1 with the discovered EZVIZ entities" -ForegroundColor Yellow
Write-Host "    2. Run 10a-Run-EzvizVision.ps1 manually to test" -ForegroundColor Yellow
Write-Host "    3. Check Developer Tools > States for sensor updates" -ForegroundColor Yellow
Write-Host "    4. Deploy scheduled task to host server via PS Remoting" -ForegroundColor Yellow
Write-Host "    5. Run 10b-Add-EzvizDashboard.ps1 to add Farm Cameras to dashboards" -ForegroundColor Yellow
Write-Host ""
