<#
.SYNOPSIS
    Calculate optimal energy schedule using weather forecast + Gemini.

.DESCRIPTION
    Runs daily at 04:20 via Windows Scheduled Task (HA-RefreshEnergySchedule).
    1. Reads sensor.weather_briefing for hourly cloud cover + precipitation
    2. Reads sensor.battery_soc for current battery state
    3. Builds hourly solar estimate (06:00-20:00) with bell curve + cloud attenuation
    4. Calls Gemini to optimize device scheduling within solar budget
    5. Updates sensor.energy_schedule with hourly plan + TTS summary
    6. Falls back to rule-based schedule if Gemini fails

.EXAMPLE
    .\18a-Refresh-EnergySchedule.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN", "GeminiApiKey")

# ============================================================
# Configuration
# ============================================================

$haBase      = "http://$($Config.HA_IP):8123"
$haToken     = $Config.HA_TOKEN
$geminiKey   = $Config.GeminiApiKey
$geminiModel = $Config.GeminiModel

$logDir  = Join-Path $scriptDir "logs"
$logFile = Join-Path $logDir "energy_schedule.log"

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

$haHeaders = @{
    "Authorization" = "Bearer $haToken"
    "Content-Type"  = "application/json"
}

# ============================================================
# Logging
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# Trim log file if > 1MB
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    $lines = Get-Content $logFile -Tail 500
    $lines | Set-Content $logFile
}

Write-Log "=== Energy schedule calculation starting ==="

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
# Step 1: Read weather data from HA
# ============================================================

Write-Log "Reading weather briefing sensor..."

$weatherData = $null
$hourlyCloud = @()
$totalPrecip = 0

try {
    $weatherState = Invoke-RestMethod -Uri "$haBase/api/states/sensor.weather_briefing" -Headers $haHeaders -TimeoutSec 10
    if ($weatherState.attributes.hourly_cloud_cover) {
        $hourlyCloud = $weatherState.attributes.hourly_cloud_cover
    }
    if ($weatherState.attributes.total_precip_mm) {
        $totalPrecip = [double]$weatherState.attributes.total_precip_mm
    }
    Write-Log "Weather data: $($hourlyCloud.Count) cloud entries, precip=${totalPrecip}mm"
} catch {
    Write-Log "Weather sensor unavailable: $($_.Exception.Message)" "WARN"
}

# Read battery SOC
$soc = 50  # default
try {
    $socState = Invoke-RestMethod -Uri "$haBase/api/states/sensor.battery_soc" -Headers $haHeaders -TimeoutSec 10
    $soc = [double]$socState.state
    Write-Log "Battery SOC: $soc%"
} catch {
    Write-Log "Battery SOC unavailable, using default 50%" "WARN"
}

# ============================================================
# Step 2: Build hourly solar estimate (06:00 - 20:00)
# ============================================================

$today = (Get-Date).ToString("yyyy-MM-dd")
$peakSolarKw = 18  # 18 kW peak capacity

$hourlyForecast = @()

for ($h = 6; $h -le 20; $h++) {
    # Bell curve: peak at 12:30, zero at 6 and 19
    $hod = $h + 0.5  # mid-hour
    if ($hod -ge 6 -and $hod -le 19) {
        $nominal = $peakSolarKw * (1 - [math]::Pow(($hod - 12.5) / 6.5, 2))
        if ($nominal -lt 0) { $nominal = 0 }
    } else {
        $nominal = 0
    }

    # Look up cloud cover for this hour
    $cloud = 30  # default moderate cloud
    $hourStr = "${today}T$($h.ToString('D2')):00"
    foreach ($entry in $hourlyCloud) {
        if ($entry.hour -eq $hourStr) {
            $cloud = [double]$entry.cloud_pct
            break
        }
    }

    # Cloud attenuation factor (same as 05d)
    if ($cloud -le 50) {
        $factor = 1.0 - $cloud * 0.006
    } else {
        $factor = 1.2 - $cloud * 0.01
    }

    $solarKw = [math]::Round($nominal * $factor, 1)

    $hourlyForecast += @{
        hour     = $h
        solar_kw = $solarKw
        cloud_pct = $cloud
    }
}

Write-Log "Built hourly forecast: $($hourlyForecast.Count) hours"
$totalSolarKwh = [math]::Round(($hourlyForecast | ForEach-Object { $_.solar_kw } | Measure-Object -Sum).Sum, 1)
Write-Log "Total estimated solar: ${totalSolarKwh} kWh"

# ============================================================
# Step 3: Call Gemini for optimal schedule
# ============================================================

