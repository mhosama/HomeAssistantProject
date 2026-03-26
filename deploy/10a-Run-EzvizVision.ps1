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
$geminiModel    = $Config.GeminiModel
$geminiProModel = "gemini-2.5-pro"

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
# Gemini Token Stats (shared state file, cross-process locking)
# ============================================================

$geminiStatsFile = Join-Path $scriptDir ".gemini_token_stats.json"

function Update-GeminiTokenStats {
    param(
        [string]$Source,
        [int]$Calls = 0,
        [int]$PromptTokens = 0,
        [int]$CompletionTokens = 0,
        [int]$TotalTokens = 0
    )
    if ($Calls -eq 0 -and $TotalTokens -eq 0) { return }

    $mtx = $null
    try {
        $mtx = New-Object System.Threading.Mutex($false, "Global\HA-GeminiTokenStats")
        $null = $mtx.WaitOne(5000)

        $today = (Get-Date).ToString("yyyy-MM-dd")

        if (Test-Path $geminiStatsFile) {
            $stats = Get-Content $geminiStatsFile -Raw | ConvertFrom-Json
        } else {
            $stats = [PSCustomObject]@{ daily_date = $today; sources = [PSCustomObject]@{}; daily_history = @() }
        }

        # Daily rollover
        if ($stats.daily_date -ne $today) {
            $oldDate = $stats.daily_date
            if ($oldDate -and $stats.sources.PSObject.Properties.Count -gt 0) {
                $dayCalls = 0; $dayPrompt = 0; $dayCompletion = 0; $dayTotal = 0; $dayCost = 0
                # Gemini 2.5 Flash: $0.30/$2.50, Pro: $1.25/$10.00 per M tokens
                foreach ($p in $stats.sources.PSObject.Properties) {
                    $dayCalls += [int]$p.Value.calls
                    $dayPrompt += [int]$p.Value.prompt_tokens
                    $dayCompletion += [int]$p.Value.completion_tokens
                    $dayTotal += [int]$p.Value.total_tokens
                    if ($p.Name -eq "ezviz_vision_pro") {
                        $dayCost += ([int]$p.Value.prompt_tokens * 1.25 + [int]$p.Value.completion_tokens * 10.00) / 1000000
                    } else {
                        $dayCost += ([int]$p.Value.prompt_tokens * 0.30 + [int]$p.Value.completion_tokens * 2.50) / 1000000
                    }
                }
                $dayCost = [math]::Round($dayCost, 4)
                $entry = [PSCustomObject]@{
                    date = $oldDate; calls = $dayCalls; prompt_tokens = $dayPrompt
                    completion_tokens = $dayCompletion; total_tokens = $dayTotal
                    estimated_cost_usd = $dayCost
                }
                $history = @($stats.daily_history) + @($entry)
                if ($history.Count -gt 30) { $history = $history | Select-Object -Last 30 }
                $stats.daily_history = $history
            }
            $stats.daily_date = $today
            $stats.sources = [PSCustomObject]@{}
        }

        # Update source
        if (-not $stats.sources.PSObject.Properties[$Source]) {
            $stats.sources | Add-Member -NotePropertyName $Source -NotePropertyValue ([PSCustomObject]@{
                calls = 0; prompt_tokens = 0; completion_tokens = 0; total_tokens = 0
            }) -Force
        }
        $src = $stats.sources.$Source
        $src.calls = [int]$src.calls + $Calls
        $src.prompt_tokens = [int]$src.prompt_tokens + $PromptTokens
        $src.completion_tokens = [int]$src.completion_tokens + $CompletionTokens
        $src.total_tokens = [int]$src.total_tokens + $TotalTokens

        $stats | ConvertTo-Json -Depth 10 | Set-Content $geminiStatsFile -Encoding UTF8
    } catch {
        # Non-critical
    } finally {
        if ($mtx) { try { $mtx.ReleaseMutex() } catch {} ; $mtx.Dispose() }
    }
}

