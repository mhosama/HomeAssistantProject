<#
.SYNOPSIS
    Capture snapshots from all 8 cameras, analyze with Gemini Flash, update HA sensors and fire alerts.

.DESCRIPTION
    Runs every 60 seconds via Windows Scheduled Task (HA-VisionAnalysis).
    - Captures JPEG snapshots from 8 cameras via HA camera_proxy API
    - Sends each to Gemini 2.0 Flash for structured JSON analysis
    - Updates HA sensors (chicken count, gate status, food descriptions, car counts)
    - Fires TTS alerts for intruders (8PM-6AM) and turns off lights (after midnight)
    - Uses mutex to prevent overlapping runs
    - Each camera runs in its own runspace for parallel execution

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

Write-Log "=== Vision analysis run starting ==="

# ============================================================
# Time context
# ============================================================

$now = Get-Date
$hour = $now.Hour

$isNightSecurity = ($hour -ge 20) -or ($hour -lt 6)    # 8PM - 6AM
$isAfterMidnight = ($hour -ge 0) -and ($hour -lt 6)    # 12AM - 6AM

# Meal windows
$mealWindow = "none"
if ($hour -ge 6 -and $hour -lt 10)  { $mealWindow = "breakfast" }
if ($hour -ge 11 -and $hour -lt 14) { $mealWindow = "lunch" }
if ($hour -ge 17 -and $hour -lt 21) { $mealWindow = "dinner" }

# ============================================================
# State file (alert throttling + food tracking)
# ============================================================

$defaultState = @{
    last_alerts = @{}
    food_items  = @{
        breakfast = @{ date = ""; items = @(); timestamps = @() }
        lunch    = @{ date = ""; items = @(); timestamps = @() }
        dinner   = @{ date = ""; items = @(); timestamps = @() }
    }
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
    } catch {
        $state = $defaultState | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    }
} else {
    $state = $defaultState | ConvertTo-Json -Depth 5 | ConvertFrom-Json
}

$today = $now.ToString("yyyy-MM-dd")

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
    "DiningRoom_lights"     = @{ TTS = $false; Phone = $false }
    "Kitchen_human"         = @{ TTS = $true;  Phone = $true  }
    "Kitchen_lights"        = @{ TTS = $false; Phone = $false }
    "MainGate_open"         = @{ TTS = $true;  Phone = $true  }
    "VisitorGate_open"      = @{ TTS = $true;  Phone = $true  }
    "Lawn_human"            = @{ TTS = $true;  Phone = $true  }
    "Pool_human"            = @{ TTS = $true;  Phone = $true  }
    "Garage_human"          = @{ TTS = $true;  Phone = $true  }
    "Lounge_human"          = @{ TTS = $true;  Phone = $true  }
    "Lounge_lights"         = @{ TTS = $false; Phone = $false }
    "Street_human"          = @{ TTS = $true;  Phone = $true  }
}

$ttsEngine      = "tts.google_translate_en_com"
$kitchenSpeaker = "media_player.kitchen_speaker"
$notifyEntity   = $Config.NotifyEntity

# Light entities for auto-off
$kitchenLights = @("switch.sonoff_1000feaf53_2", "switch.sonoff_1000a21c46")
$diningLights  = @("switch.sonoff_1000feaf53_1", "switch.sonoff_10008cd8c2_2")

# ============================================================
# Camera definitions
# ============================================================

# SD streams for Tapo cameras (faster, lower bandwidth), direct entity for gate cameras
$cameras = @(
    @{
        Name     = "Chickens"
        EntityId = "camera.chickens_sd_stream"
        Type     = "chickens"
    }
    @{
        Name     = "Backyard"
        EntityId = "camera.backyard_camera_sd_stream"
        Type     = "security"
    }
    @{
        Name     = "BackDoor"
        EntityId = "camera.back_door_camera_sd_stream"
        Type     = "security"
    }
    @{
        Name     = "VeggieGarden"
        EntityId = "camera.veggie_garden_sd_stream"
        Type     = "security"
    }
    @{
        Name     = "DiningRoom"
        EntityId = "camera.dining_room_camera_sd_stream"
        Type     = "indoor"
    }
    @{
        Name     = "Kitchen"
        EntityId = "camera.kitchen_camera_sd_stream"
        Type     = "kitchen"
    }
    @{
        Name     = "MainGate"
        EntityId = "camera.main_gate_camera"
        Type     = "gate"
    }
    @{
        Name     = "VisitorGate"
        EntityId = "camera.visitor_gate_camera"
        Type     = "gate"
    }
    @{
        Name     = "Lawn"
        EntityId = "camera.lawn_camera_sd_stream"
        Type     = "security"
    }
    @{
        Name     = "Pool"
        EntityId = "camera.pool_camera"
        Type     = "security"
    }
    @{
        Name     = "Garage"
        EntityId = "camera.garage_camera"
        Type     = "security"
    }
    @{
        Name     = "Lounge"
        EntityId = "camera.lounge_camera"
        Type     = "indoor"
    }
    @{
        Name     = "Street"
        EntityId = "camera.street_camera"
        Type     = "security"
    }
)

