<#
.SYNOPSIS
    Execute energy schedule - switch devices on/off based on hourly plan.

.DESCRIPTION
    Runs every 5 minutes via Windows Scheduled Task (HA-RunEnergySchedule).
    1. Reads sensor.energy_schedule for today's hourly plan
    2. Checks input_boolean.energy_schedule_active (master kill switch)
    3. Compares expected vs actual device states for current hour
    4. Switches devices on/off as needed (respects manual overrides)
    5. Sends TTS + phone notification for each switch event
    6. Logs events to sensor.energy_schedule_log

.EXAMPLE
    .\18b-Run-EnergySchedule.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# Configuration
# ============================================================

$haBase  = "http://$($Config.HA_IP):8123"
$haToken = $Config.HA_TOKEN

$logDir  = Join-Path $scriptDir "logs"
$logFile = Join-Path $logDir "energy_schedule.log"
$stateFile = Join-Path $scriptDir ".energy_schedule_state.json"

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

$haHeaders = @{
    "Authorization" = "Bearer $haToken"
    "Content-Type"  = "application/json"
}

# Device map: schedule name → Sonoff entity ID
$deviceMap = @{
    "main_geyser" = "switch.sonoff_1001f8b113"
    "flat_geyser" = "switch.sonoff_100179fb1b"
    "pool_pump"   = "switch.sonoff_1001f8b132"
}

$deviceNames = @{
    "main_geyser" = "Main Geyser"
    "flat_geyser" = "Flat Geyser"
    "pool_pump"   = "Pool Pump"
}

$kitchenSpeaker = "media_player.kitchen_speaker"
$ttsEngine      = "tts.google_translate_en_com"

# ============================================================
# Logging
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

# ============================================================
# State file (mutex-protected)
# ============================================================

function Read-State {
    $mtx = $null
    try {
        $mtx = New-Object System.Threading.Mutex($false, "Global\HA-EnergySchedule")
        $null = $mtx.WaitOne(5000)

        if (Test-Path $stateFile) {
            return Get-Content $stateFile -Raw | ConvertFrom-Json
        }
        return [PSCustomObject]@{
            scheduler_turned_on = [PSCustomObject]@{}
            devices_switched_this_hour = [PSCustomObject]@{}
        }
    } catch {
        return [PSCustomObject]@{
            scheduler_turned_on = [PSCustomObject]@{}
            devices_switched_this_hour = [PSCustomObject]@{}
        }
    } finally {
        if ($mtx) { try { $mtx.ReleaseMutex() } catch {} ; $mtx.Dispose() }
    }
}

function Write-State {
    param($State)
    $mtx = $null
    try {
        $mtx = New-Object System.Threading.Mutex($false, "Global\HA-EnergySchedule")
        $null = $mtx.WaitOne(5000)
        $State | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Encoding UTF8
    } catch {} finally {
        if ($mtx) { try { $mtx.ReleaseMutex() } catch {} ; $mtx.Dispose() }
    }
}

# ============================================================
# Phone notification helper
# ============================================================

$script:notifyService = $null

function Get-NotifyService {
    if ($script:notifyService) { return $script:notifyService }
    try {
        $services = Invoke-RestMethod -Uri "$haBase/api/services" -Headers $haHeaders -TimeoutSec 10
        $notifyDomain = $services | Where-Object { $_.domain -eq "notify" }
        if ($notifyDomain) {
            $mobileService = $notifyDomain.services.PSObject.Properties | Where-Object { $_.Name -like "mobile_app_*" } | Select-Object -First 1
            if ($mobileService) {
                $script:notifyService = "notify.$($mobileService.Name)"
                return $script:notifyService
            }
        }
    } catch {}
    return $null
}