# ============================================================
# Gemini Pro verification (second pass for security detections)
# ============================================================

function Invoke-GeminiProVerification {
    param(
        [string]$CameraName,
        [byte[]]$ImageBytes,
        [PSCustomObject]$FirstPassData
    )

    $result = @{
        Confirmed        = $false
        Description      = ""
        Confidence       = $null
        PromptTokens     = 0
        CompletionTokens = 0
        TotalTokens      = 0
        Error            = $null
    }

    $base64Image = [Convert]::ToBase64String($ImageBytes)

    # Build summary of what Flash detected
    $detections = @()
    if ([int]$FirstPassData.humans.count -gt 0) { $detections += "$([int]$FirstPassData.humans.count) human(s)" }
    if ([int]$FirstPassData.vehicles.count -gt 0) { $detections += "$([int]$FirstPassData.vehicles.count) vehicle(s) ($($FirstPassData.vehicles.types))" }
    if ([int]$FirstPassData.animals.count -gt 0) { $detections += "$([int]$FirstPassData.animals.count) animal(s) ($($FirstPassData.animals.types))" }
    if ($FirstPassData.fire_smoke.detected -eq $true) { $detections += "fire/smoke (severity: $($FirstPassData.fire_smoke.severity))" }
    $detectionSummary = $detections -join "; "

    $proPrompt = @"
A fast AI model analyzed this farm security camera image and reported these detections: $detectionSummary

Please carefully verify this image. For each claimed detection, confirm or reject it. Be very descriptive about what you see. Provide your response as JSON only:

{"confirmed": true, "description": "2-3 sentence detailed description of what you actually see in the image", "detections": {"humans": {"confirmed": false, "count": 0, "confidence_pct": 0, "detail": ""}, "vehicles": {"confirmed": false, "count": 0, "confidence_pct": 0, "detail": ""}, "animals": {"confirmed": false, "count": 0, "confidence_pct": 0, "detail": ""}, "fire_smoke": {"confirmed": false, "confidence_pct": 0, "detail": ""}}}

Rules:
- "confirmed" at top level = true if ANY detection is genuinely present (not a false positive)
- Per-detection "confirmed" = true only if that specific detection type is real
- confidence_pct: 0-100 how confident you are the detection is real
- detail: descriptive text (e.g. "2 brown cattle grazing near the eastern fence line", "adult male walking along the dirt road carrying a bag")
- description: overall scene description including lighting, weather conditions, and what you observe
- Common false positives on farm cameras: tree stumps or poles as people, dust clouds as smoke, shadows as vehicles, rocks as animals
- This is a farm in South Africa - wildlife and livestock are expected but still noteworthy
- If night vision (grayscale/infrared), note reduced confidence accordingly
"@

    $geminiUri = "https://generativelanguage.googleapis.com/v1beta/models/${geminiProModel}:generateContent?key=$geminiKey"

    $geminiBody = @{
        contents = @(@{
            parts = @(
                @{ inline_data = @{ mime_type = "image/jpeg"; data = $base64Image } }
                @{ text = $proPrompt }
            )
        })
        generationConfig = @{
            responseMimeType = "application/json"
            temperature      = 0.2
        }
    } | ConvertTo-Json -Depth 10

    try {
        $geminiResp = Invoke-RestMethod -Uri $geminiUri -Method POST `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($geminiBody)) `
            -ContentType "application/json; charset=utf-8" -TimeoutSec 120

        if ($geminiResp.usageMetadata) {
            $result.PromptTokens     = [int]$geminiResp.usageMetadata.promptTokenCount
            $result.CompletionTokens = [int]$geminiResp.usageMetadata.candidatesTokenCount
            $result.TotalTokens      = [int]$geminiResp.usageMetadata.totalTokenCount
        }

        $responseText = $geminiResp.candidates[0].content.parts[0].text
        $parsed = $responseText | ConvertFrom-Json
        $result.Confirmed   = [bool]$parsed.confirmed
        $result.Description = [string]$parsed.description
        $result.Confidence  = $parsed.detections
    } catch {
        $result.Error = "Pro verification failed: $($_.Exception.Message)"
    }

    return $result
}

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
        Camera           = $CameraName
        Success          = $false
        Data             = $null
        PicUrl           = $null
        ImageBytes       = $null
        Error            = $null
        PromptTokens     = 0
        CompletionTokens = 0
        TotalTokens      = 0
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

        # 5. Extract token usage from response
        if ($geminiResp.usageMetadata) {
            $result.PromptTokens     = [int]$geminiResp.usageMetadata.promptTokenCount
            $result.CompletionTokens = [int]$geminiResp.usageMetadata.candidatesTokenCount
            $result.TotalTokens      = [int]$geminiResp.usageMetadata.totalTokenCount
        }

        # 6. Extract JSON from response
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
# Aggregate Gemini token usage from worker results
# ============================================================