# ============================================================
# Build prompts per camera type
# ============================================================

function Get-CameraPrompt {
    param([hashtable]$Camera)

    $nightNote = "This image may be night-vision (grayscale/infrared). Analyze accordingly."

    switch ($Camera.Name) {
        "Chickens" {
            return @"
This is an indoor camera inside a small chicken nesting box. The camera looks down at chickens sleeping on straw/hay bedding. Count every individual chicken you can see, including partially hidden ones. Chickens may be dark-feathered or light-feathered and may overlap.
$nightNote
Respond with ONLY this JSON:
{"chicken_count": <integer>, "chickens_visible": <true/false>, "description": "<brief description>"}
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
This is an indoor camera in a combined dining/living room. The scene typically shows a dining table, chairs, a TV/screen on one wall, a sofa, and kitchen cabinets in the background. Look for any HUMAN figures - someone sitting at the table, on the sofa, standing, or walking through. Check if indoor lights are on (room appears brightly lit with warm/artificial lighting) or off (room appears dark, only TV glow). A TV that is on does NOT count as lights being on - only overhead or room lights count.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "lights_on": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Kitchen" {
            $base = @"
This is an indoor camera in a kitchen, mounted high looking down at the room. The scene shows a kitchen counter/island in the center, wooden cabinets, a sink area, a stove, and a dining table with chairs in the lower portion of the frame. Look carefully for any HUMAN figures - someone sitting at the table, standing at the counter, or anywhere in the room. People may be partially occluded by furniture. Check if indoor lights are on (room brightly lit with warm lighting) or off (dark).
$nightNote
"@
            if ($script:mealWindow -ne "none") {
                $base += @"

Also look at the counter and dining table for PREPARED FOOD (plates of food, bowls, sandwiches, cooked meals). Do not count raw ingredients, empty plates, or cooking equipment as food. If prepared food is visible, describe each distinct food item concisely in 2-5 words (e.g. 'toast and eggs', 'chicken stir fry', 'cereal with milk'). Be consistent - use the same description for the same food across different images.
Respond with ONLY this JSON:
{"human_detected": <true/false>, "lights_on": <true/false>, "confidence": "<high/medium/low>", "food_visible": <true/false>, "food_description": "<brief 2-5 word food description or empty string>", "description": "<brief description>"}
"@
            } else {
                $base += @"

Respond with ONLY this JSON:
{"human_detected": <true/false>, "lights_on": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
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
This is an outdoor security camera overlooking a swimming pool area at a residential property. The scene normally shows a pool, pool deck, outdoor furniture, and surrounding fencing or walls. Look carefully for any HUMAN figures - a person swimming, sitting by the pool, standing, walking, or moving anywhere in the frame. Check for any signs of someone in the water (especially important for safety). Do NOT confuse pool equipment, reflections on water, or furniture for humans.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "person_in_pool": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Garage" {
            return @"
This is a security camera inside or overlooking a garage area. The scene normally shows vehicles, tools, storage items, and garage doors. Look carefully for any HUMAN figures - a person standing, walking, crouching, or moving anywhere in the frame. Do NOT confuse storage items, tools, or vehicle shapes for humans. Only report human_detected=true if you can clearly identify a human body shape.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Lounge" {
            return @"
This is an indoor camera in a lounge/living room area. The scene typically shows a sofa, TV, coffee table, and other living room furniture. Look for any HUMAN figures - someone sitting on the sofa, standing, or walking through. Check if indoor lights are on (room appears brightly lit with warm/artificial lighting) or off (room appears dark, only TV glow). A TV that is on does NOT count as lights being on - only overhead or room lights count.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "lights_on": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
        "Street" {
            return @"
This is an outdoor security camera facing the street outside a residential property. The scene normally shows the road, pavement/sidewalk, parked cars, and possibly neighbouring houses or fences. Look carefully for any HUMAN figures - a person walking, standing, or loitering on the street or pavement near the property. Also note any vehicles that appear to be stopped or parked suspiciously close to the property. Do NOT confuse street furniture (bins, poles, post boxes) or parked cars for humans.
$nightNote
Respond with ONLY this JSON:
{"human_detected": <true/false>, "vehicle_detected": <true/false>, "confidence": "<high/medium/low>", "description": "<brief description>"}
"@
        }
    }
}

# ============================================================
# Parallel execution: capture snapshot + call Gemini per camera
# ============================================================

Write-Log "Processing $($cameras.Count) cameras (night=$isNightSecurity, meal=$mealWindow)"

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
        Camera  = $CameraName
        Success = $false
        Data    = $null
        Error   = $null
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

# Create runspace pool
$pool = [RunspaceFactory]::CreateRunspacePool(1, 8)
$pool.Open()

$jobs = @()

foreach ($cam in $cameras) {
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

# Wait for all jobs to complete (max 60 seconds total)
$deadline = (Get-Date).AddSeconds(60)
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
    param([string]$Message, [string]$Title = "Vision AI Alert")
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

function Switch-Off {
    param([string[]]$Entities)
    foreach ($eid in $Entities) {
        $body = @{ entity_id = $eid } | ConvertTo-Json
        try {
            $null = Invoke-WebRequest -Uri "$haBase/api/services/switch/turn_off" -Method POST -Headers $haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing -TimeoutSec 10
            Write-Log "Turned off: $eid"
        } catch {
            Write-Log "Failed to turn off $eid : $($_.Exception.Message)" "ERROR"
        }
    }
}

foreach ($r in $results) {
    if (-not $r.Success) {
        Write-Log "$($r.Camera): FAILED - $($r.Error)" "ERROR"
        continue
    }

    $cam = $r.Camera
    $data = $r.Data
    Write-Log "${cam}: $($data | ConvertTo-Json -Compress)"

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
        }

        "Backyard" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Backyard_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the backyard."
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "BackDoor" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "BackDoor_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected at the back door."
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "VeggieGarden" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "VeggieGarden_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the veggie garden."
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "DiningRoom" {
            # Indoor security alert (12AM-6AM only)
            if ($isAfterMidnight -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "DiningRoom_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the dining room."
                    Set-AlertTime -Key $alertKey
                }
            }

            # Auto lights off after midnight if no human
            if ($isAfterMidnight -and $data.lights_on -eq $true -and $data.human_detected -eq $false) {
                $alertKey = "DiningRoom_lights"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Write-Log "Turning off dining room lights (after midnight, no human detected)"
                    Switch-Off -Entities $diningLights
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Kitchen" {
            # Indoor security alert (12AM-6AM only)
            if ($isAfterMidnight -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Kitchen_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the kitchen."
                    Set-AlertTime -Key $alertKey
                }
            }

            # Auto lights off after midnight if no human
            if ($isAfterMidnight -and $data.lights_on -eq $true -and $data.human_detected -eq $false) {
                $alertKey = "Kitchen_lights"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Write-Log "Turning off kitchen lights (after midnight, no human detected)"
                    Switch-Off -Entities $kitchenLights
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
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected on the lawn."
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Pool" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Pool_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected at the pool area."
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Garage" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Garage_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the garage."
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Lounge" {
            # Indoor security alert (12AM-6AM only)
            if ($isAfterMidnight -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Lounge_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected in the lounge."
                    Set-AlertTime -Key $alertKey
                }
            }

            # Auto lights off after midnight if no human
            if ($isAfterMidnight -and $data.lights_on -eq $true -and $data.human_detected -eq $false) {
                $alertKey = "Lounge_lights"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Write-Log "Lounge lights on after midnight with no human detected (no auto-off entities configured yet)"
                    Set-AlertTime -Key $alertKey
                }
            }
        }

        "Street" {
            if ($isNightSecurity -and $data.human_detected -eq $true -and $data.confidence -ne "low") {
                $alertKey = "Street_human"
                if (-not (Test-AlertThrottled -Key $alertKey)) {
                    Send-Alert -AlertKey $alertKey -Message "Security alert. A person has been detected on the street outside the property."
                    Set-AlertTime -Key $alertKey
                }
            }
        }
    }
}

# ============================================================
# Save state
# ============================================================

$state | Add-Member -NotePropertyName "last_run" -NotePropertyValue $now.ToString("o") -Force
$state | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8

$successCount = ($results | Where-Object { $_.Success }).Count
Write-Log "=== Run complete: $successCount/$($cameras.Count) cameras processed ==="

# end of mutex try block
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