$forecastJson = $hourlyForecast | ConvertTo-Json -Depth 5

$geminiPrompt = @"
You are an energy scheduler for a home with an 18 kW peak solar installation in Johannesburg, South Africa.
Your PRIMARY goal is to MAXIMIZE solar utilization by running devices as much as possible within the solar budget.

Here is the hourly solar forecast for today ($today):

$forecastJson

Additional context:
- Battery SOC: ${soc}%
- Total precipitation expected: ${totalPrecip}mm
- Base household load: constant 1.5 kW

Devices to schedule (solar hours 06:00-20:00 only):
1. main_geyser (3.9 kW): MINIMUM 2 hours, MAXIMUM 6 hours. At least 1 hour MUST be in 15:00-19:00 (pre-evening heating). Priority: HIGH.
2. flat_geyser (2.2 kW): MINIMUM 1 hour, MAXIMUM 4 hours. Priority: MEDIUM.
3. pool_pump (3.0 kW): MINIMUM 0 hours, MAXIMUM 6 hours. Priority: LOW.

CRITICAL scheduling rules:
- MAXIMIZE solar utilization. The minimums are FLOORS, not targets. If surplus solar is available after meeting minimums, schedule MORE device hours up to the maximums. Wasting surplus solar is bad.
- Any hour where solar_kw exceeds base load (1.5 kW) + scheduled device loads by more than 2 kW is underutilized — fill it with more device runtime.
- Total device_load_kw + base load (1.5 kW) must not exceed available solar_kw in any hour, UNLESS the SOC bonus applies.
- SOC bonus: If battery SOC > 70%, you MAY exceed solar by up to 2 kW in shoulder hours (06-08, 17-20) to extend device runtime, since battery has headroom to absorb the shortfall.
- Prioritize: main_geyser > flat_geyser > pool_pump. After all geysers are at their max, fill remaining surplus with pool pump.
- Schedule continuous runs where possible (avoid 1-hour gaps between same-device slots).
- If solar is very low (overcast), still schedule minimum geyser hours even if it draws from battery.

Respond with ONLY a JSON object (no markdown):
{
  "hourly_plan": [{"hour": 6, "solar_kw": X, "devices": ["device_name", ...], "device_load_kw": Y}, ...],
  "device_summary": "main_geyser: 10-12,16-17; flat_geyser: 11-12; pool_pump: 12-13",
  "total_solar_kwh": X,
  "total_device_kwh": X,
  "irrigation_disabled": true/false,
  "tts_summary": "Today's energy plan: geysers will run from 10 to 12 and 4 to 5 PM, with the pool pump at midday. Good solar expected.",
  "confidence": "high/medium/low"
}

Set irrigation_disabled to true if total precipitation > 2mm.
The tts_summary should be 1-2 sentences, conversational, suitable for text-to-speech.
Include ALL hours from 6 to 20 in hourly_plan, even if no devices are scheduled (devices: []).
"@

$geminiUri = "https://generativelanguage.googleapis.com/v1beta/models/${geminiModel}:generateContent?key=$geminiKey"

$geminiBody = @{
    contents = @(@{
        parts = @(
            @{ text = $geminiPrompt }
        )
    })
    generationConfig = @{
        responseMimeType = "application/json"
        temperature      = 0.3
    }
} | ConvertTo-Json -Depth 10

$schedule = $null

Write-Log "Sending forecast to Gemini ($geminiModel)..."

