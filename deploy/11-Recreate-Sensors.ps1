<#
.SYNOPSIS
    Recreate all custom sensors that don't survive HA restarts.

.DESCRIPTION
    Sensors created via POST /api/states are temporary and vanish when HA restarts.
    This script recreates all vision analysis and farm camera sensors with initial
    placeholder values. The scheduled runner scripts (08a, 10a) will populate them
    with real data on their next cycle.

    Should run:
    - Automatically on server boot (via HA-RecreateSensors scheduled task)
    - Manually after any HA restart or power loss
    - Waits for HA to be accessible before creating sensors

.EXAMPLE
    .\11-Recreate-Sensors.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

$logDir  = Join-Path $scriptDir "logs"
$logFile = Join-Path $logDir "recreate_sensors.log"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    Write-Host "  [$Level] $Message"
}

# Trim log
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    $lines = Get-Content $logFile -Tail 500
    $lines | Set-Content $logFile
}

Write-Log "=== Sensor recreation starting ==="

# ============================================================
# Wait for HA to be accessible (up to 5 minutes after boot)
# ============================================================

$haBase = "http://$($Config.HA_IP):8123"
$headers = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

$maxWait = 300  # 5 minutes
$waited = 0
$haReady = $false

Write-Log "Waiting for HA to be accessible at $haBase..."

while ($waited -lt $maxWait) {
    try {
        $null = Invoke-RestMethod -Uri "$haBase/api/" -Headers $headers -TimeoutSec 5
        $haReady = $true
        break
    } catch {
        Start-Sleep -Seconds 10
        $waited += 10
        if ($waited % 60 -eq 0) { Write-Log "Still waiting... ($waited seconds)" }
    }
}

if (-not $haReady) {
    Write-Log "HA not accessible after $maxWait seconds - aborting" "ERROR"
    exit 1
}

Write-Log "HA accessible after $waited seconds"

# ============================================================
# Sensor definitions — all custom sensors that need recreation
# ============================================================

