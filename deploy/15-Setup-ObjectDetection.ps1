<#
.SYNOPSIS
    Deploy CameraObjectDetection pipeline to host server with HA integration.

.DESCRIPTION
    - Copies CameraObjectDetection folder to server Desktop
    - Creates HA-CameraObjectDetection scheduled task (runs supervisor.py at startup)
    - Creates HA sensors for street camera detection metrics
    - Creates "Street Stats" dashboard in Home Assistant via WebSocket API
    - Sets HA_TOKEN environment variable for the scheduled task

.EXAMPLE
    .\15-Setup-ObjectDetection.ps1
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

# ============================================================
# Server details
# ============================================================

$serverName = "DESKTOP-HG724B5"
$serverUser = "DESKTOP-HG724B5\hadeploy"
$serverPass = 'T3rrabyte!'
$serverCred = New-Object System.Management.Automation.PSCredential($serverUser, (ConvertTo-SecureString $serverPass -AsPlainText -Force))

$localSrcDir = Join-Path (Split-Path $scriptDir -Parent) "CameraObjectDetection"
$remoteDestDir = "C:\Users\hadeploy\Desktop\CameraObjectDetection"

# ============================================================
# STEP 1: Copy files to server
# ============================================================

Write-Step "1/7 - Copying CameraObjectDetection to server"

$filesToCopy = @(
    "config.py",
    "supervisor.py",
    "ha_metrics.py",
    "SampleImages.py",
    "DetectObjects3.py",
    "ProcessCropFiles.py",
    "alerts.py",
    "gemini_verify.py",
    "plate_registry.json",
    "run.bat",
    "requirements.txt"
)

# Read all files locally, send to server in one Invoke-Command
$fileContents = @{}
foreach ($f in $filesToCopy) {
    $path = Join-Path $localSrcDir $f
    if (Test-Path $path) {
        $fileContents[$f] = [System.IO.File]::ReadAllText($path)
        Write-Info "Read: $f"
    } else {
        Write-Fail "Missing: $path"
        exit 1
    }
}