try {
    $geminiResp = Invoke-RestMethod -Uri $geminiUri -Method POST `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($geminiBody)) `
        -ContentType "application/json; charset=utf-8" -TimeoutSec 120

    # Track Gemini token usage
    if ($geminiResp.usageMetadata) {
        try {
            Update-GeminiTokenStats -Source "energy_schedule" -Calls 1 `
                -PromptTokens ([int]$geminiResp.usageMetadata.promptTokenCount) `
                -CompletionTokens ([int]$geminiResp.usageMetadata.candidatesTokenCount) `
                -TotalTokens ([int]$geminiResp.usageMetadata.totalTokenCount)
        } catch {}
    }

    $responseText = $geminiResp.candidates[0].content.parts[0].text
    $schedule = $responseText | ConvertFrom-Json

    Write-Log "Gemini response: confidence=$($schedule.confidence), devices=$($schedule.device_summary)"
    Write-Log "TTS: $($schedule.tts_summary)"
} catch {
    $errMsg = $_.Exception.Message
    if ($_.Exception.Response) {
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errMsg += " | " + $reader.ReadToEnd()
        } catch {}
    }
    Write-Log "Gemini failed: $errMsg" "ERROR"
}

# ============================================================
# Step 3b: Fallback schedule if Gemini failed
# ============================================================

if (-not $schedule) {
    Write-Log "Using fallback greedy schedule" "WARN"

    $baseLoad = 1.5
    $deviceSpecs = @(
        @{ name = "main_geyser"; kw = 3.9; min = 2; max = 6; priority = 1; evening = $true }
        @{ name = "flat_geyser"; kw = 2.2; min = 1; max = 4; priority = 2; evening = $false }
        @{ name = "pool_pump";   kw = 3.0; min = 0; max = 6; priority = 3; evening = $false }
    )

    # Initialize plan with remaining solar capacity per hour
    $fallbackPlan = @()
    for ($h = 6; $h -le 20; $h++) {
        $entry = $hourlyForecast | Where-Object { $_.hour -eq $h }
        $solarKw = if ($entry) { $entry.solar_kw } else { 0 }
        $fallbackPlan += @{
            hour           = $h
            solar_kw       = $solarKw
            devices        = [System.Collections.ArrayList]@()
            device_load_kw = 0
            remaining      = [math]::Max(0, $solarKw - $baseLoad)
        }
    }

    # SOC bonus: allow 2 kW overdraw in shoulder hours if battery is healthy
    $socBonus = if ($soc -gt 70) { 2.0 } else { 0 }

    # Greedy assignment: for each device (priority order), fill hours with most remaining capacity
    foreach ($dev in ($deviceSpecs | Sort-Object priority)) {
        # Ensure evening hour for main_geyser first
        $assigned = 0
        if ($dev.evening) {
            $eveningSlot = $fallbackPlan | Where-Object {
                $_.hour -ge 15 -and $_.hour -le 19 -and ($_.remaining + $socBonus) -ge $dev.kw
            } | Sort-Object { -$_.remaining } | Select-Object -First 1
            if ($eveningSlot) {
                $null = $eveningSlot.devices.Add($dev.name)
                $eveningSlot.device_load_kw += $dev.kw
                $eveningSlot.remaining -= $dev.kw
                $assigned++
            }
        }

        # Fill remaining slots — prefer hours with most remaining solar, break ties by proximity to midday
        $candidateHours = $fallbackPlan | Where-Object {
            -not ($_.devices -contains $dev.name) -and ($_.remaining + $socBonus) -ge $dev.kw
        } | Sort-Object { -$_.remaining }, { [math]::Abs($_.hour - 12) }

        foreach ($slot in $candidateHours) {
            if ($assigned -ge $dev.max) { break }
            # Apply SOC bonus only in shoulder hours
            $bonus = if ($slot.hour -le 8 -or $slot.hour -ge 17) { $socBonus } else { 0 }
            if ($slot.remaining + $bonus -lt $dev.kw) { continue }
            $null = $slot.devices.Add($dev.name)
            $slot.device_load_kw += $dev.kw
            $slot.remaining -= $dev.kw
            $assigned++
        }

        # Force-assign minimum hours from highest-solar slots if minimum not met
        if ($assigned -lt $dev.min) {
            $forceSlots = $fallbackPlan | Where-Object {
                -not ($_.devices -contains $dev.name)
            } | Sort-Object { -$_.solar_kw } | Select-Object -First ($dev.min - $assigned)
            foreach ($slot in $forceSlots) {
                $null = $slot.devices.Add($dev.name)
                $slot.device_load_kw += $dev.kw
                $slot.remaining = [math]::Max(0, $slot.remaining - $dev.kw)
                $assigned++
            }
        }

        Write-Log "Fallback: $($dev.name) assigned $assigned hours (min=$($dev.min), max=$($dev.max))"
    }

    $totalDeviceKwh = [math]::Round(($fallbackPlan | ForEach-Object { $_.device_load_kw } | Measure-Object -Sum).Sum, 1)

    # Build device summary string
    $summaryParts = @()
    foreach ($dev in $deviceSpecs) {
        $hours = ($fallbackPlan | Where-Object { $_.devices -contains $dev.name } | ForEach-Object { $_.hour }) -join ","
        if ($hours) { $summaryParts += "$($dev.name): $hours" }
    }

    $avgCloud = 30
    if ($hourlyForecast.Count -gt 0) {
        $avgCloud = [math]::Round(($hourlyForecast | ForEach-Object { $_.cloud_pct } | Measure-Object -Average).Average, 0)
    }
    $conditionText = if ($avgCloud -lt 50) { "Good solar expected" } elseif ($avgCloud -lt 80) { "Moderate cloud cover" } else { "Overcast conditions" }

    $schedule = @{
        hourly_plan        = $fallbackPlan
        device_summary     = ($summaryParts -join "; ") + " (fallback)"
        total_solar_kwh    = $totalSolarKwh
        total_device_kwh   = $totalDeviceKwh
        irrigation_disabled = ($totalPrecip -gt 2)
        tts_summary        = "Energy schedule using fallback rules. $conditionText with ${totalSolarKwh} kilowatt hours expected."
        confidence         = "fallback"
    }
}

# ============================================================
# Step 4: Update HA sensor
# ============================================================

Write-Log "Updating sensor.energy_schedule..."

$sensorState = "active"
$sensorBody = @{
    state      = $sensorState
    attributes = @{
        friendly_name       = "Energy Schedule"
        icon                = "mdi:lightning-bolt-circle"
        hourly_plan         = $schedule.hourly_plan
        device_summary      = $schedule.device_summary
        total_solar_kwh     = $schedule.total_solar_kwh
        total_device_kwh    = $schedule.total_device_kwh
        tts_summary         = $schedule.tts_summary
        irrigation_disabled = $schedule.irrigation_disabled
        confidence          = $schedule.confidence
        schedule_date       = $today
        last_updated        = (Get-Date).ToString("o")
    }
} | ConvertTo-Json -Depth 10

try {
    $null = Invoke-WebRequest `
        -Uri "$haBase/api/states/sensor.energy_schedule" `
        -Method POST -Headers $haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($sensorBody)) `
        -UseBasicParsing -TimeoutSec 15
    Write-Log "sensor.energy_schedule updated successfully"
} catch {
    Write-Log "Failed to update sensor: $($_.Exception.Message)" "ERROR"
}

# ============================================================
# Step 5: Sync override booleans to match new schedule
# ============================================================

Write-Log "Syncing override booleans to new schedule..."

$overrideDevices = @("main_geyser", "flat_geyser", "pool_pump")
$onEntities = @()
$offEntities = @()

foreach ($dev in $overrideDevices) {
    for ($h = 6; $h -le 20; $h++) {
        $hh = $h.ToString("D2")
        $entityId = "input_boolean.override_${dev}_${hh}"

        # Check if this device is scheduled for this hour
        $hourSlot = $schedule.hourly_plan | Where-Object { [int]$_.hour -eq $h }
        $isScheduled = $false
        if ($hourSlot -and $hourSlot.devices) {
            $isScheduled = @($hourSlot.devices) -contains $dev
        }

        if ($isScheduled) { $onEntities += $entityId } else { $offEntities += $entityId }
    }
}

# Batch turn on (scheduled hours)
if ($onEntities.Count -gt 0) {
    try {
        $body = @{ entity_id = $onEntities } | ConvertTo-Json -Depth 5
        $null = Invoke-WebRequest -Uri "$haBase/api/services/input_boolean/turn_on" `
            -Method POST -Headers $haHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 15
        Write-Log "Turned ON $($onEntities.Count) override booleans"
    } catch {
        Write-Log "Failed to sync ON overrides: $($_.Exception.Message)" "WARN"
    }
}

# Batch turn off (non-scheduled hours)
if ($offEntities.Count -gt 0) {
    try {
        $body = @{ entity_id = $offEntities } | ConvertTo-Json -Depth 5
        $null = Invoke-WebRequest -Uri "$haBase/api/services/input_boolean/turn_off" `
            -Method POST -Headers $haHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 15
        Write-Log "Turned OFF $($offEntities.Count) override booleans"
    } catch {
        Write-Log "Failed to sync OFF overrides: $($_.Exception.Message)" "WARN"
    }
}

Write-Log "Override sync complete: $($onEntities.Count) ON, $($offEntities.Count) OFF"

# Reset today's log
$logBody = @{
    state      = "0"
    attributes = @{
        friendly_name = "Energy Schedule Log"
        icon          = "mdi:format-list-bulleted"
        events        = @()
        last_updated  = (Get-Date).ToString("o")
    }
} | ConvertTo-Json -Depth 5

try {
    $null = Invoke-WebRequest `
        -Uri "$haBase/api/states/sensor.energy_schedule_log" `
        -Method POST -Headers $haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($logBody)) `
        -UseBasicParsing -TimeoutSec 15
    Write-Log "sensor.energy_schedule_log reset for new day"
} catch {
    Write-Log "Failed to reset log sensor: $($_.Exception.Message)" "WARN"
}

Write-Log "=== Energy schedule calculation complete ==="
