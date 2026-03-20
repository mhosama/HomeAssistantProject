<#
.SYNOPSIS
    Validate HA deployment integrity — sensors, cameras, automations, dashboards, scheduled tasks.

.DESCRIPTION
    Read-only check that verifies all expected entities and infrastructure exist and are healthy.
    Run after any deployment change. Exit code 0 = all pass, 1 = any failures.

    Categories checked:
    1. HA Connectivity
    2. Sensors (49)
    3. Cameras (20)
    4. Automations (14)
    5. Dashboards (9)
    6. Scheduled Tasks (8) — server only, skipped on dev PC
    7. Host Processes (5) — server only, verifies detection pipeline + log freshness + sensor recency

.EXAMPLE
    .\17-Integrity-Check.ps1
    .\17-Integrity-Check.ps1 -IncludeTasks   # also check scheduled tasks (run on server)
#>

param(
    [switch]$IncludeTasks
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# Output helpers
# ============================================================

$script:passCount = 0
$script:warnCount = 0
$script:failCount = 0
$script:skipCount = 0

function Write-Check {
    param([string]$Level, [string]$Msg)
    switch ($Level) {
        "PASS" { Write-Host ("  [PASS] " + $Msg) -ForegroundColor Green;   $script:passCount++ }
        "WARN" { Write-Host ("  [WARN] " + $Msg) -ForegroundColor Yellow;  $script:warnCount++ }
        "FAIL" { Write-Host ("  [FAIL] " + $Msg) -ForegroundColor Red;     $script:failCount++ }
        "SKIP" { Write-Host ("  [SKIP] " + $Msg) -ForegroundColor DarkGray; $script:skipCount++ }
    }
}

function Write-Header { param([string]$msg) Write-Host ("`n--- " + $msg + " ---") -ForegroundColor Cyan }

# ============================================================
# Entity check helper — returns array of failure lines
# ============================================================

function Test-Entities {
    param(
        [string]$Category,
        [string[]]$Expected,
        [hashtable]$StateMap,
        [string]$BadState = "unavailable",
        [string]$GoodState = $null  # if set, state must equal this
    )

    $pass = 0
    $fails = @()

    foreach ($eid in $Expected) {
        if (-not $StateMap.ContainsKey($eid)) {
            $fails += @{ Level = "FAIL"; Msg = "$eid - not found" }
        } elseif ($GoodState -and $StateMap[$eid] -ne $GoodState) {
            $fails += @{ Level = "WARN"; Msg = "$eid - state: $($StateMap[$eid])" }
        } elseif ($StateMap[$eid] -eq $BadState) {
            $fails += @{ Level = "WARN"; Msg = "$eid - $BadState" }
        } else {
            $pass++
        }
    }

    $total = $Expected.Count
    if ($fails.Count -eq 0) {
        Write-Check "PASS" ($Category + ": " + $pass + "/" + $total)
    } else {
        $failItems = @($fails | Where-Object { $_.Level -eq "FAIL" }).Count
        $warnItems = @($fails | Where-Object { $_.Level -eq "WARN" }).Count
        $detail = @()
        if ($failItems -gt 0) { $detail += "$failItems missing" }
        if ($warnItems -gt 0) { $detail += "$warnItems issues" }

        if ($failItems -gt 0) {
            Write-Check "FAIL" ($Category + ": " + $pass + "/" + $total + " (" + ($detail -join ", ") + ")")
        } else {
            Write-Check "WARN" ($Category + ": " + $pass + "/" + $total + " (" + ($detail -join ", ") + ")")
        }
        foreach ($f in $fails) {
            if ($f.Level -eq "FAIL") { Write-Host ("    " + $f.Msg) -ForegroundColor Red }
            else { Write-Host ("    " + $f.Msg) -ForegroundColor Yellow }
        }
    }
}

# ============================================================
# HA API helpers
# ============================================================

$haBase = "http://$($Config.HA_IP):8123"
$headers = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

# ============================================================
# WebSocket helpers (for dashboard checks)
# ============================================================

$script:ws = $null
$script:cts = $null
$script:wsId = 0

function Connect-HAWS {
    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $script:cts.CancelAfter(30000)
    $script:wsId = 0
    $uri = [Uri]"ws://$($Config.HA_IP):8123/api/websocket"
    $script:ws.ConnectAsync($uri, $script:cts.Token).Wait()
    $null = Receive-HAWS
    $authMsg = @{type = "auth"; access_token = $Config.HA_TOKEN} | ConvertTo-Json -Compress
    Send-HAWS $authMsg
    $authResp = Receive-HAWS | ConvertFrom-Json
    if ($authResp.type -ne "auth_ok") { throw "WebSocket auth failed" }
    return $authResp.ha_version
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
        try { $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait() } catch {}
    }
}

