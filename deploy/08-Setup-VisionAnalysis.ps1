<#
.SYNOPSIS
    One-time setup for LLM vision analysis of cameras with per-camera scheduling.

.DESCRIPTION
    Creates HA sensors (chicken count, gate status, food descriptions, car counts, analysis stats),
    HA automations (gate open too long, chickens not inside), and registers a
    Windows Scheduled Task to run 08a-Run-VisionAnalysis.ps1 every 10 seconds.

    Run this ONCE after cameras are configured.

.EXAMPLE
    .\08-Setup-VisionAnalysis.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN", "GeminiApiKey")

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

# ============================================================
# Entity IDs
# ============================================================

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"

# ============================================================
# STEP 1: Create sensors via POST /api/states
# ============================================================

Write-Step "1/3 - Creating Vision Analysis Sensors"

$sensors = @(
    @{ entity_id = "sensor.chicken_count";          state = "unknown"; attributes = @{ friendly_name = "Chicken Count";          icon = "mdi:chicken";         unit_of_measurement = "chickens" } }
    @{ entity_id = "sensor.egg_count";              state = "0";       attributes = @{ friendly_name = "Egg Count";              icon = "mdi:egg";             unit_of_measurement = "eggs" } }
    @{ entity_id = "sensor.breakfast_food";          state = "unknown"; attributes = @{ friendly_name = "Breakfast Food";         icon = "mdi:food-croissant"  } }
    @{ entity_id = "sensor.lunch_food";              state = "unknown"; attributes = @{ friendly_name = "Lunch Food";             icon = "mdi:food"            } }
    @{ entity_id = "sensor.dinner_food";             state = "unknown"; attributes = @{ friendly_name = "Dinner Food";            icon = "mdi:food-turkey"     } }
    @{ entity_id = "sensor.main_gate_status";        state = "unknown"; attributes = @{ friendly_name = "Main Gate Status";       icon = "mdi:gate"            } }
    @{ entity_id = "sensor.main_gate_car_count";     state = "0";       attributes = @{ friendly_name = "Main Gate Car Count";    icon = "mdi:car";            unit_of_measurement = "cars" } }
    @{ entity_id = "sensor.visitor_gate_status";     state = "unknown"; attributes = @{ friendly_name = "Visitor Gate Status";    icon = "mdi:gate"            } }
    @{ entity_id = "sensor.visitor_gate_car_count";  state = "0";       attributes = @{ friendly_name = "Visitor Gate Car Count"; icon = "mdi:car";            unit_of_measurement = "cars" } }
    @{ entity_id = "sensor.vision_analysis_stats";   state = "0";       attributes = @{ friendly_name = "Vision Analysis Stats";  icon = "mdi:chart-bar"       } }
    @{ entity_id = "sensor.pool_adult_count";       state = "0";       attributes = @{ friendly_name = "Pool Adult Count";      icon = "mdi:account";        unit_of_measurement = "people" } }
    @{ entity_id = "sensor.pool_child_count";       state = "0";       attributes = @{ friendly_name = "Pool Child Count";      icon = "mdi:account-child";  unit_of_measurement = "people" } }
    @{ entity_id = "sensor.pool_cover_status";      state = "unknown"; attributes = @{ friendly_name = "Pool Cover Status";     icon = "mdi:pool"            } }
    @{ entity_id = "sensor.left_garage_door";       state = "unknown"; attributes = @{ friendly_name = "Left Garage Door";      icon = "mdi:garage"          } }
    @{ entity_id = "sensor.right_garage_door";      state = "unknown"; attributes = @{ friendly_name = "Right Garage Door";     icon = "mdi:garage"          } }
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
# STEP 2: Create automations
# ============================================================

Write-Step "2/3 - Creating Vision Analysis Automations"

# --- Main Gate Open Too Long ---
Write-Info "Creating: Main Gate Open Too Long..."

$mainGateAutoJson = @"
{
  "alias": "Main Gate Open Too Long",
  "description": "Alerts when the main gate has been open for more than 10 minutes (detected by LLM vision analysis)",
  "mode": "single",
  "trigger": [{"platform": "state", "entity_id": "sensor.main_gate_status", "to": "open", "for": {"minutes": 10}}],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Warning. The main gate has been open for more than 10 minutes."}}
  ]
}
"@

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/main_gate_open_too_long" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($mainGateAutoJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Main Gate Open Too Long"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# --- Visitor Gate Open Too Long ---
Write-Info "Creating: Visitor Gate Open Too Long..."

