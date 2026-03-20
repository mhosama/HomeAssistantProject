<#
.SYNOPSIS
    Capture on-demand snapshots from EZVIZ farm cameras via cloud API, analyze with Gemini Flash, update HA sensors.

.DESCRIPTION
    Runs every 5 minutes via Windows Scheduled Task (HA-EzvizVision).
    - Logs into EZVIZ cloud API (EU region) to get a session token
    - Triggers on-demand capture on each camera via PUT /v3/devconfig/v1/{serial}/{channel}/capture
    - Downloads the fresh snapshot from the returned picUrl
    - Sends each to Gemini Flash for structured JSON analysis
    - Updates HA sensors (fire/smoke, rain, animals, humans/vehicles, per-camera status)
    - Fires TTS + phone alerts for fire/smoke and night-time intruders
    - Uses mutex to prevent overlapping runs
    - Each camera runs in its own runspace for parallel execution

    Separate pipeline from home cameras (08a) - own schedule, state file, mutex, log.

.EXAMPLE
    .\10a-Run-EzvizVision.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

# ============================================================
# Mutex - prevent overlapping runs
# ============================================================

$mutexName = "Global\HA-EzvizVision"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)

if (-not $mutex.WaitOne(0)) {
    # Another instance is running, exit silently
    exit 0
}

