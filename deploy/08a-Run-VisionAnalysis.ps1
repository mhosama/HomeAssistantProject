<#
.SYNOPSIS
    Capture snapshots from cameras on schedule, analyze with Gemini Flash, update HA sensors and fire alerts.

.DESCRIPTION
    Runs every 1 minute via Windows Scheduled Task (HA-VisionAnalysis).
    Internally loops 6 times at 10-second intervals (effective 10s polling).
    - Each camera has its own schedule (10s/30s/60s/5min/10min/30min/1hr)
    - Time-of-day overrides change schedule at specific hours
    - Tapo cameras support motion-triggered burst mode (tapering: 10s -> 60s -> 120s)
    - Only processes cameras that are "due" each tick (most ticks skip most cameras)
    - Uses mutex to prevent overlapping runs
    - Each camera runs in its own runspace for parallel execution
    - Daily analysis counts tracked per camera with 30-day history

.EXAMPLE
    .\08a-Run-VisionAnalysis.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

# ============================================================
# Mutex - prevent overlapping runs
# ============================================================

$mutexName = "Global\HA-VisionAnalysis"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)

if (-not $mutex.WaitOne(0)) {
    # Another instance is running, exit silently
    exit 0
}

try {

# ============================================================
# Configuration
# ============================================================

$haBase     = "http://$($Config.HA_IP):8123"
$haToken    = $Config.HA_TOKEN
$geminiKey  = $Config.GeminiApiKey
$geminiModel = $Config.GeminiModel

$logDir  = Join-Path $scriptDir "logs"
$logFile = Join-Path $logDir "vision_analysis.log"
$stateFile = Join-Path $scriptDir ".vision_state.json"
$sambaWww = "\\192.168.0.239\config\www"

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ============================================================
# Schedule intervals (seconds)
# ============================================================

$scheduleIntervals = @{
    "10s"   = 10
    "30s"   = 30
    "60s"   = 60
    "2min"  = 120
    "5min"  = 300
    "10min" = 600
    "15min" = 900
    "30min" = 1800
    "1hr"   = 3600
}

# ============================================================
# Logging
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

# Trim log file if > 5MB
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 5MB)) {
    $lines = Get-Content $logFile -Tail 1000
    $lines | Set-Content $logFile
}

# $now, $hour, etc. are recalculated each tick in the polling loop below

# ============================================================
# State file (alert throttling + food tracking + camera schedules)
# ============================================================

$defaultState = @{
    last_alerts = @{}
    food_items  = @{
        breakfast = @{ date = ""; items = @(); timestamps = @() }
        lunch    = @{ date = ""; items = @(); timestamps = @() }
        dinner   = @{ date = ""; items = @(); timestamps = @() }
    }
    camera_schedules = @{}
    garage_doors = @{
        left_first_open  = $null
        right_first_open = $null
    }
    detection_history = @{}
    last_run    = ""
}

if (Test-Path $stateFile) {
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        # Ensure all keys exist
        if (-not $state.last_alerts) { $state | Add-Member -NotePropertyName "last_alerts" -NotePropertyValue @{} -Force }
        # Migrate from old food_last_detected to new food_items structure
        if (-not $state.food_items) {
            $emptyMeal = @{ date = ""; items = @(); timestamps = @() }
            $state | Add-Member -NotePropertyName "food_items" -NotePropertyValue @{
                breakfast = $emptyMeal.Clone()
                lunch    = $emptyMeal.Clone()
                dinner   = $emptyMeal.Clone()
            } -Force
        } else {
            # Ensure each meal has the required fields
            foreach ($meal in @("breakfast", "lunch", "dinner")) {
                $m = $state.food_items.$meal
                if (-not $m) {
                    $state.food_items | Add-Member -NotePropertyName $meal -NotePropertyValue @{ date = ""; items = @(); timestamps = @() } -Force
                } else {
                    if (-not $m.PSObject.Properties["items"]) { $m | Add-Member -NotePropertyName "items" -NotePropertyValue @() -Force }
                    if (-not $m.PSObject.Properties["timestamps"]) { $m | Add-Member -NotePropertyName "timestamps" -NotePropertyValue @() -Force }
                    if (-not $m.PSObject.Properties["date"]) { $m | Add-Member -NotePropertyName "date" -NotePropertyValue "" -Force }
                }
            }
        }
        # Ensure camera_schedules exists
        if (-not $state.PSObject.Properties["camera_schedules"]) {
            $state | Add-Member -NotePropertyName "camera_schedules" -NotePropertyValue (New-Object PSObject) -Force
        }
        # Ensure garage_doors exists
        if (-not $state.PSObject.Properties["garage_doors"]) {
            $state | Add-Member -NotePropertyName "garage_doors" -NotePropertyValue ([PSCustomObject]@{
                left_first_open  = $null
                right_first_open = $null
            }) -Force
        } else {
            if (-not $state.garage_doors.PSObject.Properties["left_first_open"]) {
                $state.garage_doors | Add-Member -NotePropertyName "left_first_open" -NotePropertyValue $null -Force
            }
            if (-not $state.garage_doors.PSObject.Properties["right_first_open"]) {
                $state.garage_doors | Add-Member -NotePropertyName "right_first_open" -NotePropertyValue $null -Force
            }
        }
        # Ensure detection_history exists
        if (-not $state.PSObject.Properties["detection_history"]) {
            $state | Add-Member -NotePropertyName "detection_history" -NotePropertyValue (New-Object PSObject) -Force
        }
    } catch {
        $state = $defaultState | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    }
} else {
    $state = $defaultState | ConvertTo-Json -Depth 5 | ConvertFrom-Json
}

function Test-AlertThrottled {
    param([string]$Key, [int]$MinutesCooldown = 5)
    $lastStr = $state.last_alerts.PSObject.Properties[$Key]
    if ($lastStr) {
        $lastTime = [DateTime]::Parse($lastStr.Value)
        return ($now - $lastTime).TotalMinutes -lt $MinutesCooldown
    }
    return $false
}

function Set-AlertTime {
    param([string]$Key)
    if (-not $state.last_alerts.PSObject.Properties[$Key]) {
        $state.last_alerts | Add-Member -NotePropertyName $Key -NotePropertyValue $now.ToString("o") -Force
    } else {
        $state.last_alerts.$Key = $now.ToString("o")
    }
}

# ============================================================
# Alert configuration (per camera, per alert type)
# ============================================================

$alertConfig = @{
    "Chickens_missing"      = @{ TTS = $true;  Phone = $true  }
    "Backyard_human"        = @{ TTS = $true;  Phone = $true  }
    "BackDoor_human"        = @{ TTS = $true;  Phone = $true  }
    "VeggieGarden_human"    = @{ TTS = $true;  Phone = $true  }
    "DiningRoom_human"      = @{ TTS = $true;  Phone = $true  }
    "Kitchen_human"         = @{ TTS = $true;  Phone = $true  }
    "MainGate_open"         = @{ TTS = $true;  Phone = $true  }
    "VisitorGate_open"      = @{ TTS = $true;  Phone = $true  }
    "Lawn_human"            = @{ TTS = $true;  Phone = $true  }
    "Pool_human"            = @{ TTS = $true;  Phone = $true  }
    "Pool_unsupervised_children" = @{ TTS = $true;  Phone = $true  }
    "Garage_human"          = @{ TTS = $true;  Phone = $true  }
    "Garage_left_door_open" = @{ TTS = $true;  Phone = $true  }
    "Garage_right_door_open" = @{ TTS = $true; Phone = $true  }
    "Lounge_human"          = @{ TTS = $true;  Phone = $true  }
}

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"
$notifyEntity   = $Config.NotifyEntity