$sensors = @(
    # Home Vision Analysis sensors (from 08-Setup-VisionAnalysis.ps1)
    @{ entity_id = "sensor.chicken_count";          state = "0";       attributes = @{ friendly_name = "Chicken Count";          icon = "mdi:chicken";         unit_of_measurement = "chickens" } }
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

    # Farm Vision Analysis sensors (from 10-Setup-Ezviz.ps1)
    @{ entity_id = "sensor.farm_cam_1_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 1"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_2_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 2"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_3_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 3"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_4_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 4"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_5_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 5"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_cam_6_status"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 6"; icon = "mdi:cctv"; source = "ezviz" } }
    @{ entity_id = "sensor.farm_fire_smoke";   state = "none";    attributes = @{ friendly_name = "Farm Fire/Smoke"; icon = "mdi:fire-alert"; cameras_detecting = "" } }
    @{ entity_id = "sensor.farm_rain_status";  state = "none";    attributes = @{ friendly_name = "Farm Rain Status"; icon = "mdi:weather-rainy"; intensity = "none" } }
    @{ entity_id = "sensor.farm_animal_summary"; state = "none detected"; attributes = @{ friendly_name = "Farm Animals"; icon = "mdi:cow"; total_count = 0 } }
    @{ entity_id = "sensor.farm_human_vehicle_summary"; state = "clear"; attributes = @{ friendly_name = "Farm Humans/Vehicles"; icon = "mdi:account-alert"; human_count = 0; vehicle_count = 0 } }

    # Farm battery sensors
    @{ entity_id = "sensor.farm_cam_1_battery"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 1 Battery"; icon = "mdi:battery"; device_class = "battery"; unit_of_measurement = "%" } }
    @{ entity_id = "sensor.farm_cam_3_battery"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 3 Battery"; icon = "mdi:battery"; device_class = "battery"; unit_of_measurement = "%" } }
    @{ entity_id = "sensor.farm_cam_5_battery"; state = "unknown"; attributes = @{ friendly_name = "Farm Camera 5 Battery"; icon = "mdi:battery"; device_class = "battery"; unit_of_measurement = "%" } }

    # Weather briefing sensor
    @{ entity_id = "sensor.weather_briefing"; state = "unknown"; attributes = @{ friendly_name = "Weather Briefing"; icon = "mdi:weather-partly-cloudy" } }

    # Street camera object detection sensors (from 15-Setup-ObjectDetection.ps1)
    @{ entity_id = "sensor.street_cam_detections_today"; state = "0";       attributes = @{ friendly_name = "Street Cam Detections Today"; icon = "mdi:cctv";           unit_of_measurement = "detections"; by_type = @{}; hourly = @{} } }
    @{ entity_id = "sensor.street_cam_people_today";     state = "0";       attributes = @{ friendly_name = "Street Cam People Today";     icon = "mdi:walk";           unit_of_measurement = "people" } }
    @{ entity_id = "sensor.street_cam_vehicles_today";   state = "0";       attributes = @{ friendly_name = "Street Cam Vehicles Today";   icon = "mdi:car";            unit_of_measurement = "vehicles" } }
    @{ entity_id = "sensor.street_cam_last_detection";   state = "unknown"; attributes = @{ friendly_name = "Street Cam Last Detection";   icon = "mdi:clock-outline"  } }
    @{ entity_id = "sensor.street_cam_last_object";      state = "none";    attributes = @{ friendly_name = "Street Cam Last Object";      icon = "mdi:shape"          } }
    @{ entity_id = "sensor.street_cam_status";           state = "offline"; attributes = @{ friendly_name = "Street Cam Detection Status"; icon = "mdi:alert-circle"   } }
    @{ entity_id = "sensor.street_cam_last_plate";           state = "none"; attributes = @{ friendly_name = "Street Cam Last Plate";           icon = "mdi:car-info" } }
    @{ entity_id = "sensor.street_cam_known_plates_today"; state = "0"; attributes = @{ friendly_name = "Street Cam Known Plates Today"; icon = "mdi:car-multiple"; unit_of_measurement = "sightings"; plates = @() } }
    @{ entity_id = "sensor.street_cam_person_1";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 1";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_2";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 2";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_3";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 3";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_4";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 4";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_5";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 5";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_vehicle_1"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 1"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_2"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 2"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_3"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 3"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_4"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 4"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_5"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 5"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_loitering"; state = "clear"; attributes = @{ friendly_name = "Street Cam Loitering"; icon = "mdi:account-clock" } }

    # Loitering verification counters
    @{ entity_id = "sensor.street_cam_unconfirmed_loitering_today"; state = "0"; attributes = @{ friendly_name = "Street Cam Unconfirmed Loitering Today"; icon = "mdi:account-question"; unit_of_measurement = "detections" } }
    @{ entity_id = "sensor.street_cam_confirmed_loitering_today";   state = "0"; attributes = @{ friendly_name = "Street Cam Confirmed Loitering Today";   icon = "mdi:account-check";    unit_of_measurement = "detections" } }
    @{ entity_id = "sensor.street_cam_false_loitering_today";       state = "0"; attributes = @{ friendly_name = "Street Cam False Loitering Today";       icon = "mdi:account-cancel";   unit_of_measurement = "detections" } }
)

# ============================================================
# Create sensors
# ============================================================

$created = 0
$failed = 0

foreach ($sensor in $sensors) {
    # Check if sensor already exists with a real state (not just recreated)
    try {
        $existing = Invoke-RestMethod -Uri "$haBase/api/states/$($sensor.entity_id)" -Headers $headers -TimeoutSec 5
        if ($existing.state -and $existing.state -ne "unknown" -and $existing.state -ne "unavailable") {
            # Sensor exists with real data — skip to avoid overwriting
            continue
        }
    } catch {
        # 404 = doesn't exist, need to create
    }

    $body = @{
        state      = $sensor.state
        attributes = $sensor.attributes
    } | ConvertTo-Json -Depth 5

    try {
        $null = Invoke-WebRequest `
            -Uri "$haBase/api/states/$($sensor.entity_id)" `
            -Method POST -Headers $headers `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 10
        $created++
    } catch {
        Write-Log "Failed: $($sensor.entity_id) - $($_.Exception.Message)" "ERROR"
        $failed++
    }
}

Write-Log "=== Done: $created created, $failed failed, $($sensors.Count - $created - $failed) skipped (already had data) ==="