function Send-Notification {
    param([string]$Title, [string]$Message)

    # TTS on kitchen speaker (06:00-22:00 only)
    $hour = (Get-Date).Hour
    if ($hour -ge 6 -and $hour -lt 22) {
        try {
            $ttsBody = @{
                target = @{ entity_id = $ttsEngine }
                data   = @{ media_player_entity_id = $kitchenSpeaker; message = $Message }
            } | ConvertTo-Json -Depth 5
            $null = Invoke-WebRequest -Uri "$haBase/api/services/tts/speak" `
                -Method POST -Headers $haHeaders `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($ttsBody)) `
                -UseBasicParsing -TimeoutSec 10
        } catch {
            Write-Log "TTS failed: $($_.Exception.Message)" "WARN"
        }
    }

    # Phone notification
    $svc = Get-NotifyService
    if ($svc) {
        try {
            $phoneBody = @{
                title   = $Title
                message = $Message
            } | ConvertTo-Json -Depth 5
            $null = Invoke-WebRequest -Uri "$haBase/api/services/$($svc -replace '\.', '/')" `
                -Method POST -Headers $haHeaders `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($phoneBody)) `
                -UseBasicParsing -TimeoutSec 10
        } catch {
            Write-Log "Phone notification failed: $($_.Exception.Message)" "WARN"
        }
    }
}

# ============================================================
# Step 1: Read schedule and master switch
# ============================================================

# Check master switch
try {
    $masterState = Invoke-RestMethod -Uri "$haBase/api/states/input_boolean.energy_schedule_active" -Headers $haHeaders -TimeoutSec 10
    if ($masterState.state -ne "on") {
        Write-Log "Energy scheduler disabled (input_boolean.energy_schedule_active = $($masterState.state))"
        exit 0
    }
} catch {
    Write-Log "Cannot read master switch: $($_.Exception.Message)" "WARN"
    exit 0
}

# Read schedule sensor
$schedule = $null
try {
    $schedState = Invoke-RestMethod -Uri "$haBase/api/states/sensor.energy_schedule" -Headers $haHeaders -TimeoutSec 10
    if ($schedState.state -ne "active") {
        exit 0
    }

    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($schedState.attributes.schedule_date -ne $today) {
        exit 0
    }

    $schedule = $schedState.attributes
} catch {
    Write-Log "Cannot read energy schedule: $($_.Exception.Message)" "WARN"
    exit 0
}

if (-not $schedule.hourly_plan -or $schedule.hourly_plan.Count -eq 0) {
    exit 0
}

# ============================================================
# Step 2: Determine expected devices from override booleans
# ============================================================

$currentHour = (Get-Date).Hour
$hh = $currentHour.ToString("D2")

$expectedDevices = @()
foreach ($deviceName in $deviceMap.Keys) {
    $overrideEntity = "input_boolean.override_${deviceName}_${hh}"
    try {
        $overrideState = Invoke-RestMethod -Uri "$haBase/api/states/$overrideEntity" -Headers $haHeaders -TimeoutSec 5
        if ($overrideState.state -eq "on") {
            $expectedDevices += $deviceName
        }
    } catch {
        # Override entity not available — fall back to schedule sensor
        Write-Log "Override $overrideEntity not readable, falling back to schedule" "WARN"
        $hourSlot = $schedule.hourly_plan | Where-Object { [int]$_.hour -eq $currentHour }
        if ($hourSlot -and $hourSlot.devices -and (@($hourSlot.devices) -contains $deviceName)) {
            $expectedDevices += $deviceName
        }
    }
}

# ============================================================
# Step 3: Read current device states from HA
# ============================================================

$state = Read-State

# Ensure scheduler_turned_on exists
if (-not $state.scheduler_turned_on) {
    $state.scheduler_turned_on = [PSCustomObject]@{}
}
if (-not $state.devices_switched_this_hour) {
    $state.devices_switched_this_hour = [PSCustomObject]@{}
}

$hourKey = "${today}_${currentHour}"
$events = @()