$visitorGateAutoJson = @"
{
  "alias": "Visitor Gate Open Too Long",
  "description": "Alerts when the visitor gate has been open for more than 10 minutes (detected by LLM vision analysis)",
  "mode": "single",
  "trigger": [{"platform": "state", "entity_id": "sensor.visitor_gate_status", "to": "open", "for": {"minutes": 10}}],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Warning. The visitor gate has been open for more than 10 minutes."}}
  ]
}
"@

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/visitor_gate_open_too_long" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($visitorGateAutoJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Visitor Gate Open Too Long"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# --- Chickens Not Inside ---
Write-Info "Creating: Chickens Not Inside..."

$chickenAutoJson = @"
{
  "alias": "Chickens Not Inside",
  "description": "Alerts at 8PM if no chickens are detected in the cage by LLM vision analysis. Once per day only.",
  "mode": "single",
  "trigger": [{"platform": "time", "at": "20:00:00"}],
  "condition": [
    {"condition": "numeric_state", "entity_id": "sensor.chicken_count", "below": 1}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Warning. No chickens have been detected in the cage. Please check on the chickens."}}
  ]
}
"@

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/chickens_not_inside" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($chickenAutoJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Chickens Not Inside"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# --- Chickens Not Outside ---
Write-Info "Creating: Chickens Not Outside..."

$chickenOutAutoJson = @"
{
  "alias": "Chickens Not Outside",
  "description": "Alerts at 8AM if chickens are still detected in the cage (they should be out by now). Once per day only.",
  "mode": "single",
  "trigger": [{"platform": "time", "at": "08:00:00"}],
  "condition": [
    {"condition": "numeric_state", "entity_id": "sensor.chicken_count", "above": 0}
  ],
  "action": [
    {"service": "tts.speak", "target": {"entity_id": "$ttsEngine"}, "data": {"media_player_entity_id": "$kitchenSpeaker", "message": "Warning. Chickens are still inside the cage. Please let the chickens out."}}
  ]
}
"@

try {
    $null = Invoke-WebRequest `
        -Uri "http://$($Config.HA_IP):8123/api/config/automation/config/chickens_not_outside" `
        -Method POST -Headers $script:haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($chickenOutAutoJson)) `
        -UseBasicParsing -TimeoutSec 60
    Write-Success "Chickens Not Outside"
} catch {
    Write-Info "Request sent (may have timed out, but automation should still be created)"
}

# ============================================================
# STEP 3: Register Windows Scheduled Task (every 10 seconds)
# ============================================================

Write-Step "3/3 - Registering Scheduled Task (every 1 minute, internal 10s loop)"

$taskName = "HA-VisionAnalysis"
$scriptPath = Join-Path $scriptDir "08a-Run-VisionAnalysis.ps1"

Write-Info "Script path: $scriptPath"

# Delete old task first (may have been created with schtasks or Register-ScheduledTask)
Write-Info "Removing existing task '$taskName' if present..."
try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {}
try {
    schtasks /delete /tn $taskName /f 2>&1 | Out-Null
} catch {}

Write-Info "Creating scheduled task '$taskName' (every 1 minute, internally polls every 10s)..."

$result = schtasks /create /tn $taskName /tr "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" /sc minute /mo 1 /ru SYSTEM /f
if ($LASTEXITCODE -eq 0) {
    Write-Success "Scheduled task '$taskName' created (every 1 minute, internal 10s polling loop)"
} else {
    Write-Fail "Failed to create scheduled task (run as admin for SYSTEM account, or remove /ru SYSTEM)"
    Write-Info "Manual command: schtasks /create /tn `"$taskName`" /tr `"powershell -ExecutionPolicy Bypass -File $scriptPath`" /sc minute /mo 1"
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