$tickPromptTokens = 0; $tickCompletionTokens = 0; $tickTotalTokens = 0; $tickCalls = 0
foreach ($r in $results) {
    if ($r.TotalTokens -and [int]$r.TotalTokens -gt 0) {
        $tickPromptTokens     += [int]$r.PromptTokens
        $tickCompletionTokens += [int]$r.CompletionTokens
        $tickTotalTokens      += [int]$r.TotalTokens
        $tickCalls++
    }
}
if ($tickCalls -gt 0) {
    Write-Log "Gemini tokens this run: $tickCalls calls, $tickPromptTokens prompt, $tickCompletionTokens completion, $tickTotalTokens total"
    Update-GeminiTokenStats -Source "ezviz_vision" -Calls $tickCalls -PromptTokens $tickPromptTokens -CompletionTokens $tickCompletionTokens -TotalTokens $tickTotalTokens
}

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
    param([string]$Message, [string]$Title = "Farm Vision Alert", [string]$ImageUrl = $null)
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

# ============================================================
# First pass: Aggregate data across all cameras (Flash results)
# ============================================================

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

# Store per-camera data and image URLs for second pass + alerts
$cameraFirstPass = @{}
$cameraImageUrls = @{}

foreach ($r in $results) {
    $camName = $r.Camera
    $camIndex = [int]($camName -replace "FarmCam", "") # Extract camera number

    if (-not $r.Success) {
        Write-Log "${camName}: FAILED - $($r.Error)" "ERROR"
        Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State "error" -Attributes @{
            friendly_name       = "Farm Camera $camIndex"
            icon                = "mdi:cctv"
            source              = "ezviz"
            error               = [string]$r.Error
            verified_status     = ""
            verification_detail = ""
            verification_model  = ""
            verification_time   = ""
            last_updated        = $now.ToString("o")
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
        friendly_name       = "Farm Camera $camIndex"
        icon                = "mdi:cctv"
        source              = "ezviz"
        humans              = [int]$data.humans.count
        vehicles            = [int]$data.vehicles.count
        vehicle_types       = [string]$data.vehicles.types
        animals             = [int]$data.animals.count
        animal_types        = [string]$data.animals.types
        fire_smoke          = [bool]$data.fire_smoke.detected
        fire_severity       = [string]$data.fire_smoke.severity
        fire_distance       = [string]$data.fire_smoke.estimated_distance
        rain                = [bool]$data.rain.detected
        rain_intensity      = [string]$data.rain.intensity
        verified_status     = ""
        verification_detail = ""
        verification_model  = ""
        verification_time   = ""
        last_updated        = $now.ToString("o")
    }
    if ($r.PicUrl) { $sensorAttrs["entity_picture"] = $r.PicUrl }

    Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State $stateText -Attributes $sensorAttrs

    # Store for second pass
    $cameraFirstPass[$camName] = @{
        Data       = $data
        StateText  = $stateText
        CamIndex   = $camIndex
        ImageBytes = $r.ImageBytes
        Attrs      = $sensorAttrs
    }
    $cameraImageUrls[$camName] = "/local/farm_cam${camIndex}_latest.jpg"

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

    # Aggregate rain from first pass (rain skips Pro verification)
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
# Second pass: Gemini Pro verification (security detections only)
# Rain skips verification — alerts fire directly from Flash.
# ============================================================

$proTickCalls = 0; $proTickPrompt = 0; $proTickCompletion = 0; $proTickTotal = 0

# Identify cameras needing security verification (humans, vehicles, animals, fire/smoke)
$camerasNeedingVerification = @()
foreach ($camName in $cameraFirstPass.Keys) {
    $d = $cameraFirstPass[$camName].Data
    $needsVerify = ([int]$d.humans.count -gt 0) -or ([int]$d.vehicles.count -gt 0) -or
                   ([int]$d.animals.count -gt 0) -or ($d.fire_smoke.detected -eq $true)
    if ($needsVerify) {
        $camerasNeedingVerification += $camName
    }
}

if ($camerasNeedingVerification.Count -gt 0) {
    Write-Log "Second pass: $($camerasNeedingVerification.Count) camera(s) need Pro verification"

    foreach ($camName in $camerasNeedingVerification) {
        $fp = $cameraFirstPass[$camName]
        $camIndex = $fp.CamIndex

        if (-not $fp.ImageBytes -or $fp.ImageBytes.Count -eq 0) {
            Write-Log "${camName}: No image bytes for Pro verification - using first-pass data" "WARN"
            # Fall back: aggregate from first-pass data
            $d = $fp.Data
            if ([int]$d.humans.count -gt 0) { $totalHumans += [int]$d.humans.count; $humanCameras += $camName }
            if ([int]$d.vehicles.count -gt 0) { $totalVehicles += [int]$d.vehicles.count; $vehicleCameras += $camName }
            if ([int]$d.animals.count -gt 0) { $totalAnimals += [int]$d.animals.count; if ($d.animals.types) { $animalTypes += [string]$d.animals.types } }
            if ($d.fire_smoke.detected -eq $true) {
                $fireDetected = $true; $fireCameras += $camName
                $severityOrder = @{ "none" = 0; "low" = 1; "medium" = 2; "high" = 3 }
                $currentSev = if ($d.fire_smoke.severity) { [string]$d.fire_smoke.severity } else { "low" }
                if ($severityOrder[$currentSev] -gt $severityOrder[$fireSeverity]) { $fireSeverity = $currentSev; $fireDistance = [string]$d.fire_smoke.estimated_distance }
            }
            continue
        }

        Write-Log "${camName}: Running Pro verification..."
        $proResult = Invoke-GeminiProVerification -CameraName $camName -ImageBytes $fp.ImageBytes -FirstPassData $fp.Data

        # Track Pro tokens
        if ($proResult.TotalTokens -gt 0) {
            $proTickCalls++
            $proTickPrompt     += $proResult.PromptTokens
            $proTickCompletion += $proResult.CompletionTokens
            $proTickTotal      += $proResult.TotalTokens
        }

        if ($proResult.Error) {
            Write-Log "${camName}: Pro verification error: $($proResult.Error) — falling back to Flash data" "WARN"
            # Fallback: use first-pass data for aggregation (better to false-alarm than miss)
            $d = $fp.Data
            if ([int]$d.humans.count -gt 0) { $totalHumans += [int]$d.humans.count; $humanCameras += $camName }
            if ([int]$d.vehicles.count -gt 0) { $totalVehicles += [int]$d.vehicles.count; $vehicleCameras += $camName }
            if ([int]$d.animals.count -gt 0) { $totalAnimals += [int]$d.animals.count; if ($d.animals.types) { $animalTypes += [string]$d.animals.types } }
            if ($d.fire_smoke.detected -eq $true) {
                $fireDetected = $true; $fireCameras += $camName
                $severityOrder = @{ "none" = 0; "low" = 1; "medium" = 2; "high" = 3 }
                $currentSev = if ($d.fire_smoke.severity) { [string]$d.fire_smoke.severity } else { "low" }
                if ($severityOrder[$currentSev] -gt $severityOrder[$fireSeverity]) { $fireSeverity = $currentSev; $fireDistance = [string]$d.fire_smoke.estimated_distance }
            }
            # Update sensor with unverified status
            $fp.Attrs["verified_status"]     = "unverified"
            $fp.Attrs["verification_detail"] = "Pro model error: $($proResult.Error)"
            $fp.Attrs["verification_model"]  = $geminiProModel
            $fp.Attrs["verification_time"]   = (Get-Date).ToString("o")
            Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State $fp.StateText -Attributes $fp.Attrs
        } elseif ($proResult.Confirmed) {
            Write-Log "${camName}: CONFIRMED by Pro — $($proResult.Description)"
            $conf = $proResult.Confidence
            # Aggregate from Pro-verified counts
            if ($conf.humans.confirmed -eq $true) { $totalHumans += [int]$conf.humans.count; $humanCameras += $camName }
            if ($conf.vehicles.confirmed -eq $true) { $totalVehicles += [int]$conf.vehicles.count; $vehicleCameras += $camName }
            if ($conf.animals.confirmed -eq $true) {
                $totalAnimals += [int]$conf.animals.count
                if ($conf.animals.detail) { $animalTypes += [string]$conf.animals.detail }
            }
            if ($conf.fire_smoke.confirmed -eq $true) {
                $fireDetected = $true; $fireCameras += $camName
                $severityOrder = @{ "none" = 0; "low" = 1; "medium" = 2; "high" = 3 }
                $currentSev = if ($fp.Data.fire_smoke.severity) { [string]$fp.Data.fire_smoke.severity } else { "low" }
                if ($severityOrder[$currentSev] -gt $severityOrder[$fireSeverity]) { $fireSeverity = $currentSev; $fireDistance = [string]$fp.Data.fire_smoke.estimated_distance }
            }
            # Update sensor with confirmed status + Pro description
            $fp.Attrs["verified_status"]     = "confirmed"
            $fp.Attrs["verification_detail"] = [string]$proResult.Description
            $fp.Attrs["verification_model"]  = $geminiProModel
            $fp.Attrs["verification_time"]   = (Get-Date).ToString("o")
            Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State $fp.StateText -Attributes $fp.Attrs
        } else {
            Write-Log "${camName}: REJECTED by Pro (false positive) — $($proResult.Description)"
            # Don't aggregate security detections — this was a false positive
            # Update sensor with false_positive status
            $fp.Attrs["verified_status"]     = "false_positive"
            $fp.Attrs["verification_detail"] = [string]$proResult.Description
            $fp.Attrs["verification_model"]  = $geminiProModel
            $fp.Attrs["verification_time"]   = (Get-Date).ToString("o")
            Update-HaSensor -EntityId "sensor.farm_cam_${camIndex}_status" -State $fp.StateText -Attributes $fp.Attrs
        }
    }
} else {
    # No security detections — aggregate everything from first pass (rain already handled above)
    foreach ($camName in $cameraFirstPass.Keys) {
        $d = $cameraFirstPass[$camName].Data
        if ([int]$d.humans.count -gt 0) { $totalHumans += [int]$d.humans.count; $humanCameras += $camName }
        if ([int]$d.vehicles.count -gt 0) { $totalVehicles += [int]$d.vehicles.count; $vehicleCameras += $camName }
        if ([int]$d.animals.count -gt 0) { $totalAnimals += [int]$d.animals.count; if ($d.animals.types) { $animalTypes += [string]$d.animals.types } }
        if ($d.fire_smoke.detected -eq $true) {
            $fireDetected = $true; $fireCameras += $camName
            $severityOrder = @{ "none" = 0; "low" = 1; "medium" = 2; "high" = 3 }
            $currentSev = if ($d.fire_smoke.severity) { [string]$d.fire_smoke.severity } else { "low" }
            if ($severityOrder[$currentSev] -gt $severityOrder[$fireSeverity]) { $fireSeverity = $currentSev; $fireDistance = [string]$d.fire_smoke.estimated_distance }
        }
    }
}

# Track Pro token usage
if ($proTickCalls -gt 0) {
    Write-Log "Gemini Pro tokens this run: $proTickCalls calls, $proTickPrompt prompt, $proTickCompletion completion, $proTickTotal total"
    Update-GeminiTokenStats -Source "ezviz_vision_pro" -Calls $proTickCalls -PromptTokens $proTickPrompt -CompletionTokens $proTickCompletion -TotalTokens $proTickTotal
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
# Alerts — verified detections + rain (TTS + phone with images, throttled)
# Security alerts only fire after Pro verification (or on Pro failure fallback).
# Rain alerts fire directly from Flash results (no Pro needed).
# ============================================================

if ($fireDetected) {
    $alertKey = "Farm_fire_smoke"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        $distNote = if ($fireDistance) { " It appears to be $fireDistance." } else { "" }
        $fireImage = if ($fireCameras.Count -gt 0) { $cameraImageUrls[$fireCameras[0]] } else { $null }
        Send-Alert -AlertKey $alertKey -Message "Warning! Fire or smoke detected at the farm. Severity: $fireSeverity.$distNote Cameras: $($fireCameras -join ', ')." -ImageUrl $fireImage
        Set-AlertTime -Key $alertKey
    }
}

if ($totalHumans -gt 0) {
    $alertKey = "Farm_human"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        $humanImage = if ($humanCameras.Count -gt 0) { $cameraImageUrls[$humanCameras[0]] } else { $null }
        Send-Alert -AlertKey $alertKey -Message "Farm alert. $totalHumans person or people detected at: $($humanCameras -join ', ')." -ImageUrl $humanImage
        Set-AlertTime -Key $alertKey
    }
}

if ($totalVehicles -gt 0) {
    $alertKey = "Farm_vehicle"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        $vehicleImage = if ($vehicleCameras.Count -gt 0) { $cameraImageUrls[$vehicleCameras[0]] } else { $null }
        Send-Alert -AlertKey $alertKey -Message "Farm alert. $totalVehicles vehicle or vehicles detected at: $($vehicleCameras -join ', ')." -ImageUrl $vehicleImage
        Set-AlertTime -Key $alertKey
    }
}