foreach ($deviceName in $deviceMap.Keys) {
    $entityId = $deviceMap[$deviceName]
    $friendlyName = $deviceNames[$deviceName]
    $shouldBeOn = $expectedDevices -contains $deviceName

    # Check if already switched this hour
    $switchKey = "${hourKey}_${deviceName}"
    if ($state.devices_switched_this_hour.PSObject.Properties[$switchKey]) {
        continue
    }

    # Read current state from HA
    $currentState = "unknown"
    try {
        $entityState = Invoke-RestMethod -Uri "$haBase/api/states/$entityId" -Headers $haHeaders -TimeoutSec 10
        $currentState = $entityState.state
    } catch {
        Write-Log "Cannot read $entityId : $($_.Exception.Message)" "WARN"
        continue
    }

    $isOn = ($currentState -eq "on")

    if ($shouldBeOn -and -not $isOn) {
        # Turn ON
        Write-Log "Turning ON $friendlyName ($entityId) for hour $currentHour"
        try {
            $body = @{ entity_id = $entityId } | ConvertTo-Json
            $null = Invoke-WebRequest -Uri "$haBase/api/services/switch/turn_on" `
                -Method POST -Headers $haHeaders `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -UseBasicParsing -TimeoutSec 10

            # Track that scheduler turned this on
            $state.scheduler_turned_on | Add-Member -NotePropertyName $deviceName -NotePropertyValue $true -Force
            $state.devices_switched_this_hour | Add-Member -NotePropertyName $switchKey -NotePropertyValue "on" -Force

            $events += @{ time = (Get-Date).ToString("HH:mm"); device = $friendlyName; action = "on" }
            Send-Notification -Title "Energy Schedule" -Message "$friendlyName turned on (scheduled $currentHour`:00-$($currentHour+1):00)"
        } catch {
            Write-Log "Failed to turn on $entityId : $($_.Exception.Message)" "ERROR"
        }

    } elseif (-not $shouldBeOn -and $isOn) {
        # Only turn OFF if the scheduler turned it on (respect manual overrides)
        $schedulerTurnedOn = $false
        if ($state.scheduler_turned_on.PSObject.Properties[$deviceName]) {
            $schedulerTurnedOn = [bool]$state.scheduler_turned_on.$deviceName
        }

        if ($schedulerTurnedOn) {
            Write-Log "Turning OFF $friendlyName ($entityId) - scheduled slot ended"
            try {
                $body = @{ entity_id = $entityId } | ConvertTo-Json
                $null = Invoke-WebRequest -Uri "$haBase/api/services/switch/turn_off" `
                    -Method POST -Headers $haHeaders `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                    -UseBasicParsing -TimeoutSec 10

                # Clear scheduler tracking
                $state.scheduler_turned_on | Add-Member -NotePropertyName $deviceName -NotePropertyValue $false -Force
                $state.devices_switched_this_hour | Add-Member -NotePropertyName $switchKey -NotePropertyValue "off" -Force

                $events += @{ time = (Get-Date).ToString("HH:mm"); device = $friendlyName; action = "off" }
                Send-Notification -Title "Energy Schedule" -Message "$friendlyName turned off (schedule complete)"
            } catch {
                Write-Log "Failed to turn off $entityId : $($_.Exception.Message)" "ERROR"
            }
        }
    } elseif (-not $shouldBeOn -and -not $isOn) {
        # Device is OFF and should be OFF - clear stale scheduler flag
        # This prevents the scheduler from turning off a future manual turn-on
        if ($state.scheduler_turned_on.PSObject.Properties[$deviceName]) {
            $state.scheduler_turned_on | Add-Member -NotePropertyName $deviceName -NotePropertyValue $false -Force
        }
    }
}

# ============================================================
# Step 4: Update state file and log sensor
# ============================================================

Write-State $state

if ($events.Count -gt 0) {
    # Update event log sensor
    try {
        $logState = Invoke-RestMethod -Uri "$haBase/api/states/sensor.energy_schedule_log" -Headers $haHeaders -TimeoutSec 10
        $existingEvents = @()
        if ($logState.attributes.events) {
            $existingEvents = @($logState.attributes.events)
        }
        $allEvents = $existingEvents + $events
        $eventCount = $allEvents.Count

        $logBody = @{
            state      = "$eventCount"
            attributes = @{
                friendly_name = "Energy Schedule Log"
                icon          = "mdi:format-list-bulleted"
                events        = $allEvents
                last_updated  = (Get-Date).ToString("o")
            }
        } | ConvertTo-Json -Depth 10

        $null = Invoke-WebRequest `
            -Uri "$haBase/api/states/sensor.energy_schedule_log" `
            -Method POST -Headers $haHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($logBody)) `
            -UseBasicParsing -TimeoutSec 15
        Write-Log "$($events.Count) event(s) logged"
    } catch {
        Write-Log "Failed to update log sensor: $($_.Exception.Message)" "WARN"
    }
}