Write-Step "Vision Analysis Setup Complete"

Write-Host ""
Write-Host "  Sensors created:" -ForegroundColor Green
Write-Host "    - sensor.chicken_count          (Chicken Count)" -ForegroundColor White
Write-Host "    - sensor.breakfast_food          (Breakfast Food)" -ForegroundColor White
Write-Host "    - sensor.lunch_food              (Lunch Food)" -ForegroundColor White
Write-Host "    - sensor.dinner_food             (Dinner Food)" -ForegroundColor White
Write-Host "    - sensor.main_gate_status        (Main Gate Status)" -ForegroundColor White
Write-Host "    - sensor.main_gate_car_count     (Main Gate Car Count)" -ForegroundColor White
Write-Host "    - sensor.visitor_gate_status      (Visitor Gate Status)" -ForegroundColor White
Write-Host "    - sensor.visitor_gate_car_count   (Visitor Gate Car Count)" -ForegroundColor White
Write-Host "    - sensor.vision_analysis_stats    (Vision Analysis Stats - daily counts)" -ForegroundColor White
Write-Host "    - sensor.pool_adult_count         (Pool Adult Count)" -ForegroundColor White
Write-Host "    - sensor.pool_child_count         (Pool Child Count)" -ForegroundColor White
Write-Host "    - sensor.pool_cover_status        (Pool Cover Status)" -ForegroundColor White
Write-Host "    - sensor.left_garage_door         (Left Garage Door)" -ForegroundColor White
Write-Host "    - sensor.right_garage_door        (Right Garage Door)" -ForegroundColor White
Write-Host ""
Write-Host "  Automations created:" -ForegroundColor Green
Write-Host "    1. Main Gate Open Too Long    - sensor open > 10 min -> TTS" -ForegroundColor White
Write-Host "    2. Visitor Gate Open Too Long  - sensor open > 10 min -> TTS" -ForegroundColor White
Write-Host "    3. Chickens Not Inside         - 8PM + count < 1 -> TTS" -ForegroundColor White
Write-Host "    4. Chickens Not Outside        - 8AM + count > 0 -> TTS" -ForegroundColor White
Write-Host ""
Write-Host "  Scheduled task: $taskName (every 1 min, internal 10s loop)" -ForegroundColor Green
Write-Host ""
Write-Host "  Camera schedules:" -ForegroundColor Green
Write-Host "    - Chickens:     1hr (60s at roost times, motion-only during day)" -ForegroundColor White
Write-Host "    - Backyard:     motion-only (24/7)" -ForegroundColor White
Write-Host "    - BackDoor:     motion-only (24/7)" -ForegroundColor White
Write-Host "    - VeggieGarden: motion-only (24/7)" -ForegroundColor White
Write-Host "    - DiningRoom:   motion-only (24/7)" -ForegroundColor White
Write-Host "    - Kitchen:      30min (10min during meals)" -ForegroundColor White
Write-Host "    - Lawn:         motion-only day, 5min night (+ motion)" -ForegroundColor White
Write-Host "    - MainGate:     5min day, 30min night" -ForegroundColor White
Write-Host "    - VisitorGate:  5min day, 30min night" -ForegroundColor White
Write-Host "    - Pool:         5min (scheduled only)" -ForegroundColor White
Write-Host "    - Garage:       15min day, 5min night" -ForegroundColor White
Write-Host "    - Lounge:       15min (scheduled only)" -ForegroundColor White
Write-Host "    - Street:       EXCLUDED from analysis" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Run 08a-Run-VisionAnalysis.ps1 manually to test" -ForegroundColor Yellow
Write-Host "    2. Check Developer Tools > States for sensor updates" -ForegroundColor Yellow
Write-Host "    3. Check logs at deploy/logs/vision_analysis.log" -ForegroundColor Yellow
Write-Host "    4. Verify Tapo motion sensor entity IDs in HA" -ForegroundColor Yellow
Write-Host ""