try {

# ============================================================
# Configuration
# ============================================================

$haBase      = "http://$($Config.HA_IP):8123"
$haToken     = $Config.HA_TOKEN
$geminiKey   = $Config.GeminiApiKey
$geminiModel = $Config.GeminiModel

$logDir    = Join-Path $scriptDir "logs"
$logFile   = Join-Path $logDir "ezviz_analysis.log"
$stateFile = Join-Path $scriptDir ".ezviz_vision_state.json"

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

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

Write-Log "=== EZVIZ vision analysis run starting ==="

# ============================================================
# Time context
# ============================================================

$now  = Get-Date
$hour = $now.Hour

$isNightSecurity = ($hour -ge 20) -or ($hour -lt 6)    # 8PM - 6AM

# ============================================================
# State file (alert throttling)
# ============================================================

$defaultState = @{
    last_alerts       = @{}
    last_run          = ""
    detection_history = @{}
}

if (Test-Path $stateFile) {
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        if (-not $state.last_alerts) { $state | Add-Member -NotePropertyName "last_alerts" -NotePropertyValue @{} -Force }
        if (-not $state.PSObject.Properties["detection_history"]) { $state | Add-Member -NotePropertyName "detection_history" -NotePropertyValue (New-Object PSObject) -Force }
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
# Alert configuration (all detections → TTS + phone, always)
# ============================================================

$alertConfig = @{
    "Farm_fire_smoke" = @{ TTS = $true; Phone = $true; Cooldown = 10 }
    "Farm_human"      = @{ TTS = $true; Phone = $true; Cooldown = 5  }
    "Farm_vehicle"    = @{ TTS = $true; Phone = $true; Cooldown = 5  }
    "Farm_animal"     = @{ TTS = $true; Phone = $true; Cooldown = 10 }
    "Farm_rain"       = @{ TTS = $true; Phone = $true; Cooldown = 30 }
}

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"
$notifyEntity   = $Config.NotifyEntity

# Battery threshold: skip capture if battery below this, but still poll battery level
$lowBatteryThreshold = 20

$sambaWww = "\\192.168.0.239\config\www"

function Save-FarmDetectionSnapshot {
    param([int]$CamNum, [byte[]]$ImageBytes, [string]$Timestamp)
    if (-not $ImageBytes -or $ImageBytes.Count -eq 0) { return $null }

    try {
        if (-not (Test-Path $sambaWww)) {
            Write-Log "Samba www not accessible ($sambaWww) - skipping snapshot for FarmCam$CamNum" "WARN"
            return $null
        }

        $slotKey = "FarmCam${CamNum}_slot"
        $currentSlot = 0
        if ($state.detection_history.PSObject.Properties[$slotKey]) {
            $currentSlot = [int]$state.detection_history.$slotKey
        }
        $nextSlot = ($currentSlot % 5) + 1

        $filename = "farm_detect_${CamNum}_${nextSlot}.jpg"
        $fullPath = Join-Path $sambaWww $filename
        [IO.File]::WriteAllBytes($fullPath, $ImageBytes)

        if ($state.detection_history.PSObject.Properties[$slotKey]) {
            $state.detection_history.$slotKey = $nextSlot
        } else {
            $state.detection_history | Add-Member -NotePropertyName $slotKey -NotePropertyValue $nextSlot -Force
        }

        return "/local/$filename"
    } catch {
        Write-Log "Failed to save snapshot for FarmCam${CamNum}: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# ============================================================
# Camera definitions (EZVIZ serial numbers from device registry)
# ============================================================
# Each camera needs its Serial (from HA device registry identifiers).
# Channel is 1 for single-channel cameras (all EB3/EB8 models).

$cameras = @(
    @{
        Name    = "FarmCam1"
        Serial  = "BB7898720"    # EB8
        Channel = 1
        Prompt  = $null          # null = use default prompt
    }
    # FarmCam2 - not registered on EZVIZ account
    @{
        Name    = "FarmCam3"
        Serial  = "BD0555089"    # EB8
        Channel = 1
        Prompt  = $null
    }
    # FarmCam4 - not registered on EZVIZ account
    @{
        Name    = "FarmCam5"
        Serial  = "BF2666942"    # EB3
        Channel = 1
        Prompt  = $null
    }
    # FarmCam6 - not registered on EZVIZ account
)

# ============================================================
# EZVIZ cloud API login (get session token for capture requests)
# ============================================================

$ezvizApiDomain = "apiieu.ezvizlife.com"
$ezvizSessionId = $null

$md5 = [System.Security.Cryptography.MD5]::Create()

# Feature code: MD5 of a MAC-like identifier (matches pyezviz pattern)
$macBytes = [System.Text.Encoding]::UTF8.GetBytes("00:11:22:33:44:55")
$featureCode = [BitConverter]::ToString($md5.ComputeHash($macBytes)).Replace("-","").ToLower()

# Password: MD5 hash (EZVIZ API requires hashed password)
$pwdBytes = [System.Text.Encoding]::UTF8.GetBytes($Config.EzvizPassword)
$pwdHash = [BitConverter]::ToString($md5.ComputeHash($pwdBytes)).Replace("-","").ToLower()

Write-Log "Logging into EZVIZ cloud API..."
try {
    $loginData = "account=$([uri]::EscapeDataString($Config.EzvizUsername))&password=$pwdHash&featureCode=$featureCode&msgType=0&cuName=SGFzc2lv"
    $loginResp = Invoke-RestMethod -Uri "https://$ezvizApiDomain/v3/users/login/v5" -Method POST `
        -Body $loginData -ContentType "application/x-www-form-urlencoded" `
        -Headers @{ "featureCode" = $featureCode; "clientType" = "3"; "User-Agent" = "okhttp/3.12.1" } `
        -TimeoutSec 30

    if ($loginResp.meta.code -eq 200) {
        $ezvizSessionId = $loginResp.loginSession.sessionId
        $ezvizApiDomain = $loginResp.loginArea.apiDomain
        Write-Log "EZVIZ login OK (domain=$ezvizApiDomain)"
    } else {
        Write-Log "EZVIZ login failed: code=$($loginResp.meta.code) msg=$($loginResp.meta.message)" "ERROR"
    }
} catch {
    Write-Log "EZVIZ login error: $($_.Exception.Message)" "ERROR"
}

if (-not $ezvizSessionId) {
    Write-Log "Cannot proceed without EZVIZ session - aborting" "ERROR"
    $state | Add-Member -NotePropertyName "last_run" -NotePropertyValue $now.ToString("o") -Force
    $state | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8
    exit 0
}

# ============================================================
# Default Gemini prompt (used when camera Prompt is $null)
# ============================================================

$defaultPrompt = @"
Analyze this farm security camera image. This may be night-vision (grayscale/infrared). Return ONLY the structured JSON below with precise counts and flags. Do NOT include scene descriptions.

{"humans": {"count": 0}, "vehicles": {"count": 0, "types": ""}, "animals": {"count": 0, "types": ""}, "fire_smoke": {"detected": false, "severity": "none", "estimated_distance": ""}, "rain": {"detected": false, "intensity": "none"}}

Field rules:
- humans.count: number of people visible (0 if none)
- vehicles.count: number of cars/trucks/bakkies/tractors/motorcycles (0 if none)
- vehicles.types: comma-separated types if any (e.g. "bakkie, tractor"), empty string if none
- animals.count: total animals visible (0 if none)
- animals.types: comma-separated species if identifiable (e.g. "cattle, dogs"), empty string if none
- fire_smoke.detected: true only if fire, smoke, or burning haze is visible
- fire_smoke.severity: "none", "low", "medium", or "high"
- fire_smoke.estimated_distance: "close" (on property), "medium" (few hundred meters), "far" (horizon), or "" if not detected
- rain.detected: true only if active rain is visible (rain streaks, water on lens, puddles forming)
- rain.intensity: "none", "light", "moderate", or "heavy"
"@

function Get-CameraPrompt {
    param([hashtable]$Camera)
    if ($Camera.Prompt) { return $Camera.Prompt }
    return $defaultPrompt
}

# ============================================================
# Parallel execution: EZVIZ cloud capture + Gemini per camera
# ============================================================

# ============================================================
# Check battery levels and update battery sensors
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

$camerasToCapture = @()
foreach ($cam in $cameras) {
    $camIndex = $cam.Name -replace "FarmCam", ""
    $batteryEntityId = "sensor.farm_camera_${camIndex}_battery"

    # Read battery level from HA
    $batteryPct = -1
    try {
        $battState = Invoke-RestMethod -Uri "$haBase/api/states/$batteryEntityId" -Headers $haHeaders -TimeoutSec 10
        if ($battState.state -ne "unavailable" -and $battState.state -ne "unknown") {
            $batteryPct = [int]$battState.state
        }
    } catch {
        Write-Log "$($cam.Name): Could not read battery ($batteryEntityId)" "WARN"
    }

    # Update battery sensor for dashboard
    Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_battery" -State $(if ($batteryPct -ge 0) { "$batteryPct" } else { "unknown" }) -Attributes @{
        friendly_name       = "Farm Camera $camIndex Battery"
        icon                = if ($batteryPct -ge 0 -and $batteryPct -lt $lowBatteryThreshold) { "mdi:battery-alert" } else { "mdi:battery" }
        device_class        = "battery"
        unit_of_measurement = "%"
        low_battery         = ($batteryPct -ge 0 -and $batteryPct -lt $lowBatteryThreshold)
        last_updated        = $now.ToString("o")
    }

    if ($batteryPct -ge 0 -and $batteryPct -lt $lowBatteryThreshold) {
        Write-Log "$($cam.Name): Battery low ($batteryPct%) - skipping capture to preserve battery" "WARN"
        Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State "low battery ($batteryPct%)" -Attributes @{
            friendly_name = "Farm Camera $camIndex"
            icon          = "mdi:battery-alert"
            source        = "ezviz"
            battery       = $batteryPct
            last_updated  = $now.ToString("o")
        }
    } else {
        $camerasToCapture += $cam
    }
}

Write-Log "Processing $($camerasToCapture.Count)/$($cameras.Count) cameras (night=$isNightSecurity, skipped=$(($cameras.Count - $camerasToCapture.Count)) low-battery)"

$workerScript = {
    param(
        [string]$CameraName,
        [string]$CameraSerial,
        [int]$CameraChannel,
        [string]$Prompt,
        [string]$EzvizApiDomain,
        [string]$EzvizSessionId,
        [string]$FeatureCode,
        [string]$HaBase,
        [string]$HaToken,
        [string]$GeminiKey,
        [string]$GeminiModel
    )

    $result = @{
        Camera     = $CameraName
        Success    = $false
        Data       = $null
        PicUrl     = $null
        ImageBytes = $null
        Error      = $null
    }

    try {
        # 1. Trigger on-demand capture via EZVIZ cloud API
        $captureUrl = "https://$EzvizApiDomain/v3/devconfig/v1/$CameraSerial/$CameraChannel/capture"
        $captureHeaders = @{ "sessionId" = $EzvizSessionId; "featureCode" = $FeatureCode }

        try {
            $captureResp = Invoke-RestMethod -Uri $captureUrl -Method PUT -Headers $captureHeaders -TimeoutSec 30
        } catch {
            $result.Error = "Capture API failed for $CameraSerial : $($_.Exception.Message)"
            return $result
        }

        if ($captureResp.meta.code -ne 200) {
            $result.Error = "Capture failed: code=$($captureResp.meta.code) msg=$($captureResp.meta.message)"
            return $result
        }

        $picUrl = $captureResp.captureInfo.picUrl
        if (-not $picUrl) {
            $result.Error = "Capture returned no picUrl"
            return $result
        }

        # 2. Download the fresh snapshot from picUrl
        try {
            $imgResp = Invoke-WebRequest -Uri $picUrl -UseBasicParsing -TimeoutSec 30
            $imageBytes = $imgResp.Content
        } catch {
            $result.Error = "Failed to download image from picUrl: $($_.Exception.Message)"
            return $result
        }

        if (-not $imageBytes -or $imageBytes.Length -lt 500) {
            $result.Error = "Downloaded image too small ($($imageBytes.Length) bytes) - camera may be offline"
            return $result
        }

        # 3. Save captured image to HA /config/www/ via Samba for dashboard display
        $result.PicUrl = $picUrl
        $result.ImageBytes = $imageBytes
        $camNum = $CameraName -replace "FarmCam", ""
        try {
            $sambaPath = "\\192.168.0.239\config\www\farm_cam${camNum}_latest.jpg"
            [System.IO.File]::WriteAllBytes($sambaPath, $imageBytes)
        } catch {
            # Non-critical — dashboard image won't update but analysis continues
        }

        $base64Image = [Convert]::ToBase64String($imageBytes)

        # 4. Call Gemini API
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

        # 5. Extract JSON from response
        $responseText = $geminiResp.candidates[0].content.parts[0].text
        $parsed = $responseText | ConvertFrom-Json
        $result.Data = $parsed
        $result.Success = $true
    } catch {
        $result.Error = "Processing failed: $($_.Exception.Message)"
    }

    return $result
}

# Create runspace pool
$pool = [RunspaceFactory]::CreateRunspacePool(1, 6)
$pool.Open()

$jobs = @()

foreach ($cam in $camerasToCapture) {
    $prompt = Get-CameraPrompt -Camera $cam

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    $null = $ps.AddScript($workerScript).AddParameters(@{
        CameraName      = $cam.Name
        CameraSerial    = $cam.Serial
        CameraChannel   = $cam.Channel
        Prompt          = $prompt
        EzvizApiDomain  = $ezvizApiDomain
        EzvizSessionId  = $ezvizSessionId
        FeatureCode     = $featureCode
        HaBase          = $haBase
        HaToken         = $haToken
        GeminiKey       = $geminiKey
        GeminiModel     = $geminiModel
    })

    $jobs += @{
        PowerShell = $ps
        Handle     = $ps.BeginInvoke()
        Camera     = $cam
    }
}

# Wait for all jobs to complete (max 120 seconds - cloud capture + download + Gemini)
$deadline = (Get-Date).AddSeconds(120)
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
    param([string]$Message, [string]$Title = "Farm Vision Alert")
    if (-not $notifyEntity) { return }
    $body = @{
        message = $Message
        title   = $Title
    } | ConvertTo-Json -Depth 5
    try {
        $svcName = $notifyEntity -replace "notify\.", ""
        $null = Invoke-WebRequest -Uri "$haBase/api/services/notify/$svcName" -Method POST -Headers $haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 15
        Write-Log "Phone alert sent: $Message"
    } catch {
        Write-Log "Phone alert failed: $($_.Exception.Message)" "ERROR"
    }
}

function Send-Alert {
    param([string]$AlertKey, [string]$Message)
    $cfg = $alertConfig[$AlertKey]
    if ($cfg.TTS) { Send-TTS $Message }
    if ($cfg.Phone) { Send-PhoneAlert -Message $Message }
}

# Aggregate data across all cameras
$totalHumans   = 0
$totalVehicles = 0
$totalAnimals  = 0
$animalTypes   = @()
$fireDetected  = $false
$fireSeverity  = "none"
$fireDistance   = ""
$fireCameras   = @()
$rainDetected  = $false
$rainIntensity = "none"
$humanCameras  = @()
$vehicleCameras = @()

foreach ($r in $results) {
    $camName = $r.Camera
    $camIndex = [int]($camName -replace "FarmCam", "") # Extract camera number

    if (-not $r.Success) {
        Write-Log "${camName}: FAILED - $($r.Error)" "ERROR"
        # Update per-camera sensor with error
        Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State "error" -Attributes @{
            friendly_name = "Farm Camera $camIndex"
            icon          = "mdi:cctv"
            source        = "ezviz"
            error         = [string]$r.Error
            last_updated  = $now.ToString("o")
        }
        continue
    }

    $data = $r.Data
    Write-Log "${camName}: $($data | ConvertTo-Json -Compress)"

    # Build compact state string from detection flags
    $stateParts = @()
    if ([int]$data.humans.count -gt 0)  { $stateParts += "$([int]$data.humans.count) human(s)" }
    if ([int]$data.vehicles.count -gt 0) { $stateParts += "$([int]$data.vehicles.count) vehicle(s)" }
    if ([int]$data.animals.count -gt 0)  { $stateParts += "$([int]$data.animals.count) animal(s)" }
    if ($data.fire_smoke.detected -eq $true) { $stateParts += "FIRE/SMOKE" }
    if ($data.rain.detected -eq $true) { $stateParts += "rain:$($data.rain.intensity)" }
    $stateText = if ($stateParts.Count -gt 0) { $stateParts -join ", " } else { "clear" }

    $sensorAttrs = @{
        friendly_name  = "Farm Camera $camIndex"
        icon           = "mdi:cctv"
        source         = "ezviz"
        humans         = [int]$data.humans.count
        vehicles       = [int]$data.vehicles.count
        vehicle_types  = [string]$data.vehicles.types
        animals        = [int]$data.animals.count
        animal_types   = [string]$data.animals.types
        fire_smoke     = [bool]$data.fire_smoke.detected
        fire_severity  = [string]$data.fire_smoke.severity
        fire_distance  = [string]$data.fire_smoke.estimated_distance
        rain           = [bool]$data.rain.detected
        rain_intensity = [string]$data.rain.intensity
        last_updated   = $now.ToString("o")
    }
    # Add picUrl as entity_picture if available (for dashboard display)
    if ($r.PicUrl) { $sensorAttrs["entity_picture"] = $r.PicUrl }

    Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State $stateText -Attributes $sensorAttrs

    # Record detection history (only when something is detected)
    if ($stateText -ne "clear") {
        $imageUrl = Save-FarmDetectionSnapshot -CamNum $camIndex -ImageBytes $r.ImageBytes -Timestamp $now.ToString("o")
        $summary = $stateText
        if ($summary.Length -gt 200) { $summary = $summary.Substring(0, 200) }

        $entry = [PSCustomObject]@{
            timestamp = $now.ToString("o")
            summary   = $summary
            image_url = $imageUrl
        }

        $histKey = "FarmCam${camIndex}_history"
        if (-not $state.detection_history.PSObject.Properties[$histKey]) {
            $state.detection_history | Add-Member -NotePropertyName $histKey -NotePropertyValue @() -Force
        }
        $histArray = @($state.detection_history.$histKey) + @($entry)
        if ($histArray.Count -gt 5) { $histArray = $histArray | Select-Object -Last 5 }
        $state.detection_history.$histKey = $histArray
    }

    # Aggregate humans
    if ($data.humans.count -gt 0) {
        $totalHumans += [int]$data.humans.count
        $humanCameras += $camName
    }

    # Aggregate vehicles
    if ($data.vehicles.count -gt 0) {
        $totalVehicles += [int]$data.vehicles.count
        $vehicleCameras += $camName
    }

    # Aggregate animals
    if ($data.animals.count -gt 0) {
        $totalAnimals += [int]$data.animals.count
        if ($data.animals.types) { $animalTypes += [string]$data.animals.types }
    }

    # Aggregate fire/smoke (highest severity wins)
    if ($data.fire_smoke.detected -eq $true) {
        $fireDetected = $true
        $fireCameras += $camName
        $severityOrder = @{ "none" = 0; "low" = 1; "medium" = 2; "high" = 3 }
        $currentSev = if ($data.fire_smoke.severity) { [string]$data.fire_smoke.severity } else { "low" }
        if ($severityOrder[$currentSev] -gt $severityOrder[$fireSeverity]) {
            $fireSeverity = $currentSev
            $fireDistance = [string]$data.fire_smoke.estimated_distance
        }
    }

    # Aggregate rain (highest intensity wins)
    if ($data.rain.detected -eq $true) {
        $rainDetected = $true
        $intensityOrder = @{ "none" = 0; "light" = 1; "moderate" = 2; "heavy" = 3 }
        $currentInt = if ($data.rain.intensity) { [string]$data.rain.intensity } else { "light" }
        if ($intensityOrder[$currentInt] -gt $intensityOrder[$rainIntensity]) {
            $rainIntensity = $currentInt
        }
    }
}

# ============================================================
# Update aggregate sensors
# ============================================================

# Fire/Smoke sensor
$fireState = if ($fireDetected) { "$fireSeverity" } else { "none" }
Update-HaSensor -EntityId "sensor.farm_fire_smoke" -State $fireState -Attributes @{
    friendly_name      = "Farm Fire/Smoke"
    icon               = if ($fireDetected) { "mdi:fire" } else { "mdi:fire-alert" }
    detected           = $fireDetected
    severity           = $fireSeverity
    estimated_distance = $fireDistance
    cameras_detecting  = ($fireCameras -join ", ")
    last_updated       = $now.ToString("o")
}

# Rain sensor
$rainState = if ($rainDetected) { $rainIntensity } else { "none" }
Update-HaSensor -EntityId "sensor.farm_rain_status" -State $rainState -Attributes @{
    friendly_name = "Farm Rain Status"
    icon          = if ($rainDetected) { "mdi:weather-pouring" } else { "mdi:weather-rainy" }
    detected      = $rainDetected
    intensity     = $rainIntensity
    last_updated  = $now.ToString("o")
}

# Animal summary sensor
$animalDesc = if ($totalAnimals -gt 0) { "$totalAnimals animals ($($animalTypes -join ', '))" } else { "none detected" }
Update-HaSensor -EntityId "sensor.farm_animal_summary" -State $animalDesc -Attributes @{
    friendly_name = "Farm Animals"
    icon          = "mdi:cow"
    total_count   = $totalAnimals
    animal_types  = ($animalTypes -join ", ")
    last_updated  = $now.ToString("o")
}

# Human/Vehicle summary sensor
$hvState = if ($totalHumans -gt 0 -or $totalVehicles -gt 0) {
    $parts = @()
    if ($totalHumans -gt 0) { $parts += "$totalHumans human(s)" }
    if ($totalVehicles -gt 0) { $parts += "$totalVehicles vehicle(s)" }
    $parts -join ", "
} else { "clear" }

Update-HaSensor -EntityId "sensor.farm_human_vehicle_summary" -State $hvState -Attributes @{
    friendly_name    = "Farm Humans/Vehicles"
    icon             = if ($totalHumans -gt 0) { "mdi:account-alert" } else { "mdi:account-check" }
    human_count      = $totalHumans
    vehicle_count    = $totalVehicles
    human_cameras    = ($humanCameras -join ", ")
    vehicle_cameras  = ($vehicleCameras -join ", ")
    last_updated     = $now.ToString("o")
}

# ============================================================
# Update farm last detections sensor (rolling buffer per camera)
# ============================================================

$detAttrs = @{
    friendly_name = "Farm Last Detections"
    icon          = "mdi:eye"
    last_updated  = $now.ToString("o")
}
$totalFarmDetections = 0
foreach ($cam in $cameras) {
    $camIdx = $cam.Name -replace "FarmCam", ""
    $histKey = "FarmCam${camIdx}_history"
    $camHist = @()
    if ($state.detection_history.PSObject.Properties[$histKey]) {
        $camHist = @($state.detection_history.$histKey)
    }
    $detAttrs["FarmCam${camIdx}_count"] = $camHist.Count
    $totalFarmDetections += $camHist.Count
    if ($camHist.Count -gt 0) {
        $latest = $camHist[-1]
        $detAttrs["FarmCam${camIdx}_last"] = [string]$latest.timestamp
        $detAttrs["FarmCam${camIdx}_last_summary"] = [string]$latest.summary
        if ($latest.image_url) {
            $detAttrs["FarmCam${camIdx}_image"] = [string]$latest.image_url
        }
    }
}
Update-HaSensor -EntityId "sensor.farm_last_detections" -State "$totalFarmDetections" -Attributes $detAttrs

# ============================================================
# Alerts — all detections, always (TTS + phone, with throttling)
# ============================================================

if ($fireDetected) {
    $alertKey = "Farm_fire_smoke"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        $distNote = if ($fireDistance) { " It appears to be $fireDistance." } else { "" }
        Send-Alert -AlertKey $alertKey -Message "Warning! Fire or smoke detected at the farm. Severity: $fireSeverity.$distNote Cameras: $($fireCameras -join ', ')."
        Set-AlertTime -Key $alertKey
    }
}

if ($totalHumans -gt 0) {
    $alertKey = "Farm_human"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        Send-Alert -AlertKey $alertKey -Message "Farm alert. $totalHumans person or people detected at: $($humanCameras -join ', ')."
        Set-AlertTime -Key $alertKey
    }
}

if ($totalVehicles -gt 0) {
    $alertKey = "Farm_vehicle"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        Send-Alert -AlertKey $alertKey -Message "Farm alert. $totalVehicles vehicle or vehicles detected at: $($vehicleCameras -join ', ')."
        Set-AlertTime -Key $alertKey
    }
}

if ($totalAnimals -gt 0) {
    $alertKey = "Farm_animal"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        Send-Alert -AlertKey $alertKey -Message "Farm alert. $totalAnimals animal or animals detected: $($animalTypes -join ', ')."
        Set-AlertTime -Key $alertKey
    }
}

if ($rainDetected) {
    $alertKey = "Farm_rain"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        Send-Alert -AlertKey $alertKey -Message "Farm weather alert. Rain detected at the farm. Intensity: $rainIntensity."
        Set-AlertTime -Key $alertKey
    }
}

# ============================================================
# Save state
# ============================================================

$state | Add-Member -NotePropertyName "last_run" -NotePropertyValue $now.ToString("o") -Force
$state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8

$successCount = ($results | Where-Object { $_.Success }).Count
Write-Log "=== Run complete: $successCount/$($camerasToCapture.Count) captured, $($cameras.Count - $camerasToCapture.Count) skipped (low battery) ==="

# end of mutex try block
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