Invoke-Command -ComputerName $serverName -Credential $serverCred -ArgumentList $remoteDestDir, $fileContents, $Config.HA_TOKEN, $Config.GeminiApiKey -ScriptBlock {
    param($destDir, $files, $haToken, $geminiKey)

    # Create destination directory
    if (-not (Test-Path $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }

    # Create logs subdirectory
    $logsDir = Join-Path $destDir "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }

    # Write each file
    foreach ($name in $files.Keys) {
        $filePath = Join-Path $destDir $name
        [System.IO.File]::WriteAllText($filePath, $files[$name])
    }

    # Patch config.py with HA_TOKEN and GEMINI_API_KEY on the server
    $configPath = Join-Path $destDir "config.py"
    $content = [System.IO.File]::ReadAllText($configPath)
    $content = $content -replace 'HA_TOKEN\s*=\s*""', "HA_TOKEN = `"$haToken`""
    $content = $content -replace 'GEMINI_API_KEY\s*=\s*""', "GEMINI_API_KEY = `"$geminiKey`""
    [System.IO.File]::WriteAllText($configPath, $content)

    # Create wrapper bat that establishes Samba connection before running supervisor
    # SYSTEM user needs net use to access \\192.168.0.239\config\www for image gallery
    $wrapperPath = Join-Path $destDir "start_supervisor.bat"
    $wrapperContent = "@echo off`r`nnet use \\192.168.0.239\config /user:homeassistant terrabyte /persistent:no 2>nul`r`nC:\Python311\python.exe `"%~dp0supervisor.py`""
    [System.IO.File]::WriteAllText($wrapperPath, $wrapperContent)
}

Write-Success "Files copied to $serverName`:$remoteDestDir"

# ============================================================
# STEP 2: Create scheduled task on server
# ============================================================

Write-Step "2/7 - Installing Python dependencies on server"

Invoke-Command -ComputerName $serverName -Credential $serverCred -ArgumentList $remoteDestDir -ScriptBlock {
    param($destDir)
    $python = "C:\Python311\python.exe"
    $reqPath = Join-Path $destDir "requirements.txt"
    & $python -m pip install -r $reqPath --quiet 2>&1 | Out-Null
}

Write-Success "Python dependencies installed (including deep-sort-realtime)"

# ============================================================
# STEP 3: Ensure HA www dir exists via Samba
# ============================================================

Write-Step "3/7 - Ensuring HA www directory exists"

$sambaWww = "\\192.168.0.239\config\www"
if (-not (Test-Path $sambaWww)) {
    try {
        New-Item -Path $sambaWww -ItemType Directory -Force | Out-Null
        Write-Success "Created $sambaWww"
    } catch {
        Write-Info "Could not create $sambaWww (may need Samba credentials): $($_.Exception.Message)"
    }
} else {
    Write-Success "$sambaWww already exists"
}

# ============================================================
# STEP 4: Create scheduled task on server
# ============================================================

Write-Step "4/7 - Creating HA-CameraObjectDetection scheduled task"

Invoke-Command -ComputerName $serverName -Credential $serverCred -ArgumentList $remoteDestDir -ScriptBlock {
    param($destDir)

    $taskName = "HA-CameraObjectDetection"

    # Remove existing task if present
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    # Use wrapper bat that connects Samba before running supervisor
    $wrapperPath = Join-Path $destDir "start_supervisor.bat"
    $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$wrapperPath`"" -WorkingDirectory $destDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Camera Object Detection pipeline supervisor - monitors and restarts SampleImages, DetectObjects3, ProcessCropFiles" -Force
}

Write-Success "HA-CameraObjectDetection scheduled task created (runs at startup as SYSTEM)"

# ============================================================
# STEP 3: Create HA sensors
# ============================================================

Write-Step "5/7 - Creating HA sensors for street camera metrics"

$sensors = @(
    # Original detection metrics
    @{ entity_id = "sensor.street_cam_detections_today"; state = "0";       attributes = @{ friendly_name = "Street Cam Detections Today"; icon = "mdi:cctv";           unit_of_measurement = "detections"; by_type = @{}; hourly = @{} } }
    @{ entity_id = "sensor.street_cam_people_today";     state = "0";       attributes = @{ friendly_name = "Street Cam People Today";     icon = "mdi:walk";           unit_of_measurement = "people" } }
    @{ entity_id = "sensor.street_cam_vehicles_today";   state = "0";       attributes = @{ friendly_name = "Street Cam Vehicles Today";   icon = "mdi:car";            unit_of_measurement = "vehicles" } }
    @{ entity_id = "sensor.street_cam_last_detection";   state = "unknown"; attributes = @{ friendly_name = "Street Cam Last Detection";   icon = "mdi:clock-outline"  } }
    @{ entity_id = "sensor.street_cam_last_object";      state = "none";    attributes = @{ friendly_name = "Street Cam Last Object";      icon = "mdi:shape"          } }
    @{ entity_id = "sensor.street_cam_status";           state = "offline"; attributes = @{ friendly_name = "Street Cam Detection Status"; icon = "mdi:alert-circle"   } }

    # Plate registry sensors
    @{ entity_id = "sensor.street_cam_last_plate";           state = "none"; attributes = @{ friendly_name = "Street Cam Last Plate";           icon = "mdi:car-info";      owner = "Unknown"; known = $false } }
    @{ entity_id = "sensor.street_cam_known_plates_today"; state = "0"; attributes = @{ friendly_name = "Street Cam Known Plates Today"; icon = "mdi:car-multiple"; unit_of_measurement = "sightings"; plates = @() } }

    # Image gallery sensors (person 1-5)
    @{ entity_id = "sensor.street_cam_person_1";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 1";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_2";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 2";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_3";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 3";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_4";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 4";  icon = "mdi:walk" } }
    @{ entity_id = "sensor.street_cam_person_5";  state = "empty"; attributes = @{ friendly_name = "Street Cam Person 5";  icon = "mdi:walk" } }

    # Image gallery sensors (vehicle 1-5)
    @{ entity_id = "sensor.street_cam_vehicle_1"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 1"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_2"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 2"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_3"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 3"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_4"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 4"; icon = "mdi:car" } }
    @{ entity_id = "sensor.street_cam_vehicle_5"; state = "empty"; attributes = @{ friendly_name = "Street Cam Vehicle 5"; icon = "mdi:car" } }

    # Loitering detection sensor
    @{ entity_id = "sensor.street_cam_loitering"; state = "clear"; attributes = @{ friendly_name = "Street Cam Loitering"; icon = "mdi:account-clock"; object_type = $null; track_id = $null; duration_seconds = 0 } }

    # Loitering verification counters
    @{ entity_id = "sensor.street_cam_unconfirmed_loitering_today"; state = "0"; attributes = @{ friendly_name = "Street Cam Unconfirmed Loitering Today"; icon = "mdi:account-question"; unit_of_measurement = "detections" } }
    @{ entity_id = "sensor.street_cam_confirmed_loitering_today";   state = "0"; attributes = @{ friendly_name = "Street Cam Confirmed Loitering Today";   icon = "mdi:account-check";    unit_of_measurement = "detections" } }
    @{ entity_id = "sensor.street_cam_false_loitering_today";       state = "0"; attributes = @{ friendly_name = "Street Cam False Loitering Today";       icon = "mdi:account-cancel";   unit_of_measurement = "detections" } }
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
# STEP 4: Create Street Stats dashboard via WebSocket
# ============================================================

Write-Step "6/7 - Creating Street Stats dashboard"

# --- WebSocket helpers (same as other deploy scripts) ---
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

Connect-HAWS

# Check if dashboard already exists
$dashList = Invoke-WSCommand -Type "lovelace/dashboards/list"
$existingDash = $dashList.result | Where-Object { $_.url_path -eq "street-stats" }

if (-not $existingDash) {
    Write-Info "Creating street-stats dashboard..."
    $createResp = Invoke-WSCommand -Type "lovelace/dashboards/create" -Extra @{
        url_path        = "street-stats"
        title           = "Street Stats"
        icon            = "mdi:cctv"
        require_admin   = $false
        show_in_sidebar = $true
    }
    if ($createResp.success) {
        Write-Success "Street Stats dashboard created"
    } else {
        Write-Fail "Failed to create dashboard: $($createResp.error.message)"
    }
} else {
    Write-Info "Street Stats dashboard already exists - updating config"
}

# Build dashboard config
$dashboardConfig = @{
    views = @(
        @{
            title = "Street Camera"
            path  = "street-camera"
            icon  = "mdi:cctv"
            cards = @(
                # Status header
                @{
                    type  = "custom:mushroom-template-card"
                    primary    = "Street Camera Object Detection"
                    icon       = "mdi:cctv"
                    icon_color = "blue"
                    secondary  = "Status: {{ states('sensor.street_cam_status') }}"
                }
                # Detection summary
                @{
                    type  = "vertical-stack"
                    title = "Detection Summary (Today)"
                    cards = @(
                        @{
                            type     = "glance"
                            entities = @(
                                @{ entity = "sensor.street_cam_detections_today"; name = "Total" }
                                @{ entity = "sensor.street_cam_people_today";     name = "People" }
                                @{ entity = "sensor.street_cam_vehicles_today";   name = "Vehicles" }
                            )
                        }
                        @{
                            type    = "markdown"
                            title   = "Detections by Type"
                            content = @"
{% set by_type = state_attr('sensor.street_cam_detections_today', 'by_type') %}
{% if by_type %}
| Object | Count |
|--------|-------|
{% for obj, count in by_type.items() %}| {{ obj }} | {{ count }} |
{% endfor %}{% else %}
No detections yet today.
{% endif %}
"@
                        }
                    )
                }
                # Loitering detection (always visible)
                @{
                    type  = "vertical-stack"
                    title = "Loitering Detection"
                    cards = @(
                        @{
                            type    = "markdown"
                            content = @"
{% if states('sensor.street_cam_loitering') == 'alert' %}**Loitering Detected** - {{ state_attr('sensor.street_cam_loitering', 'object_type') }} for {{ state_attr('sensor.street_cam_loitering', 'duration_seconds') }}s
Track {{ state_attr('sensor.street_cam_loitering', 'track_id') }} | {{ state_attr('sensor.street_cam_loitering', 'detected_at')[:19] }}{% else %}No active loitering.{% if state_attr('sensor.street_cam_loitering', 'detected_at') %}
*Last: {{ state_attr('sensor.street_cam_loitering', 'object_type') }} - {{ state_attr('sensor.street_cam_loitering', 'detected_at')[:19] }} ({{ state_attr('sensor.street_cam_loitering', 'duration_seconds') }}s)*{% endif %}{% endif %}
"@
                        }
                        @{
                            type  = "horizontal-stack"
                            cards = @(
                                @{
                                    type    = "markdown"
                                    title   = "First Seen"
                                    content = "{% if state_attr('sensor.street_cam_loitering', 'image_first') %}<a href='{{ state_attr(""sensor.street_cam_loitering"", ""image_first"") }}' target='_blank'><img src='{{ state_attr(""sensor.street_cam_loitering"", ""image_first"") }}?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:8px;cursor:pointer;' /></a>{% else %}No image yet{% endif %}"
                                }
                                @{
                                    type    = "markdown"
                                    title   = "Last Seen"
                                    content = "{% if state_attr('sensor.street_cam_loitering', 'image_last') %}<a href='{{ state_attr(""sensor.street_cam_loitering"", ""image_last"") }}' target='_blank'><img src='{{ state_attr(""sensor.street_cam_loitering"", ""image_last"") }}?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:8px;cursor:pointer;' /></a>{% else %}No image yet{% endif %}"
                                }
                            )
                        }
                        @{
                            type     = "glance"
                            title    = "Loitering Verification (Today)"
                            entities = @(
                                @{ entity = "sensor.street_cam_unconfirmed_loitering_today"; name = "Unconfirmed" }
                                @{ entity = "sensor.street_cam_confirmed_loitering_today";   name = "Confirmed" }
                                @{ entity = "sensor.street_cam_false_loitering_today";       name = "Rejected" }
                            )
                        }
                    )
                }
                # License plate info
                @{
                    type  = "vertical-stack"
                    title = "License Plates"
                    cards = @(
                        @{
                            type     = "glance"
                            entities = @(
                                @{ entity = "sensor.street_cam_last_plate";          name = "Last Plate" }
                                @{ entity = "sensor.street_cam_known_plates_today";  name = "Known Today" }
                            )
                        }
                        @{
                            type    = "markdown"
                            title   = "Last Plate Details"
                            content = @"
{% set plate = states('sensor.street_cam_last_plate') %}
{% if plate and plate != 'none' %}
- **Plate**: {{ plate }}
- **Owner**: {{ state_attr('sensor.street_cam_last_plate', 'owner') }}
- **Known**: {{ state_attr('sensor.street_cam_last_plate', 'known') }}
- **Time**: {{ state_attr('sensor.street_cam_last_plate', 'time') }}
{% else %}
No plates detected yet.
{% endif %}
"@
                        }
                        @{
                            type    = "markdown"
                            title   = "Last Known Plate Image"
                            content = @"
{% if state_attr('sensor.street_cam_last_plate', 'known') == true and state_attr('sensor.street_cam_last_plate', 'entity_picture') %}
<img src="{{ state_attr('sensor.street_cam_last_plate', 'entity_picture') }}?t={{ now().timestamp() | int }}" style="max-width:100%;border-radius:8px;" />
**{{ state_attr('sensor.street_cam_last_plate', 'owner') }}** - {{ states('sensor.street_cam_last_plate') }}
{% else %}
No known plate image yet.
{% endif %}
"@
                        }
                        @{
                            type    = "markdown"
                            title   = "Known Plates Today"
                            content = @"
{% set plates = state_attr('sensor.street_cam_known_plates_today', 'plates') %}
{% if plates and plates | length > 0 %}
| Plate | Owner | Count | Last Seen |
|-------|-------|-------|-----------|
{% for p in plates %}| {{ p.plate }} | {{ p.owner }} | {{ p.count }} | {{ p.last_seen[:19] }} |
{% endfor %}{% else %}
No known plates seen today.
{% endif %}
"@
                        }
                    )
                }
                # Recent people gallery
                @{
                    type  = "vertical-stack"
                    title = "Recent People (Last 5)"
                    cards = @(
                        @{
                            type  = "horizontal-stack"
                            cards = @(
                                @{ type = "markdown"; content = "<a href='/local/street_person_1.jpg' target='_blank'><img src='/local/street_person_1.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_person_2.jpg' target='_blank'><img src='/local/street_person_2.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_person_3.jpg' target='_blank'><img src='/local/street_person_3.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_person_4.jpg' target='_blank'><img src='/local/street_person_4.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_person_5.jpg' target='_blank'><img src='/local/street_person_5.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                            )
                        }
                    )
                }
                # Recent vehicles gallery
                @{
                    type  = "vertical-stack"
                    title = "Recent Vehicles (Last 5)"
                    cards = @(
                        @{
                            type  = "horizontal-stack"
                            cards = @(
                                @{ type = "markdown"; content = "<a href='/local/street_vehicle_1.jpg' target='_blank'><img src='/local/street_vehicle_1.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_vehicle_2.jpg' target='_blank'><img src='/local/street_vehicle_2.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_vehicle_3.jpg' target='_blank'><img src='/local/street_vehicle_3.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_vehicle_4.jpg' target='_blank'><img src='/local/street_vehicle_4.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                                @{ type = "markdown"; content = "<a href='/local/street_vehicle_5.jpg' target='_blank'><img src='/local/street_vehicle_5.jpg?t={{ now().timestamp() | int }}' style='max-width:100%;border-radius:4px;cursor:pointer;' /></a>" }
                            )
                        }
                    )
                }
                # Hourly activity
                @{
                    type     = "history-graph"
                    title    = "Detection Activity"
                    entities = @(
                        @{ entity = "sensor.street_cam_detections_today"; name = "Total" }
                        @{ entity = "sensor.street_cam_people_today";     name = "People" }
                        @{ entity = "sensor.street_cam_vehicles_today";   name = "Vehicles" }
                    )
                    hours_to_show = 24
                }
                # Hourly breakdown as markdown
                @{
                    type    = "markdown"
                    title   = "Hourly Breakdown"
                    content = @"
{% set hourly = state_attr('sensor.street_cam_detections_today', 'hourly') %}
{% if hourly %}
| Hour | Detections |
|------|------------|
{% for h in range(24) %}{% set hh = '%02d' | format(h) %}| {{ hh }}:00 | {{ hourly[hh] | default(0) }} |
{% endfor %}{% else %}
No data yet.
{% endif %}
"@
                }
                # Last detection info
                @{
                    type  = "entities"
                    title = "Last Detection"
                    entities = @(
                        @{ entity = "sensor.street_cam_last_object";    name = "Object Type"   }
                        @{ entity = "sensor.street_cam_last_detection"; name = "Time"           }
                        @{ entity = "sensor.street_cam_status";         name = "Pipeline Status" }
                    )
                }
            )
        }
    )
}

$saveResp = Invoke-WSCommand -Type "lovelace/config/save" -Extra @{
    config   = $dashboardConfig
    url_path = "street-stats"
}

if ($saveResp.success) {
    Write-Success "Street Stats dashboard config saved!"
} else {
    Write-Fail "Save failed: $($saveResp.error.message)"
}

Disconnect-HAWS

# ============================================================
# STEP 5: Add sensors to recreate script
# ============================================================

Write-Step "7/7 - Summary"

Write-Info "Street cam sensors are managed in deploy/11-Recreate-Sensors.ps1"
Write-Info "The ha_metrics.py script also recreates core sensors on each push cycle"

# ============================================================
# Done
# ============================================================

Write-Step "Object Detection Setup Complete!"

Write-Host ""
Write-Host "  Deployed to server:" -ForegroundColor Green
Write-Host "    - Files: $remoteDestDir" -ForegroundColor White
Write-Host "    - Scheduled task: HA-CameraObjectDetection (runs at startup)" -ForegroundColor White
Write-Host "    - Python deps installed (inc. deep-sort-realtime)" -ForegroundColor White
Write-Host ""
Write-Host "  HA sensors (22 total):" -ForegroundColor Green
Write-Host "    - sensor.street_cam_detections_today (total + by_type + hourly attrs)" -ForegroundColor White
Write-Host "    - sensor.street_cam_people_today" -ForegroundColor White
Write-Host "    - sensor.street_cam_vehicles_today" -ForegroundColor White
Write-Host "    - sensor.street_cam_last_detection (timestamp)" -ForegroundColor White
Write-Host "    - sensor.street_cam_last_object" -ForegroundColor White
Write-Host "    - sensor.street_cam_status (running/error/offline)" -ForegroundColor White
Write-Host "    - sensor.street_cam_last_plate (plate + owner + known)" -ForegroundColor White
Write-Host "    - sensor.street_cam_known_plates_today (count + plate list)" -ForegroundColor White
Write-Host "    - sensor.street_cam_person_1..5 (image gallery)" -ForegroundColor White
Write-Host "    - sensor.street_cam_vehicle_1..5 (image gallery)" -ForegroundColor White
Write-Host "    - sensor.street_cam_loitering (clear/alert/rejected + details)" -ForegroundColor White
Write-Host "    - sensor.street_cam_unconfirmed_loitering_today" -ForegroundColor White
Write-Host "    - sensor.street_cam_confirmed_loitering_today" -ForegroundColor White
Write-Host "    - sensor.street_cam_false_loitering_today" -ForegroundColor White
Write-Host ""
Write-Host "  Dashboard:" -ForegroundColor Green
Write-Host "    - Street Stats: http://$($Config.HA_IP):8123/street-stats" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Start the task: schtasks /run /tn HA-CameraObjectDetection (or reboot)" -ForegroundColor White
Write-Host "    2. Check logs in $remoteDestDir\logs\" -ForegroundColor White
Write-Host "    3. Verify sensors appear in HA Developer Tools > States" -ForegroundColor White
Write-Host "    4. Add known plates to plate_registry.json on the server" -ForegroundColor White
Write-Host ""