# ============================================================
# Detection history helpers
# ============================================================

function Test-IsDetection {
    param([string]$CameraType, [PSObject]$Data)
    switch ($CameraType) {
        "chickens" { return ([int]$Data.chicken_count -gt 0 -and $Data.chickens_visible -eq $true) -or ([int]$Data.egg_count -gt 0 -and $Data.eggs_visible -eq $true) }
        "security" { return ($Data.human_detected -eq $true) }
        "indoor"   { return ($Data.human_detected -eq $true) }
        "kitchen"  { return ($Data.human_detected -eq $true -or $Data.food_visible -eq $true) }
        "gate"     { return ($Data.gate_status -eq "open") }
        "pool"     { return ([int]$Data.adult_count -gt 0 -or [int]$Data.child_count -gt 0) }
        "garage"   { return ($Data.left_garage_door -eq "open" -or $Data.right_garage_door -eq "open" -or $Data.human_detected -eq $true) }
        default    { return $false }
    }
}

function Get-DetectionSummary {
    param([string]$CameraType, [PSObject]$Data)
    switch ($CameraType) {
        "chickens" {
            $parts = @("$($Data.chicken_count) chickens")
            if ([int]$Data.egg_count -gt 0) { $parts += "$($Data.egg_count) eggs" }
            return ($parts -join ", ")
        }
        "security" { return "Human ($($Data.confidence)): $($Data.description)" }
        "indoor"   { return "Human ($($Data.confidence)): $($Data.description)" }
        "kitchen"  {
            $parts = @()
            if ($Data.human_detected -eq $true) { $parts += "Human" }
            if ($Data.food_visible -eq $true -and $Data.food_description) { $parts += "Food: $($Data.food_description)" }
            return ($parts -join "; ")
        }
        "gate"     { return "Gate $($Data.gate_status), $($Data.car_count) cars" }
        "pool"     { return "$($Data.adult_count) adults, $($Data.child_count) children" }
        "garage"   {
            $parts = @("L:$($Data.left_garage_door)", "R:$($Data.right_garage_door)")
            if ($Data.human_detected -eq $true) { $parts += "Human" }
            return ($parts -join " ")
        }
        default    { return "Detection" }
    }
}