# ============================================================
# Expected entities
# ============================================================

$expectedSensors = @(
    # Home Vision (16)
    "sensor.chicken_count", "sensor.egg_count",
    "sensor.breakfast_food", "sensor.lunch_food", "sensor.dinner_food",
    "sensor.main_gate_status", "sensor.main_gate_car_count",
    "sensor.visitor_gate_status", "sensor.visitor_gate_car_count",
    "sensor.vision_analysis_stats", "sensor.vision_last_detections",
    "sensor.pool_adult_count", "sensor.pool_child_count", "sensor.pool_cover_status",
    "sensor.left_garage_door", "sensor.right_garage_door",

    # Farm Vision (14)
    "sensor.farm_cam_1_status", "sensor.farm_cam_2_status", "sensor.farm_cam_3_status",
    "sensor.farm_cam_4_status", "sensor.farm_cam_5_status", "sensor.farm_cam_6_status",
    "sensor.farm_fire_smoke", "sensor.farm_rain_status",
    "sensor.farm_animal_summary", "sensor.farm_human_vehicle_summary", "sensor.farm_last_detections",
    "sensor.farm_cam_1_battery", "sensor.farm_cam_3_battery", "sensor.farm_cam_5_battery",

    # Template sensors (config flow - survive restarts)
    "sensor.battery_soc", "sensor.lights_on_count", "sensor.doors_open_count",
    "sensor.solar_vs_load", "sensor.pool_temperature", "sensor.battery_time_to_twenty",

    # Weather + Battery (2)
    "sensor.weather_briefing", "sensor.battery_projection",

    # Street Cam (23)
    "sensor.street_cam_detections_today", "sensor.street_cam_people_today", "sensor.street_cam_vehicles_today",
    "sensor.street_cam_last_detection", "sensor.street_cam_last_object", "sensor.street_cam_status",
    "sensor.street_cam_last_plate", "sensor.street_cam_known_plates_today", "sensor.street_cam_plate_ocr_stats",
    "sensor.street_cam_person_1", "sensor.street_cam_person_2", "sensor.street_cam_person_3",
    "sensor.street_cam_person_4", "sensor.street_cam_person_5",
    "sensor.street_cam_vehicle_1", "sensor.street_cam_vehicle_2", "sensor.street_cam_vehicle_3",
    "sensor.street_cam_vehicle_4", "sensor.street_cam_vehicle_5",
    "sensor.street_cam_loitering",
    "sensor.street_cam_unconfirmed_loitering_today", "sensor.street_cam_confirmed_loitering_today", "sensor.street_cam_false_loitering_today"
)

$expectedCameras = @(
    # Tapo HD + SD (14)
    "camera.chickens_hd_stream", "camera.chickens_sd_stream",
    "camera.backyard_camera_hd_stream", "camera.backyard_camera_sd_stream",
    "camera.back_door_camera_hd_stream", "camera.back_door_camera_sd_stream",
    "camera.veggie_garden_hd_stream", "camera.veggie_garden_sd_stream",
    "camera.dining_room_camera_hd_stream", "camera.dining_room_camera_sd_stream",
    "camera.kitchen_camera_hd_stream", "camera.kitchen_camera_sd_stream",
    "camera.lawn_camera_hd_stream", "camera.lawn_camera_sd_stream",
    # RTSP (6)
    "camera.main_gate_camera", "camera.visitor_gate_camera", "camera.pool_camera",
    "camera.garage_camera", "camera.lounge_camera", "camera.street_camera",
    # EZVIZ farm (3)
    "camera.farm_camera_1", "camera.farm_camera_3", "camera.farm_camera_5"
)

$expectedAutomations = @(
    "automation.morning_greeting",
    "automation.gate_open_alert",
    "automation.geyser_alert",
    "automation.battery_fully_charged",
    "automation.inverter_room_high_temp",
    "automation.inverter_room_door_closed_hot",
    "automation.main_gate_open_too_long",
    "automation.visitor_gate_open_too_long",
    "automation.chickens_not_inside",
    "automation.chickens_not_outside",
    "automation.play_google_news",
    "automation.good_night",
    "automation.family_member_arrived",
    "automation.family_member_departed",
    "automation.farm_fire_smoke_detected",
    "automation.farm_intruder_detected"
)