if ($totalAnimals -gt 0) {
    $alertKey = "Farm_animal"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        # Find first camera with animal detection for image
        $animalImage = $null
        foreach ($cn in $cameraFirstPass.Keys) {
            if ([int]$cameraFirstPass[$cn].Data.animals.count -gt 0 -and $cameraImageUrls[$cn]) { $animalImage = $cameraImageUrls[$cn]; break }
        }
        Send-Alert -AlertKey $alertKey -Message "Farm alert. $totalAnimals animal or animals detected: $($animalTypes -join ', ')." -ImageUrl $animalImage
        Set-AlertTime -Key $alertKey
    }
}

if ($rainDetected) {
    $alertKey = "Farm_rain"
    $cd = $alertConfig[$alertKey].Cooldown
    if (-not (Test-AlertThrottled -Key $alertKey -MinutesCooldown $cd)) {
        # Find first camera with rain detection for image
        $rainImage = $null
        foreach ($cn in $cameraFirstPass.Keys) {
            if ($cameraFirstPass[$cn].Data.rain.detected -eq $true -and $cameraImageUrls[$cn]) { $rainImage = $cameraImageUrls[$cn]; break }
        }
        Send-Alert -AlertKey $alertKey -Message "Farm weather alert. Rain detected at the farm. Intensity: $rainIntensity." -ImageUrl $rainImage
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