function Save-DetectionSnapshot {
    param([string]$CameraName, [byte[]]$ImageBytes, [string]$Timestamp)
    if (-not $ImageBytes -or $ImageBytes.Count -eq 0) { return $null }

    try {
        if (-not (Test-Path $sambaWww)) {
            Write-Log "Samba www not accessible ($sambaWww) - skipping snapshot save for $CameraName" "WARN"
            return $null
        }

        # Get or initialize slot index (1-5 rotating)
        $slotKey = "${CameraName}_slot"
        $currentSlot = 0
        if ($state.detection_history.PSObject.Properties[$slotKey]) {
            $currentSlot = [int]$state.detection_history.$slotKey
        }
        $nextSlot = ($currentSlot % 5) + 1

        $filename = "vision_${CameraName}_${nextSlot}.jpg"
        $fullPath = Join-Path $sambaWww $filename
        [IO.File]::WriteAllBytes($fullPath, $ImageBytes)

        # Update slot index in state
        if ($state.detection_history.PSObject.Properties[$slotKey]) {
            $state.detection_history.$slotKey = $nextSlot
        } else {
            $state.detection_history | Add-Member -NotePropertyName $slotKey -NotePropertyValue $nextSlot -Force
        }

        return "/local/$filename"
    } catch {
        Write-Log "Failed to save snapshot for ${CameraName}: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# ============================================================
# Camera definitions with schedules
# ============================================================

# Schedule = default interval (string key into $scheduleIntervals, or $null for motion-only)
# TimeOverrides = array of @{ From; To; Schedule } — time-of-day overrides (checked in order, first match wins)
# MotionSensor = HA entity_id for motion detection ($null = no motion trigger)

$cameras = @(
    @{
        Name         = "Chickens"
        EntityId     = "camera.chickens_sd_stream"
        Type         = "chickens"
        Schedule     = "1hr"
        TimeOverrides = @(
            @{ From = "07:30"; To = "07:35"; Schedule = "60s" }
            @{ From = "07:35"; To = "19:55"; Schedule = $null }   # motion-only during day
            @{ From = "19:55"; To = "20:00"; Schedule = "60s" }
        )
        MotionSensor = "binary_sensor.chickens_motion_alarm"
        MotionHours  = @{ From = "07:35"; To = "19:55" }   # motion only active during these hours
    }
    @{
        Name         = "Backyard"
        EntityId     = "camera.backyard_camera_sd_stream"
        Type         = "security"
        Schedule     = $null   # motion-only
        TimeOverrides = @()
        MotionSensor = "binary_sensor.backyard_camera_motion_alarm"
        MotionHours  = $null   # 24/7
    }
    @{
        Name         = "BackDoor"
        EntityId     = "camera.back_door_camera_sd_stream"
        Type         = "security"
        Schedule     = $null   # motion-only
        TimeOverrides = @()
        MotionSensor = "binary_sensor.back_door_camera_motion_alarm"
        MotionHours  = $null   # 24/7
    }
    @{
        Name         = "VeggieGarden"
        EntityId     = "camera.veggie_garden_sd_stream"
        Type         = "security"
        Schedule     = $null   # motion-only
        TimeOverrides = @()
        MotionSensor = "binary_sensor.veggie_garden_motion_alarm"
        MotionHours  = $null   # 24/7
    }
    @{
        Name         = "DiningRoom"
        EntityId     = "camera.dining_room_camera_sd_stream"
        Type         = "indoor"
        Schedule     = $null   # motion-only
        TimeOverrides = @()
        MotionSensor = "binary_sensor.dining_room_camera_motion_alarm"
        MotionHours  = $null   # 24/7
    }
    @{
        Name         = "Kitchen"
        EntityId     = "camera.kitchen_camera_sd_stream"
        Type         = "kitchen"
        Schedule     = $null   # motion-only (was 30min)
        TimeOverrides = @()
        MotionSensor = "binary_sensor.kitchen_camera_motion_alarm"
        MotionHours  = $null   # 24/7
    }
    @{
        Name         = "MainGate"
        EntityId     = "camera.main_gate_camera"
        Type         = "gate"
        Schedule     = "10min"
        TimeOverrides = @(
            @{ From = "20:00"; To = "06:00"; Schedule = "30min" }
        )
        MotionSensor = $null   # RTSP - no motion sensor
        MotionHours  = $null
    }
    @{
        Name         = "VisitorGate"
        EntityId     = "camera.visitor_gate_camera"
        Type         = "gate"
        Schedule     = "10min"
        TimeOverrides = @(
            @{ From = "20:00"; To = "06:00"; Schedule = "30min" }
        )
        MotionSensor = $null   # RTSP - no motion sensor
        MotionHours  = $null
    }
    @{
        Name         = "Lawn"
        EntityId     = "camera.lawn_camera_sd_stream"
        Type         = "security"
        Schedule     = $null   # motion-only during day
        TimeOverrides = @()
        MotionSensor = "binary_sensor.lawn_camera_motion_alarm"
        MotionHours  = $null   # 24/7
    }
    @{
        Name         = "Pool"
        EntityId     = "camera.pool_camera"
        Type         = "pool"
        Schedule     = "1hr"    # RTSP - scheduled only (no ONVIF motion available)
        TimeOverrides = @(
            @{ From = "06:00"; To = "14:00"; Schedule = "30min" }   # morning: every 30 min (was 5min)
            @{ From = "14:00"; To = "19:00"; Schedule = "5min" }    # afternoon swim time: every 5 min
            @{ From = "19:00"; To = "06:00"; Schedule = "1hr" }     # night: hourly
        )
        MotionSensor = $null
        MotionHours  = $null
    }
    @{
        Name         = "Garage"
        EntityId     = "camera.garage_camera"
        Type         = "garage"
        Schedule     = "15min"   # RTSP - scheduled only
        TimeOverrides = @(
            @{ From = "20:00"; To = "06:00"; Schedule = "10min" }  # night: more frequent
        )
        MotionSensor = $null
        MotionHours  = $null
    }
    @{
        Name         = "Lounge"
        EntityId     = "camera.lounge_camera"
        Type         = "indoor"
        Schedule     = "30min"   # RTSP - scheduled only (no ONVIF motion available)
        TimeOverrides = @()
        MotionSensor = $null
        MotionHours  = $null
    }
)
# Note: Street camera excluded from analysis entirely

# ============================================================
# Scheduling functions
# ============================================================

function Test-TimeInRange {
    param([DateTime]$Now, [string]$From, [string]$To)
    $fromParts = $From.Split(":")
    $toParts   = $To.Split(":")
    $fromMinutes = [int]$fromParts[0] * 60 + [int]$fromParts[1]
    $toMinutes   = [int]$toParts[0] * 60 + [int]$toParts[1]
    $nowMinutes  = $Now.Hour * 60 + $Now.Minute

    if ($fromMinutes -lt $toMinutes) {
        # Same day range (e.g., 07:30 to 19:55)
        return ($nowMinutes -ge $fromMinutes -and $nowMinutes -lt $toMinutes)
    } else {
        # Overnight range (e.g., 20:00 to 06:00)
        return ($nowMinutes -ge $fromMinutes -or $nowMinutes -lt $toMinutes)
    }
}

function Get-EffectiveSchedule {
    param([hashtable]$Camera, [DateTime]$Now)

    # Check time-of-day overrides first (first match wins)
    foreach ($override in $Camera.TimeOverrides) {
        if (Test-TimeInRange -Now $Now -From $override.From -To $override.To) {
            return $override.Schedule   # may be $null for motion-only
        }
    }

    return $Camera.Schedule   # default (may be $null for motion-only)
}

function Get-MotionBurstInterval {
    param([DateTime]$MotionStarted, [DateTime]$Now)

    $elapsed = ($Now - $MotionStarted).TotalSeconds

    if ($elapsed -lt 30) {
        return 10    # Rapid phase: every 10s for first 30s
    } elseif ($elapsed -lt 150) {
        return 60    # Medium phase: every 60s for next 2 minutes (30s-150s)
    } else {
        return 120   # Slow phase: every 120s until motion stops
    }
}

function Test-MotionActive {
    param([hashtable]$Camera, [DateTime]$Now)

    if (-not $Camera.MotionSensor) { return $false }

    # Check if motion is restricted to certain hours
    if ($Camera.MotionHours) {
        if (-not (Test-TimeInRange -Now $Now -From $Camera.MotionHours.From -To $Camera.MotionHours.To)) {
            return $false
        }
    }

    # Check motion sensor state (from batch-fetched states)
    $sensorState = $script:motionStates[$Camera.MotionSensor]
    return ($sensorState -eq "on")
}

function Get-CameraScheduleState {
    param([string]$CameraName)

    $camState = $state.camera_schedules.PSObject.Properties[$CameraName]
    if ($camState) {
        $cs = $camState.Value
        # Ensure all fields exist
        if (-not $cs.PSObject.Properties["last_analyzed"]) { $cs | Add-Member -NotePropertyName "last_analyzed" -NotePropertyValue $null -Force }
        if (-not $cs.PSObject.Properties["motion_started"]) { $cs | Add-Member -NotePropertyName "motion_started" -NotePropertyValue $null -Force }
        if (-not $cs.PSObject.Properties["daily_count"]) { $cs | Add-Member -NotePropertyName "daily_count" -NotePropertyValue 0 -Force }
        if (-not $cs.PSObject.Properties["daily_date"]) { $cs | Add-Member -NotePropertyName "daily_date" -NotePropertyValue $today -Force }
        if (-not $cs.PSObject.Properties["daily_history"]) { $cs | Add-Member -NotePropertyName "daily_history" -NotePropertyValue @() -Force }
        if (-not $cs.PSObject.Properties["motion_trigger_times"]) { $cs | Add-Member -NotePropertyName "motion_trigger_times" -NotePropertyValue @() -Force }
        if (-not $cs.PSObject.Properties["heavy_activity_until"]) { $cs | Add-Member -NotePropertyName "heavy_activity_until" -NotePropertyValue $null -Force }
        if (-not $cs.PSObject.Properties["motion_events"]) { $cs | Add-Member -NotePropertyName "motion_events" -NotePropertyValue @() -Force }
        # Reset daily count if new day
        if ($cs.daily_date -ne $today) {
            # Save yesterday's count to history before resetting
            $historyEntry = @{ date = $cs.daily_date; count = $cs.daily_count }
            $history = @($cs.daily_history)
            $history += $historyEntry
            # Keep last 30 days only
            if ($history.Count -gt 30) { $history = $history[-30..-1] }
            $cs.daily_history = $history
            $cs.daily_count = 0
            $cs.daily_date = $today
        }
        return $cs
    }

    # Initialize new camera state
    $newState = [PSCustomObject]@{
        last_analyzed = $null
        motion_started = $null
        daily_count = 0
        daily_date = $today
        daily_history = @()
        motion_trigger_times = @()
        heavy_activity_until = $null
        motion_events = @()
    }
    $state.camera_schedules | Add-Member -NotePropertyName $CameraName -NotePropertyValue $newState -Force
    return $newState
}

function Add-MotionEvent {
    param([PSObject]$CamState, [string]$CameraName, [DateTime]$Now, [string]$Event)
    if (-not $CamState.PSObject.Properties["motion_events"]) {
        $CamState | Add-Member -NotePropertyName "motion_events" -NotePropertyValue @() -Force
    }
    $entry = [PSCustomObject]@{ time = $Now.ToString("o"); camera = $CameraName; event = $Event }
    $events = @($CamState.motion_events) + @($entry)
    # Prune older than 24 hours and cap at 50
    $cutoff = $Now.AddHours(-24).ToString("o")
    $events = @($events | Where-Object { $_.time -ge $cutoff }) | Select-Object -Last 50
    $CamState.motion_events = $events
}

function Test-CameraDue {
    param([hashtable]$Camera, [DateTime]$Now)

    $camState = Get-CameraScheduleState -CameraName $Camera.Name
    $lastAnalyzed = $null
    if ($camState.last_analyzed) {
        try { $lastAnalyzed = [DateTime]::Parse($camState.last_analyzed) } catch { $lastAnalyzed = $null }
    }
    $elapsed = if ($lastAnalyzed) { ($Now - $lastAnalyzed).TotalSeconds } else { [double]::MaxValue }

    # Check motion burst mode
    $isMotionActive = Test-MotionActive -Camera $Camera -Now $Now

    if ($isMotionActive) {
        # Motion is currently active — check heavy activity suppression first
        $heavyUntil = $null
        if ($camState.heavy_activity_until) {
            try { $heavyUntil = [DateTime]::Parse($camState.heavy_activity_until) } catch { $heavyUntil = $null }
        }
        if ($heavyUntil -and $Now -lt $heavyUntil) {
            # Still in heavy activity suppression period
            Write-Log "$($Camera.Name): Heavy activity suppressed (until $($heavyUntil.ToString('HH:mm:ss')))"
            return $false
        }
        if ($heavyUntil -and $Now -ge $heavyUntil) {
            # Suppression expired — clear it
            Write-Log "$($Camera.Name): Heavy activity cleared"
            Add-MotionEvent -CamState $camState -CameraName $Camera.Name -Now $Now -Event "Heavy cleared"
            $camState.heavy_activity_until = $null
            $camState.motion_trigger_times = @()
        }

        $motionStarted = $null
        if ($camState.motion_started) {
            try { $motionStarted = [DateTime]::Parse($camState.motion_started) } catch { $motionStarted = $null }
        }
        if (-not $motionStarted) {
            # New motion event — start burst, analyze immediately
            $camState.motion_started = $Now.ToString("o")
            Write-Log "$($Camera.Name): Motion detected, starting burst mode (immediate first frame)"
            Add-MotionEvent -CamState $camState -CameraName $Camera.Name -Now $Now -Event "Burst started"
        }

        # Record this motion trigger timestamp and prune old entries
        $triggerTimes = @($camState.motion_trigger_times | Where-Object {
            try { ([DateTime]::Parse($_)) -gt $Now.AddMinutes(-5) } catch { $false }
        })
        $triggerTimes += $Now.ToString("o")
        $camState.motion_trigger_times = $triggerTimes

        # Check for heavy activity (>5 triggers in 5 minutes)
        if ($triggerTimes.Count -gt 5) {
            $camState.heavy_activity_until = $Now.AddMinutes(30).ToString("o")
            $camState.motion_started = $null  # Reset burst so it restarts cleanly after suppression
            Write-Log "$($Camera.Name): Heavy activity detected ($($triggerTimes.Count) triggers in 5 min), suppressing for 30 min" "WARN"
            Add-MotionEvent -CamState $camState -CameraName $Camera.Name -Now $Now -Event "Heavy activity ($($triggerTimes.Count) triggers)"
            return $false
        }

        # Re-read motionStarted (may have just been set above)
        if (-not $motionStarted) {
            # Was just set — first frame is immediate
            return $true
        }
        $burstInterval = Get-MotionBurstInterval -MotionStarted $motionStarted -Now $Now
        if ($elapsed -ge $burstInterval) {
            $burstDuration = [math]::Round(($Now - $motionStarted).TotalSeconds)
            Write-Log "$($Camera.Name): Due (motion burst, interval=${burstInterval}s, elapsed=$([math]::Min([math]::Round($elapsed), 999999))s)"
            Add-MotionEvent -CamState $camState -CameraName $Camera.Name -Now $Now -Event "Burst (${burstDuration}s, ${burstInterval}s interval)"
            return $true
        }
        # In burst but not yet due
        return $false
    } else {
        # Motion not active — clear burst state if it was set
        if ($camState.motion_started) {
            Write-Log "$($Camera.Name): Motion ended, exiting burst mode"
            Add-MotionEvent -CamState $camState -CameraName $Camera.Name -Now $Now -Event "Motion ended"
            $camState.motion_started = $null
        }
    }

    # Time-based schedule check
    $schedule = Get-EffectiveSchedule -Camera $Camera -Now $Now

    if ($null -eq $schedule) {
        # motion-only camera with no active motion — not due
        return $false
    }

    $interval = $scheduleIntervals[$schedule]
    if (-not $interval) {
        Write-Log "$($Camera.Name): Unknown schedule '$schedule', skipping" "WARN"
        return $false
    }

    if ($elapsed -ge $interval) {
        Write-Log "$($Camera.Name): Due (schedule=$schedule, interval=${interval}s, elapsed=$([math]::Min([math]::Round($elapsed), 999999))s)"
        return $true
    }

    return $false
}

# ============================================================
# Internal polling loop: 6 iterations x 10 seconds = 60 seconds
# Achieves effective 10-second polling while Task Scheduler runs every 1 minute
# ============================================================

$tickCount = 6
$tickInterval = 10  # seconds
$script:motionSensorCheckDone = $false

for ($tick = 0; $tick -lt $tickCount; $tick++) {
    # Sleep before ticks 1-5 (not before the first tick)
    if ($tick -gt 0) { Start-Sleep -Seconds $tickInterval }

    # Recalculate time context each tick
    $now = Get-Date
    $hour = $now.Hour
    $today = $now.ToString("yyyy-MM-dd")

    $isNightSecurity = ($hour -ge 20) -or ($hour -lt 6)    # 8PM - 6AM
    $isAfterMidnight = ($hour -ge 0) -and ($hour -lt 6)    # 12AM - 6AM

    # Meal windows
    $mealWindow = "none"
    if ($hour -ge 6 -and $hour -lt 10)  { $mealWindow = "breakfast" }
    if ($hour -ge 11 -and $hour -lt 14) { $mealWindow = "lunch" }
    if ($hour -ge 17 -and $hour -lt 21) { $mealWindow = "dinner" }

# ============================================================
# Fetch motion sensor states from HA (single batch call)
# ============================================================

$script:motionStates = @{}

$motionSensorIds = $cameras | Where-Object { $_.MotionSensor } | ForEach-Object { $_.MotionSensor }

if ($motionSensorIds.Count -gt 0) {
    $haHeaders = @{
        "Authorization" = "Bearer $haToken"
        "Content-Type"  = "application/json"
    }
    try {
        $allStates = Invoke-RestMethod -Uri "$haBase/api/states" -Headers $haHeaders -TimeoutSec 10
        foreach ($sensorId in $motionSensorIds) {
            $matched = $allStates | Where-Object { $_.entity_id -eq $sensorId }
            if ($matched) {
                $script:motionStates[$sensorId] = $matched.state
            }
        }
    } catch {
        Write-Log "Failed to fetch motion sensor states: $($_.Exception.Message)" "WARN"
    }
}

# One-time motion sensor diagnostic (first tick only)
if (-not $script:motionSensorCheckDone -and $motionSensorIds.Count -gt 0) {
    $foundSensors = @()
    $missingSensors = @()
    foreach ($sId in $motionSensorIds) {
        if ($script:motionStates.ContainsKey($sId)) {
            $foundSensors += "$sId=$($script:motionStates[$sId])"
        } else {
            $missingSensors += $sId
        }
    }
    if ($foundSensors.Count -gt 0) {
        Write-Log "Motion sensors found ($($foundSensors.Count)): $($foundSensors -join ', ')"
    }
    if ($missingSensors.Count -gt 0) {
        Write-Log "Motion sensors MISSING ($($missingSensors.Count)): $($missingSensors -join ', ') -- check entity IDs in HA Developer Tools > States" "WARN"
    }
    $script:motionSensorCheckDone = $true
}

# ============================================================
# Determine which cameras are due this run
# ============================================================

$dueCameras = @()
foreach ($cam in $cameras) {
    if (Test-CameraDue -Camera $cam -Now $now) {
        $dueCameras += $cam
    }
}

if ($dueCameras.Count -eq 0) {
    # Nothing to do this tick — save state and continue to next tick
    $state | Add-Member -NotePropertyName "last_run" -NotePropertyValue $now.ToString("o") -Force
    $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
    continue
}

Write-Log "=== Vision analysis run starting: $($dueCameras.Count)/$($cameras.Count) cameras due (night=$isNightSecurity, meal=$mealWindow) ==="

# ============================================================
# Build prompts per camera type
# ============================================================

function Get-CameraPrompt {
    param([hashtable]$Camera)

    $nightNote = "This image may be night-vision (grayscale/infrared). Analyze accordingly."

    switch ($Camera.Name) {
        "Chickens" {
            return @"
This is an indoor camera inside a small chicken nesting box. The camera looks down at chickens sleeping on straw/hay bedding. Count every individual chicken you can see, including partially hidden ones. Chickens may be dark-feathered or light-feathered and may overlap. Also look for any eggs visible in the straw/bedding. Eggs are oval, white or light brown, and may be partially hidden under chickens or straw.
$nightNote
Respond with ONLY this JSON:
{"chicken_count": <integer>, "chickens_visible": <true/false>, "egg_count": <integer>, "eggs_visible": <true/false>, "description": "<brief description>"}
"@
        }
        "Backyard" {
            return @"
This is an outdoor security camera overlooking a backyard area. The scene normally contains water storage tanks on the right, a clothesline in the center, potted plants, and a boundary fence/wall in the background. Look carefully for any HUMAN figures - a person standing, walking, crouching, or moving anywhere in the frame. Do NOT confuse objects like plants, clothesline poles, trash bins, or shadows for humans. Only report human_detected=true if you can clearly identify a human body shape (head, torso, limbs).
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "BackDoor" {
            return @"
This is an outdoor security camera watching a narrow passage/alley between buildings near a back door. The scene normally shows a textured wall on the right with a wooden door, cleaning tools (mops/brooms) leaning against the wall, and potted plants on the left along a pathway. Look carefully for any HUMAN figures anywhere in the passage. Do NOT confuse mops, brooms, plant shapes, or shadows for humans. Only report human_detected=true if you can clearly see a human body.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "VeggieGarden" {
            return @"
This is an outdoor security camera overlooking a vegetable garden area. The scene contains a large wire mesh cage/enclosure on the left (this is a chicken run - it may contain chickens, garden equipment, or shade cloth, NOT humans), raised garden beds, plants, and a boundary fence on the right. Look for HUMAN figures OUTSIDE the wire cage - a person standing, walking, or crouching in the open garden area. IMPORTANT: Shapes visible inside the wire mesh cage are NOT humans - they are chickens, objects, or shade cloth. Only report human_detected=true if you clearly see a human body shape in the open areas of the garden.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "DiningRoom" {
            return @"
This is an indoor camera in a combined dining/living room. The scene typically shows a dining table, chairs, a TV/screen on one wall, a sofa, and kitchen cabinets in the background. Look for any HUMAN figures - someone sitting at the table, on the sofa, standing, or walking through.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Kitchen" {
            $base = @"
This is an indoor camera in a kitchen, mounted high looking down at the room. The scene shows a kitchen counter/island in the center, wooden cabinets, a sink area, a stove, and a dining table with chairs in the lower portion of the frame. Look carefully for any HUMAN figures - someone sitting at the table, standing at the counter, or anywhere in the room. People may be partially occluded by furniture.
$nightNote
"@
            if ($script:mealWindow -ne "none") {
                $base += @"

Also look at the counter and dining table for PREPARED FOOD (plates of food, bowls, sandwiches, cooked meals). Do not count raw ingredients, empty plates, or cooking equipment as food. If prepared food is visible, describe each distinct food item concisely in 2-5 words (e.g. 'toast and eggs', 'chicken stir fry', 'cereal with milk'). Be consistent - use the same description for the same food across different images.
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "food_visible": <true/false>, "food_description": "<brief 2-5 word food description or empty string>", "description": "<brief description>"}
"@
            } else {
                $base += @"

Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
            }
            return $base
        }
        "MainGate" {
            return @"
This is a security camera INSIDE a residential property, mounted high, looking OUT toward the main gate and the road outside.

Directly in front of the camera is a clear PARKING SPACE on the property driveway. There may or may not be vehicles parked here. The parking area should be obvious.

In the MIDDLE of the frame is the ENTRANCE to the parking area / driveway exit. This is where the sliding palisade gate is located. Beyond the gate is the road outside.

TO DETERMINE GATE STATUS:
- If the middle of the frame shows an OPENING to the road outside (you can see through to the street, pavement, or open space with no palisade bars blocking the way), the gate is OPEN.
- If the middle of the frame is BLOCKED by continuous vertical palisade bars (metal fence bars running across the entrance with no gap), the gate is CLOSED.

Count all cars parked on the driveway/parking space INSIDE the property (between the camera and the gate). Do NOT count cars on the other side of the palisade fence.
$nightNote
Respond with ONLY this JSON:
{"gate_status": "<open/closed>", "car_count": <integer>, "description": "<describe what you see in the middle of the frame where the entrance is - is it open or blocked by bars?>"}
"@
        }
        "VisitorGate" {
            return @"
This is a security camera INSIDE a residential property, looking at the visitor gate area.

Directly in front of the camera is a clear brick-paved PARKING SPACE. There may or may not be vehicles parked here. The parking area should be obvious.

The ENTRANCE to the parking area is in the MIDDLE of the frame, on the left side where the sliding palisade gate is located. Beyond the gate is the road outside.

TO DETERMINE GATE STATUS:
- If the entrance in the middle/left of the frame shows an OPENING to the road outside (you can see through with no palisade bars blocking), the gate is OPEN.
- If the entrance is BLOCKED by continuous vertical palisade bars (metal fence bars running across with no gap), the gate is CLOSED.

Count all cars parked on the brick driveway/parking space INSIDE the property. Do NOT count cars on the other side of the palisade fence.
$nightNote
Respond with ONLY this JSON:
{"gate_status": "<open/closed>", "car_count": <integer>, "description": "<brief description>"}
"@
        }
        "Lawn" {
            return @"
This is an outdoor security camera overlooking a lawn/garden area at a residential property. The scene normally shows grass, garden beds, fencing, and possibly outdoor furniture or play equipment. Look carefully for any HUMAN figures - a person standing, walking, crouching, or moving anywhere in the frame. Do NOT confuse garden furniture, plant shapes, statues, or shadows for humans. Only report human_detected=true if you can clearly identify a human body shape.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Pool" {
            return @"
This is an outdoor security camera overlooking a swimming pool area at a residential property. The scene normally shows a pool, pool deck, outdoor furniture, and surrounding fencing or walls.

1. Count ADULTS (teenagers and older) separately from CHILDREN (younger than ~12) both IN the pool and AROUND the pool area. Include anyone swimming, sitting, standing, or walking.
2. Check for anyone IN the water (person_in_pool).
3. Detect the POOL COVER status: "open" (water fully visible), "closed" (cover fully over pool), or "partial" (partially covered).
4. Look for any HUMAN figures for security purposes. Do NOT confuse pool equipment, reflections on water, or furniture for humans.
$nightNote
Respond with ONLY this JSON:
{"adult_count": <integer>, "child_count": <integer>, "person_in_pool": <true/false>, "pool_cover": "<open/closed/partial>", "human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Garage" {
            return @"
This is a security camera overlooking a double garage area. The scene shows two garage door openings side by side - a LEFT door and a RIGHT door. There may be vehicles, tools, and storage items inside.

1. Look carefully for any HUMAN figures - a person standing, walking, crouching, or moving anywhere in the frame. Do NOT confuse storage items, tools, or vehicle shapes for humans.
2. Determine the LEFT garage door status: "open" if the opening is clear/you can see outside or the door is raised, "closed" if the door panel is down blocking the opening.
3. Determine the RIGHT garage door status: same criteria as left.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "left_garage_door": "<open/closed>", "right_garage_door": "<open/closed>", "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Lounge" {
            return @"
This is an indoor camera in a lounge/living room area. The scene typically shows a sofa, TV, coffee table, and other living room furniture. Look for any HUMAN figures - someone sitting on the sofa, standing, or walking through.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
    }
}

# ============================================================
# Parallel execution: capture snapshot + call Gemini per camera
# ============================================================

Write-Log "Processing $($dueCameras.Count) cameras: $($dueCameras.Name -join ', ')"

# Script block that runs in each runspace
$workerScript = {
    param(
        [string]$CameraName,
        [string]$CameraEntityId,
        [string]$Prompt,
        [string]$HaBase,
        [string]$HaToken,
        [string]$GeminiKey,
        [string]$GeminiModel
    )

    $result = @{
        Camera     = $CameraName
        Success    = $false
        Data       = $null
        Error      = $null
        ImageBytes = $null
    }

    try {
        # 1. Capture snapshot
        $snapshotUri = "$HaBase/api/camera_proxy/$CameraEntityId"
        $snapshotHeaders = @{ "Authorization" = "Bearer $HaToken" }

        try {
            $snapshotResp = Invoke-WebRequest -Uri $snapshotUri -Headers $snapshotHeaders -UseBasicParsing -TimeoutSec 15
        } catch {
            $result.Error = "Snapshot failed ($snapshotUri): $($_.Exception.Message)"
            return $result
        }

        $imageBytes = $snapshotResp.Content
        $result.ImageBytes = $imageBytes
        $base64Image = [Convert]::ToBase64String($imageBytes)

        # 2. Call Gemini API
        $geminiUri = "https://generativelanguage.googleapis.com/v1beta/models/${GeminiModel}:generateContent?key=$GeminiKey"

        $geminiBody = @{
            contents = @(@{
                parts = @(
                    @{ inline_data = @{ mime_type = "image/jpeg"; data = $base64Image } }
                    @{ text = $Prompt }
                )
            })
            generationConfig = @{
                responseMimeType = "application/json"
                temperature      = 0.1
            }
        } | ConvertTo-Json -Depth 10

        try {
            $geminiResp = Invoke-RestMethod -Uri $geminiUri -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($geminiBody)) -ContentType "application/json; charset=utf-8" -TimeoutSec 30
        } catch {
            $errBody = ""
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errBody = $reader.ReadToEnd()
                } catch {}
            }
            $result.Error = "Gemini failed (model=$GeminiModel): $($_.Exception.Message) $errBody"
            return $result
        }

        # 3. Extract JSON from response
        $responseText = $geminiResp.candidates[0].content.parts[0].text

        # Parse JSON response
        $parsed = $responseText | ConvertFrom-Json
        $result.Data = $parsed
        $result.Success = $true
    } catch {
        $result.Error = "Processing failed: $($_.Exception.Message)"
    }

    return $result
}

# Create runspace pool (max 8 threads, or camera count if fewer)
$poolSize = [Math]::Min(8, $dueCameras.Count)
$pool = [RunspaceFactory]::CreateRunspacePool(1, $poolSize)
$pool.Open()

$jobs = @()

foreach ($cam in $dueCameras) {
    $prompt = Get-CameraPrompt -Camera $cam

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    $null = $ps.AddScript($workerScript).AddParameters(@{
        CameraName     = $cam.Name
        CameraEntityId = $cam.EntityId
        Prompt         = $prompt
        HaBase         = $haBase
        HaToken        = $haToken
        GeminiKey      = $geminiKey
        GeminiModel    = $geminiModel
    })

    $jobs += @{
        PowerShell = $ps
        Handle     = $ps.BeginInvoke()
        Camera     = $cam
    }
}

# Wait for all jobs to complete (max 45 seconds total)
$deadline = (Get-Date).AddSeconds(45)
foreach ($job in $jobs) {
    $remaining = ($deadline - (Get-Date)).TotalMilliseconds
    if ($remaining -gt 0) {
        $null = $job.Handle.AsyncWaitHandle.WaitOne([int]$remaining)
    }
}

# Collect results
$results = @()
foreach ($job in $jobs) {
    try {
        if ($job.Handle.IsCompleted) {
            $r = $job.PowerShell.EndInvoke($job.Handle)
            if ($r) { $results += $r }
        } else {
            Write-Log "$($job.Camera.Name): Timed out" "WARN"
        }
    } catch {
        Write-Log "$($job.Camera.Name): EndInvoke error: $($_.Exception.Message)" "ERROR"
    } finally {
        $job.PowerShell.Dispose()
    }
}

$pool.Close()
$pool.Dispose()

# ============================================================
# Process results
# ============================================================

$haHeaders = @{
    "Authorization" = "Bearer $haToken"
    "Content-Type"  = "application/json"
}

function Update-HaSensor {
    param([string]$EntityId, [string]$State, [hashtable]$Attributes = @{})
    $body = @{ state = $State; attributes = $Attributes } | ConvertTo-Json -Depth 5
    try {
        $null = Invoke-WebRequest -Uri "$haBase/api/states/$EntityId" -Method POST -Headers $haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 10
    } catch {
        Write-Log "Failed to update $EntityId : $($_.Exception.Message)" "ERROR"
    }
}

function Send-TTS {
    param([string]$Message)
    $body = @{
        entity_id              = $ttsEngine
        media_player_entity_id = $kitchenSpeaker
        message                = $Message
    } | ConvertTo-Json -Depth 5
    try {
        $null = Invoke-WebRequest -Uri "$haBase/api/services/tts/speak" -Method POST -Headers $haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 15
        Write-Log "TTS sent: $Message"
    } catch {
        Write-Log "TTS failed: $($_.Exception.Message)" "ERROR"
    }
}

function Send-PhoneAlert {
    param([string]$Message, [string]$Title = "Vision AI Alert", [string]$ImageUrl = $null)
    if (-not $notifyEntity) { return }
    $body = @{
        message = $Message
        title   = $Title
    }
    if ($ImageUrl) {
        $body.data = @{ image = $ImageUrl }
    }
    $jsonBody = $body | ConvertTo-Json -Depth 5
    try {
        $svcName = $notifyEntity -replace "notify\.", ""
        $null = Invoke-WebRequest -Uri "$haBase/api/services/notify/$svcName" -Method POST -Headers $haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonBody)) -UseBasicParsing -TimeoutSec 15
        Write-Log "Phone alert sent: $Message"
    } catch {
        Write-Log "Phone alert failed: $($_.Exception.Message)" "ERROR"
    }
}

function Send-Alert {
    param([string]$AlertKey, [string]$Message, [string]$ImageUrl = $null)
    $cfg = $alertConfig[$AlertKey]
    if ($cfg.TTS) { Send-TTS $Message }
    if ($cfg.Phone) { Send-PhoneAlert -Message $Message -ImageUrl $ImageUrl }
}

foreach ($r in $results) {
    if (-not $r.Success) {
        Write-Log "$($r.Camera): FAILED - $($r.Error)" "ERROR"
        continue
    }

    $cam = $r.Camera
    $data = $r.Data
    Write-Log "${cam}: $($data | ConvertTo-Json -Compress)"

    # Update last_analyzed and daily count
    $camState = Get-CameraScheduleState -CameraName $cam
    $camState.last_analyzed = $now.ToString("o")
    $camState.daily_count = [int]$camState.daily_count + 1

    # Record detection history (only when something is actually detected)
    $imageUrl = $null
    $camConfig = $cameras | Where-Object { $_.Name -eq $cam } | Select-Object -First 1
    if ($camConfig -and (Test-IsDetection -CameraType $camConfig.Type -Data $data)) {
        $imageUrl = Save-DetectionSnapshot -CameraName $cam -ImageBytes $r.ImageBytes -Timestamp $now.ToString("o")
        $summary = Get-DetectionSummary -CameraType $camConfig.Type -Data $data
        # Truncate summary to avoid bloating state
        if ($summary.Length -gt 200) { $summary = $summary.Substring(0, 200) }

        $entry = [PSCustomObject]@{
            timestamp = $now.ToString("o")
            summary   = $summary
            image_url = $imageUrl
        }

        # Ensure per-camera history array exists
        $histKey = "${cam}_history"
        if (-not $state.detection_history.PSObject.Properties[$histKey]) {
            $state.detection_history | Add-Member -NotePropertyName $histKey -NotePropertyValue @() -Force
        }
        # Append and keep max 5
        $histArray = @($state.detection_history.$histKey) + @($entry)
        if ($histArray.Count -gt 5) { $histArray = $histArray | Select-Object -Last 5 }
        $state.detection_history.$histKey = $histArray
    }

    switch -Wildcard ($cam) {
        "Chickens" {
            $count = if ($data.chicken_count -ne $null) { [string]$data.chicken_count } else { "unknown" }
            Update-HaSensor -EntityId "sensor.chicken_count" -State $count -Attributes @{
                friendly_name       = "Chicken Count"
                icon                = "mdi:chicken"
                unit_of_measurement = "chickens"
                description         = [string]$data.description
                last_updated        = $now.ToString("o")
            }
            $eggCount = if ($data.egg_count -ne $null) { [string]$data.egg_count } else { "0" }
            Update-HaSensor -EntityId "sensor.egg_count" -State $eggCount -Attributes @{
                friendly_name       = "Egg Count"
                icon                = "mdi:egg"
                unit_of_measurement = "eggs"
                description         = [string]$data.description
                last_updated        = $now.ToString("o")
            }
        }

        "Backyard" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Backyard_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the backyard." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "BackDoor" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "BackDoor_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected at the back door." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "VeggieGarden" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "VeggieGarden_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the veggie garden." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "DiningRoom" {
            # Indoor security alert (12AM-6AM only)
            if ($isAfterMidnight -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "DiningRoom_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the dining room." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Kitchen" {
            # Indoor security alert (12AM-6AM only)
            if ($isAfterMidnight -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Kitchen_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the kitchen." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }

            # Food detection during meal windows (accumulates unique items with timestamps)
            if ($mealWindow -ne "none" -and $data.food_visible -eq $true -and $data.food_description) {
                $foodKey = $mealWindow
                $mealState = $state.food_items.$foodKey

                # Reset if new day
                if ($mealState.date -ne $today) {
                    $mealState.date = $today
                    $mealState.items = @()
                    $mealState.timestamps = @()
                }

                # Ensure items/timestamps are arrays (ConvertFrom-Json may deserialize single-element as string)
                if ($mealState.items -is [string]) { $mealState.items = @($mealState.items) }
                if ($mealState.timestamps -is [string]) { $mealState.timestamps = @($mealState.timestamps) }

                $newFood = ([string]$data.food_description).Trim().ToLower()

                if ($newFood -and $newFood -ne "none" -and $newFood -ne "n/a") {
                    # Fuzzy dedup: check substring matches against existing items
                    $isDuplicate = $false
                    $replaceIndex = -1
                    for ($i = 0; $i -lt $mealState.items.Count; $i++) {
                        $existing = $mealState.items[$i]
                        if ($existing -eq $newFood) {
                            $isDuplicate = $true; break
                        }
                        # Substring match: new contains existing or existing contains new
                        if ($newFood.Contains($existing) -and $newFood.Length -gt $existing.Length) {
                            # New is more detailed - replace the shorter one
                            $replaceIndex = $i; break
                        }
                        if ($existing.Contains($newFood)) {
                            # Existing is already more detailed - skip
                            $isDuplicate = $true; break
                        }
                    }

                    $changed = $false
                    if ($replaceIndex -ge 0) {
                        # Replace shorter description with longer one, keep same timestamp
                        Write-Log "Replacing food '$($mealState.items[$replaceIndex])' with more detailed '$newFood'"
                        $mealState.items[$replaceIndex] = $newFood
                        $changed = $true
                    } elseif (-not $isDuplicate) {
                        # Add new unique item
                        $mealState.items = @($mealState.items) + @($newFood)
                        $mealState.timestamps = @($mealState.timestamps) + @($now.ToString("HH:mm"))
                        $changed = $true
                        Write-Log "Added new food item '$newFood' to $mealWindow"
                    }

                    if ($changed) {
                        # Build display string: "item1 (HH:mm), item2 (HH:mm)"
                        $parts = @()
                        for ($i = 0; $i -lt $mealState.items.Count; $i++) {
                            $ts = if ($i -lt $mealState.timestamps.Count) { $mealState.timestamps[$i] } else { $now.ToString("HH:mm") }
                            $parts += "$($mealState.items[$i]) ($ts)"
                        }
                        $displayState = $parts -join ", "

                        $sensorId = "sensor.${mealWindow}_food"
                        Update-HaSensor -EntityId $sensorId -State $displayState -Attributes @{
                            friendly_name = "$($mealWindow.Substring(0,1).ToUpper())$($mealWindow.Substring(1)) Food"
                            icon          = switch ($mealWindow) { "breakfast" { "mdi:food-croissant" } "lunch" { "mdi:food" } "dinner" { "mdi:food-turkey" } }
                            items_count   = $mealState.items.Count
                            items_list    = $mealState.items
                            last_updated  = $now.ToString("o")
                        }
                        Write-Log "Updated $sensorId : $displayState"
                    } else {
                        Write-Log "Food '$newFood' already tracked for $mealWindow, skipping"
                    }
                }
            }
        }

        "MainGate" {
            $gateStatus = if ($data.gate_status) { [string]$data.gate_status } else { "unknown" }
            $carCount = if ($data.car_count -ne $null) { [string]$data.car_count } else { "0" }

            Update-HaSensor -EntityId "sensor.main_gate_status" -State $gateStatus -Attributes @{
                friendly_name = "Main Gate Status"
                icon          = "mdi:gate"
                description   = [string]$data.description
                last_updated  = $now.ToString("o")
            }
            Update-HaSensor -EntityId "sensor.main_gate_car_count" -State $carCount -Attributes @{
                friendly_name       = "Main Gate Car Count"
                icon                = "mdi:car"
                unit_of_measurement = "cars"
                last_updated        = $now.ToString("o")
            }
        }

        "VisitorGate" {
            $gateStatus = if ($data.gate_status) { [string]$data.gate_status } else { "unknown" }
            $carCount = if ($data.car_count -ne $null) { [string]$data.car_count } else { "0" }

            Update-HaSensor -EntityId "sensor.visitor_gate_status" -State $gateStatus -Attributes @{
                friendly_name = "Visitor Gate Status"
                icon          = "mdi:gate"
                description   = [string]$data.description
                last_updated  = $now.ToString("o")
            }
            Update-HaSensor -EntityId "sensor.visitor_gate_car_count" -State $carCount -Attributes @{
                friendly_name       = "Visitor Gate Car Count"
                icon                = "mdi:car"
                unit_of_measurement = "cars"
                last_updated        = $now.ToString("o")
            }
        }

        "Lawn" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Lawn_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected on the lawn." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Pool" {
            # Update pool people count sensors
            $adultCount = if ($data.adult_count -ne $null) { [string]$data.adult_count } else { "0" }
            $childCount = if ($data.child_count -ne $null) { [string]$data.child_count } else { "0" }
            $poolCover  = if ($data.pool_cover) { [string]$data.pool_cover } else { "unknown" }

            Update-HaSensor -EntityId "sensor.pool_adult_count" -State $adultCount -Attributes @{
                friendly_name       = "Pool Adult Count"
                icon                = "mdi:account"
                unit_of_measurement = "people"
                last_updated        = $now.ToString("o")
            }
            Update-HaSensor -EntityId "sensor.pool_child_count" -State $childCount -Attributes @{
                friendly_name       = "Pool Child Count"
                icon                = "mdi:account-child"
                unit_of_measurement = "people"
                last_updated        = $now.ToString("o")
            }
            Update-HaSensor -EntityId "sensor.pool_cover_status" -State $poolCover -Attributes @{
                friendly_name = "Pool Cover Status"
                icon          = "mdi:pool"
                description   = [string]$data.description
                last_updated  = $now.ToString("o")
            }

            # Unsupervised children alert (daytime 06:00-20:00)
            $isDaytime = ($hour -ge 6) -and ($hour -lt 20)
            if ($isDaytime -and [int]$data.child_count -gt 0 -and [int]$data.adult_count -eq 0) {
                $alertKey = "Pool_unsupervised_children"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Warning. Children detected at the pool with no adult present." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }

            # Night security human detection (existing)
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Pool_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected at the pool area." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Garage" {
            # Update garage door sensors
            $leftDoor  = if ($data.left_garage_door) { [string]$data.left_garage_door } else { "unknown" }
            $rightDoor = if ($data.right_garage_door) { [string]$data.right_garage_door } else { "unknown" }

            Update-HaSensor -EntityId "sensor.left_garage_door" -State $leftDoor -Attributes @{
                friendly_name = "Left Garage Door"
                icon          = if ($leftDoor -eq "open") { "mdi:garage-open" } else { "mdi:garage" }
                description   = [string]$data.description
                last_updated  = $now.ToString("o")
            }
            Update-HaSensor -EntityId "sensor.right_garage_door" -State $rightDoor -Attributes @{
                friendly_name = "Right Garage Door"
                icon          = if ($rightDoor -eq "open") { "mdi:garage-open" } else { "mdi:garage" }
                description   = [string]$data.description
                last_updated  = $now.ToString("o")
            }

            # Garage door open duration tracking
            $garageDoors = $state.garage_doors
            foreach ($side in @("left", "right")) {
                $doorState = if ($side -eq "left") { $leftDoor } else { $rightDoor }
                $firstOpenProp = "${side}_first_open"
                $alertKey = "Garage_${side}_door_open"

                if ($doorState -eq "open") {
                    # Door is open — track when it first opened
                    $firstOpen = $garageDoors.PSObject.Properties[$firstOpenProp]
                    if (-not $firstOpen -or -not $firstOpen.Value) {
                        # First time seeing it open — record timestamp
                        if ($firstOpen) {
                            $garageDoors.$firstOpenProp = $now.ToString("o")
                        } else {
                            $garageDoors | Add-Member -NotePropertyName $firstOpenProp -NotePropertyValue $now.ToString("o") -Force
                        }
                        Write-Log "Garage: $side door first detected open"
                    } else {
                        # Already tracked — check if open > 5 minutes
                        try {
                            $openSince = [DateTime]::Parse($firstOpen.Value)
                            $openMinutes = ($now - $openSince).TotalMinutes
                            if ($openMinutes -ge 5) {
                                if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown 10)) {
                                    $sideLabel = $side.Substring(0,1).ToUpper() + $side.Substring(1)
                                    Send-Alert -AlertKey $alertKey -Message "Warning. The $sideLabel garage door has been open for more than 5 minutes." -ImageUrl $imageUrl
                                    Set-AlertTime -Key $alertKey
                                }
                            }
                        } catch {
                            Write-Log "Garage: Failed to parse $firstOpenProp timestamp: $($_.Exception.Message)" "WARN"
                        }
                    }
                } else {
                    # Door is closed — clear the first_open timestamp
                    if ($garageDoors.PSObject.Properties[$firstOpenProp]) {
                        $garageDoors.$firstOpenProp = $null
                    }
                }
            }

            # Night security human detection (existing)
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Garage_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the garage." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Lounge" {
            # Indoor security alert (12AM-6AM only)
            if ($isAfterMidnight -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Lounge_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the lounge." -ImageUrl $imageUrl
                    Set-AlertTime -Key $alertKey
                }
            }
        }
    }
}

# ============================================================
# Update vision analysis stats sensor (daily counts per camera)
# ============================================================

$statsAttributes = @{
    friendly_name = "Vision Analysis Stats"
    icon          = "mdi:chart-bar"
    last_updated  = $now.ToString("o")
}
foreach ($cam in $cameras) {
    $cs = Get-CameraScheduleState -CameraName $cam.Name
    $statsAttributes["$($cam.Name)_today"] = [int]$cs.daily_count
    # Include last 7 days of history as attribute
    $history = @($cs.daily_history)
    if ($history.Count -gt 0) {
        $recent = $history | Select-Object -Last 7
        $historyStr = ($recent | ForEach-Object { "$($_.date):$($_.count)" }) -join ", "
        $statsAttributes["$($cam.Name)_history"] = $historyStr
    }
}
$totalToday = 0
foreach ($cam in $cameras) {
    $cs = Get-CameraScheduleState -CameraName $cam.Name
    $totalToday += [int]$cs.daily_count
}

# Collect motion events across all cameras (last 30, newest first)
$allMotionEvents = @()
foreach ($cam in $cameras) {
    $cs = Get-CameraScheduleState -CameraName $cam.Name
    if ($cs.motion_events) {
        $allMotionEvents += @($cs.motion_events)
    }
    # Expose heavy_until per camera if active
    if ($cs.heavy_activity_until) {
        $statsAttributes["$($cam.Name)_heavy_until"] = $cs.heavy_activity_until
    }
}
$allMotionEvents = @($allMotionEvents | Sort-Object { $_.time } | Select-Object -Last 30)
[array]::Reverse($allMotionEvents)
if ($allMotionEvents.Count -eq 0) {
    $statsAttributes["motion_events"] = "[]"
} elseif ($allMotionEvents.Count -eq 1) {
    # ConvertTo-Json unwraps single-element arrays to a bare object — force array
    $statsAttributes["motion_events"] = "[" + ($allMotionEvents[0] | ConvertTo-Json -Depth 5 -Compress) + "]"
} else {
    $statsAttributes["motion_events"] = ($allMotionEvents | ConvertTo-Json -Depth 5 -Compress)
}

Update-HaSensor -EntityId "sensor.vision_analysis_stats" -State "$totalToday" -Attributes $statsAttributes

# ============================================================
# Update last detections sensor (rolling buffer per camera)
# ============================================================

$detAttrs = @{
    friendly_name = "Vision Last Detections"
    icon          = "mdi:eye"
    last_updated  = $now.ToString("o")
}
$totalDetections = 0
foreach ($cam in $cameras) {
    $histKey = "$($cam.Name)_history"
    $camHist = @()
    if ($state.detection_history.PSObject.Properties[$histKey]) {
        $camHist = @($state.detection_history.$histKey)
    }
    $detAttrs["$($cam.Name)_count"] = $camHist.Count
    $totalDetections += $camHist.Count
    if ($camHist.Count -gt 0) {
        $latest = $camHist[-1]
        $detAttrs["$($cam.Name)_last"] = [string]$latest.timestamp
        $detAttrs["$($cam.Name)_last_summary"] = [string]$latest.summary
        if ($latest.image_url) {
            $detAttrs["$($cam.Name)_image"] = [string]$latest.image_url
        }
    }
}
Update-HaSensor -EntityId "sensor.vision_last_detections" -State "$totalDetections" -Attributes $detAttrs

# ============================================================
# Save state
# ============================================================

$state | Add-Member -NotePropertyName "last_run" -NotePropertyValue $now.ToString("o") -Force
$state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8

$successCount = ($results | Where-Object { $_.Success }).Count
Write-Log "=== Tick $($tick+1)/$tickCount complete: $successCount/$($dueCameras.Count) cameras processed (total today: $totalToday) ==="

}  # end of polling loop

# end of mutex try block
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