$expectedDashboards = @(
    "lovelace",
    "energy-dashboard",
    "lighting-dashboard",
    "security-dashboard",
    "water-climate-dashboard",
    "media-dashboard",
    "info-dashboard",
    "street-stats",
    "family-presence"
)

$expectedTrackers = @(
    "device_tracker.life360_mauritz_kloppers",
    "device_tracker.life360_chandre_kloppers",
    "device_tracker.life360_mauritz_kloppers_2",
    "device_tracker.life360_lizette_kloppers",
    "device_tracker.life360_melandi_gossman"
)

$expectedTasks = @(
    "HA-VisionAnalysis",
    "HA-EzvizVision",
    "HA-RefreshWeather",
    "HA-RefreshNews",
    "HA-RefreshTTTProjection",
    "HA-CameraHealthCheck",
    "HA-RecreateSensors",
    "HA-CameraObjectDetection"
)

# ============================================================
# Check 1: HA Connectivity
# ============================================================

Write-Host ""
Write-Host "=== HA Integrity Check ===" -ForegroundColor White
Write-Header "HA Connectivity"

$haVersion = $null
try {
    $apiResp = Invoke-RestMethod -Uri "$haBase/api/" -Headers $headers -TimeoutSec 5
    $haVersion = $apiResp.version
    Write-Check "PASS" "HA reachable (v$haVersion)"
} catch {
    Write-Check "FAIL" "HA not accessible at $haBase"
    Write-Host "`nCannot reach HA - aborting." -ForegroundColor Red
    exit 1
}

# ============================================================
# Fetch all states (single API call)
# ============================================================

$allStates = Invoke-RestMethod -Uri "$haBase/api/states" -Headers $headers -TimeoutSec 10
$stateMap = @{}
foreach ($s in $allStates) { $stateMap[$s.entity_id] = $s.state }

# ============================================================
# Check 2: Sensors
# ============================================================

$sensorTotal = $expectedSensors.Count
Write-Header "Sensors ($sensorTotal expected)"
Test-Entities -Category "Sensors" -Expected $expectedSensors -StateMap $stateMap

# ============================================================
# Check 3: Cameras
# ============================================================

$camTotal = $expectedCameras.Count
Write-Header "Cameras ($camTotal expected)"
Test-Entities -Category "Cameras" -Expected $expectedCameras -StateMap $stateMap

# ============================================================
# Check 4: Automations
# ============================================================

$autoTotal = $expectedAutomations.Count
Write-Header "Automations ($autoTotal expected)"
Test-Entities -Category "Automations" -Expected $expectedAutomations -StateMap $stateMap -GoodState "on"

# ============================================================
# Check 5: Device Trackers (Life360)
# ============================================================

$trackerTotal = $expectedTrackers.Count
Write-Header "Device Trackers ($trackerTotal expected)"
Test-Entities -Category "Device Trackers" -Expected $expectedTrackers -StateMap $stateMap

# ============================================================
# Check 6: Dashboards (via WebSocket)
# ============================================================

$dashTotal = $expectedDashboards.Count
Write-Header "Dashboards ($dashTotal expected)"

try {
    $wsVersion = Connect-HAWS
    $dashResp = Invoke-WSCommand -Type "lovelace/dashboards/list"
    Disconnect-HAWS

    # Built-in default dashboard has url_path = null, mapped to "lovelace"
    $dashPaths = @("lovelace")  # default always exists
    if ($dashResp.result) {
        foreach ($d in $dashResp.result) {
            if ($d.url_path) { $dashPaths += $d.url_path }
        }
    }

    $dashPass = 0
    $dashFails = @()

    foreach ($path in $expectedDashboards) {
        if ($dashPaths -contains $path) {
            $dashPass++
        } else {
            $dashFails += $path
        }
    }

    if ($dashFails.Count -eq 0) {
        Write-Check "PASS" "Dashboards: $dashPass/$dashTotal"
    } else {
        $missing = $dashFails.Count
        Write-Check "FAIL" ("Dashboards: $dashPass/$dashTotal ($missing missing)")
        foreach ($p in $dashFails) { Write-Host ("    " + $p + " - not found") -ForegroundColor Red }
    }
} catch {
    Write-Check "WARN" ("Dashboards: WebSocket check failed - " + $_.Exception.Message)
}

# ============================================================
# Check 7: Scheduled Tasks (server only)
# ============================================================

$taskTotal = $expectedTasks.Count
Write-Header "Scheduled Tasks ($taskTotal expected)"

if ($IncludeTasks) {
    try {
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*HA-*" }

        $taskPass = 0
        $taskFails = @()

        foreach ($name in $expectedTasks) {
            $task = $allTasks | Where-Object { $_.TaskName -eq $name }
            if (-not $task) {
                $taskFails += @{ Level = "FAIL"; Msg = "$name - not found" }
            } elseif ($task.State -eq "Disabled") {
                $taskFails += @{ Level = "WARN"; Msg = "$name - disabled" }
            } else {
                $taskPass++
            }
        }

        if ($taskFails.Count -eq 0) {
            Write-Check "PASS" "Scheduled Tasks: $taskPass/$taskTotal"
        } else {
            $failItems = @($taskFails | Where-Object { $_.Level -eq "FAIL" }).Count
            $warnItems = @($taskFails | Where-Object { $_.Level -eq "WARN" }).Count
            $detail = @()
            if ($failItems -gt 0) { $detail += "$failItems missing" }
            if ($warnItems -gt 0) { $detail += "$warnItems disabled" }

            if ($failItems -gt 0) {
                Write-Check "FAIL" ("Scheduled Tasks: $taskPass/$taskTotal (" + ($detail -join ", ") + ")")
            } else {
                Write-Check "WARN" ("Scheduled Tasks: $taskPass/$taskTotal (" + ($detail -join ", ") + ")")
            }
            foreach ($f in $taskFails) {
                if ($f.Level -eq "FAIL") { Write-Host ("    " + $f.Msg) -ForegroundColor Red }
                else { Write-Host ("    " + $f.Msg) -ForegroundColor Yellow }
            }
        }
    } catch {
        Write-Check "WARN" ("Scheduled Tasks: check failed - " + $_.Exception.Message)
    }
} else {
    Write-Check "SKIP" "Scheduled Tasks (use -IncludeTasks on server)"
}

# ============================================================
# Check 8: Host Processes (server only)
# ============================================================

Write-Header "Host Processes"

if ($IncludeTasks) {
    try {
        $expectedProcesses = @(
            @{ Name = "CameraObjectDetection Supervisor"; Pattern = "supervisor.py" },
            @{ Name = "RTSP Frame Sampler"; Pattern = "SampleImages.py" },
            @{ Name = "Object Detector"; Pattern = "DetectObjects3.py" },
            @{ Name = "Crop Processor"; Pattern = "ProcessCropFiles.py" },
            @{ Name = "HA Metrics Publisher"; Pattern = "ha_metrics.py" }
        )

        $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*python*" }

        $procPass = 0
        $procFails = @()

        foreach ($ep in $expectedProcesses) {
            $found = $allProcs | Where-Object { $_.CommandLine -like "*$($ep.Pattern)*" }
            if ($found) {
                $procPass++
            } else {
                $procFails += @{ Level = "FAIL"; Msg = "$($ep.Name) ($($ep.Pattern)) - not running" }
            }
        }

        $procTotal = $expectedProcesses.Count
        if ($procFails.Count -eq 0) {
            Write-Check "PASS" "Host Processes: $procPass/$procTotal"
        } else {
            Write-Check "FAIL" ("Host Processes: $procPass/$procTotal ($($procFails.Count) not running)")
            foreach ($f in $procFails) {
                Write-Host ("    " + $f.Msg) -ForegroundColor Red
            }
        }

        # Log freshness checks
        $scriptRoot = Split-Path -Parent $scriptDir
        $logChecks = @(
            @{ Name = "supervisor.log";      Path = "$scriptRoot\CameraObjectDetection\logs\supervisor.log"; MaxAgeMin = 2 },
            @{ Name = "process_crops.log";   Path = "$scriptRoot\CameraObjectDetection\logs\process_crops.log"; MaxAgeMin = 2 },
            @{ Name = "vision_analysis.log"; Path = "$scriptDir\logs\vision_analysis.log"; MaxAgeMin = 15 }
        )

        $logPass = 0
        $logFails = @()

        foreach ($lc in $logChecks) {
            if (-not (Test-Path $lc.Path)) {
                $logFails += @{ Level = "WARN"; Msg = "$($lc.Name) - file not found" }
            } else {
                $lastWrite = (Get-Item $lc.Path).LastWriteTime
                $ageMin = [math]::Round(((Get-Date) - $lastWrite).TotalMinutes, 1)
                if ($ageMin -gt $lc.MaxAgeMin) {
                    $logFails += @{ Level = "WARN"; Msg = "$($lc.Name) - stale (${ageMin}m ago, expected < $($lc.MaxAgeMin)m)" }
                } else {
                    $logPass++
                }
            }
        }

        $logTotal = $logChecks.Count
        if ($logFails.Count -eq 0) {
            Write-Check "PASS" "Log Freshness: $logPass/$logTotal"
        } else {
            if (@($logFails | Where-Object { $_.Level -eq "FAIL" }).Count -gt 0) {
                Write-Check "FAIL" ("Log Freshness: $logPass/$logTotal ($($logFails.Count) issues)")
            } else {
                Write-Check "WARN" ("Log Freshness: $logPass/$logTotal ($($logFails.Count) stale)")
            }
            foreach ($f in $logFails) {
                if ($f.Level -eq "FAIL") { Write-Host ("    " + $f.Msg) -ForegroundColor Red }
                else { Write-Host ("    " + $f.Msg) -ForegroundColor Yellow }
            }
        }

        # Sensor recency checks
        $sensorRecency = @(
            @{ Name = "street_cam_status"; Entity = "sensor.street_cam_status"; MaxAgeMin = 5 },
            @{ Name = "vision_analysis_stats"; Entity = "sensor.vision_analysis_stats"; MaxAgeMin = 15 }
        )

        $sensorPass = 0
        $sensorFails = @()

        foreach ($sr in $sensorRecency) {
            $entity = $allStates | Where-Object { $_.entity_id -eq $sr.Entity }
            if (-not $entity) {
                $sensorFails += @{ Level = "WARN"; Msg = "$($sr.Name) - sensor not found" }
            } elseif ($entity.state -eq "unavailable" -or $entity.state -eq "unknown") {
                $sensorFails += @{ Level = "WARN"; Msg = "$($sr.Name) - state: $($entity.state)" }
            } else {
                $lastChanged = [DateTime]::Parse($entity.last_changed).ToLocalTime()
                $ageMin = [math]::Round(((Get-Date) - $lastChanged).TotalMinutes, 1)
                if ($ageMin -gt $sr.MaxAgeMin) {
                    $sensorFails += @{ Level = "WARN"; Msg = "$($sr.Name) - last updated ${ageMin}m ago (expected < $($sr.MaxAgeMin)m)" }
                } else {
                    $sensorPass++
                }
            }
        }

        $sensorTotal = $sensorRecency.Count
        if ($sensorFails.Count -eq 0) {
            Write-Check "PASS" "Sensor Recency: $sensorPass/$sensorTotal"
        } else {
            Write-Check "WARN" ("Sensor Recency: $sensorPass/$sensorTotal ($($sensorFails.Count) stale)")
            foreach ($f in $sensorFails) {
                Write-Host ("    " + $f.Msg) -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Check "WARN" ("Host Processes: check failed - " + $_.Exception.Message)
    }
} else {
    Write-Check "SKIP" "Host Processes (use -IncludeTasks on server)"
}

# ============================================================
# Summary
# ============================================================

Write-Host ""
Write-Host "==============================" -ForegroundColor White

$summaryParts = @()
if ($script:passCount -gt 0) { $summaryParts += "$($script:passCount) passed" }
if ($script:warnCount -gt 0) { $summaryParts += "$($script:warnCount) warnings" }
if ($script:failCount -gt 0) { $summaryParts += "$($script:failCount) failed" }
if ($script:skipCount -gt 0) { $summaryParts += "$($script:skipCount) skipped" }

$summaryText = "Summary: " + ($summaryParts -join ", ")

if ($script:failCount -gt 0) {
    Write-Host $summaryText -ForegroundColor Red
    exit 1
} elseif ($script:warnCount -gt 0) {
    Write-Host $summaryText -ForegroundColor Yellow
    exit 0
} else {
    Write-Host $summaryText -ForegroundColor Green
    exit 0
}
