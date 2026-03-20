<#
.SYNOPSIS
    Fetch Open-Meteo forecast, analyze with Gemini, update sensor.weather_briefing.

.DESCRIPTION
    Runs daily at 04:15 via Windows Scheduled Task (HA-RefreshWeather).
    1. Fetches hourly forecast from Open-Meteo API for Randpark Ridge
    2. Extracts today's daytime hours (06:00-21:00)
    3. Sends weather data to Gemini for natural-language TTS briefing
    4. Updates sensor.weather_briefing with TTS text + detailed attributes
    5. Falls back to basic temp summary if Gemini fails

.EXAMPLE
    .\09a-Refresh-Weather.ps1
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
$logFile = Join-Path $logDir "weather_briefing.log"

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# Randpark Ridge, South Africa
$lat = "-26.103668"
$lon = "27.954189"

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

# Trim log file if > 1MB (runs daily, much smaller than vision log)
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    $lines = Get-Content $logFile -Tail 500
    $lines | Set-Content $logFile
}

Write-Log "=== Weather briefing run starting ==="

# ============================================================
# STEP 1: Fetch Open-Meteo forecast
# ============================================================

$meteoUrl = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&hourly=temperature_2m,cloud_cover,precipitation,wind_speed_10m,relative_humidity_2m,weather_code&timezone=Africa/Johannesburg&forecast_days=2"

Write-Log "Fetching Open-Meteo forecast..."

try {
    $meteoResp = Invoke-RestMethod -Uri $meteoUrl -Method GET -TimeoutSec 30
} catch {
    Write-Log "Open-Meteo fetch failed: $($_.Exception.Message)" "ERROR"
    Write-Log "=== Run complete (API failed, skipping) ==="
    exit 0
}

Write-Log "Open-Meteo response received, processing hourly data..."

# ============================================================
# STEP 2: Extract today's daytime hours (06:00-21:00)
# ============================================================

$hourly = $meteoResp.hourly

$daytimeHours = @()
for ($i = 0; $i -lt $hourly.time.Count; $i++) {
    $hour = [int]($hourly.time[$i].Substring(11, 2))

    if ($hour -ge 6 -and $hour -le 21) {
        $daytimeHours += @{
            hour         = "$($hourly.time[$i].Substring(11, 5))"
            temp_c       = $hourly.temperature_2m[$i]
            cloud_pct    = $hourly.cloud_cover[$i]
            humidity_pct = $hourly.relative_humidity_2m[$i]
            wind_kmh     = $hourly.wind_speed_10m[$i]
            precip_mm    = $hourly.precipitation[$i]
            weather_code = $hourly.weather_code[$i]
        }
    }
}

# Build 48-element array of ALL hourly cloud cover values (for solar-aware TTT)
$hourlyCloud = @()
for ($i = 0; $i -lt $hourly.time.Count; $i++) {
    $hourlyCloud += @{
        hour      = $hourly.time[$i]
        cloud_pct = $hourly.cloud_cover[$i]
    }
}

Write-Log "Built hourly cloud cover array: $($hourlyCloud.Count) entries"

$today = (Get-Date).ToString("yyyy-MM-dd")

if ($daytimeHours.Count -eq 0) {
    Write-Log "No daytime hours found for today ($today), skipping" "WARN"
    Write-Log "=== Run complete (no data for today) ==="
    exit 0
}

Write-Log "Extracted $($daytimeHours.Count) daytime hours for $today"

# Compute summary stats for fallback and Gemini context
$temps = $daytimeHours | ForEach-Object { $_.temp_c }
$minTemp = [math]::Round(($temps | Measure-Object -Minimum).Minimum, 0)
$maxTemp = [math]::Round(($temps | Measure-Object -Maximum).Maximum, 0)
$avgCloud = [math]::Round(($daytimeHours | ForEach-Object { $_.cloud_pct } | Measure-Object -Average).Average, 0)
$totalPrecip = [math]::Round(($daytimeHours | ForEach-Object { $_.precip_mm } | Measure-Object -Sum).Sum, 1)
$maxWind = [math]::Round(($daytimeHours | ForEach-Object { $_.wind_kmh } | Measure-Object -Maximum).Maximum, 1)

# Map WMO weather codes to descriptions
$weatherCodes = @{
    0 = "Clear sky"; 1 = "Mainly clear"; 2 = "Partly cloudy"; 3 = "Overcast"
    45 = "Fog"; 48 = "Depositing rime fog"
    51 = "Light drizzle"; 53 = "Moderate drizzle"; 55 = "Dense drizzle"
    61 = "Slight rain"; 63 = "Moderate rain"; 65 = "Heavy rain"
    71 = "Slight snow"; 73 = "Moderate snow"; 75 = "Heavy snow"
    80 = "Slight rain showers"; 81 = "Moderate rain showers"; 82 = "Violent rain showers"
    95 = "Thunderstorm"; 96 = "Thunderstorm with slight hail"; 99 = "Thunderstorm with heavy hail"
}

$uniqueCodes = $daytimeHours | ForEach-Object { $_.weather_code } | Sort-Object -Unique
$conditions = ($uniqueCodes | ForEach-Object { if ($weatherCodes.ContainsKey([int]$_)) { $weatherCodes[[int]$_] } else { "Code $_" } }) -join ", "

Write-Log "Stats: $minTemp-${maxTemp}C, cloud=$avgCloud%, precip=${totalPrecip}mm, wind=${maxWind}km/h, conditions=$conditions"

# ============================================================
# STEP 3: Send to Gemini for natural-language briefing
# ============================================================

$weatherDataJson = $daytimeHours | ConvertTo-Json -Depth 5

$geminiPrompt = @"
You are a weather assistant for a home in Randpark Ridge, Johannesburg, South Africa. This home has solar panels and a garden that needs irrigation.

Here is the hourly weather forecast for today ($today), from 06:00 to 21:00 local time:

$weatherDataJson

Summary stats:
- Temperature range: ${minTemp}C to ${maxTemp}C
- Average cloud cover: ${avgCloud}%
- Total expected precipitation: ${totalPrecip}mm
- Max wind speed: ${maxWind} km/h
- Conditions: $conditions

Produce a JSON response with these fields:
1. "tts_briefing": A natural, conversational 2-3 sentence weather summary suitable for text-to-speech. Keep it under 180 characters. Example: "Today will be warm and sunny, reaching 28 degrees with clear skies all day."
2. "solar_impact": If average cloud cover is above 40% OR rain is expected, provide ONE sentence about the impact on solar generation. Otherwise, return an empty string.
3. "irrigation_note": If any precipitation is expected (total > 0mm), provide ONE sentence advising whether garden irrigation can be skipped. Otherwise, return an empty string.
4. "detailed_summary": A 3-5 sentence detailed summary including temperatures, cloud cover, precipitation, and wind for the HA sensor attributes.

Respond with ONLY the JSON object, no markdown formatting.
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

$ttsText = $null
$detailedSummary = $null

Write-Log "Sending weather data to Gemini ($geminiModel)..."

try {
    $geminiResp = Invoke-RestMethod -Uri $geminiUri -Method POST `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($geminiBody)) `
        -ContentType "application/json; charset=utf-8" -TimeoutSec 30

    $responseText = $geminiResp.candidates[0].content.parts[0].text
    $parsed = $responseText | ConvertFrom-Json

    Write-Log "Gemini response: $($parsed | ConvertTo-Json -Compress)"

    # Build TTS text from briefing + optional parts
    $parts = @()
    if ($parsed.tts_briefing) { $parts += $parsed.tts_briefing }
    if ($parsed.solar_impact) { $parts += $parsed.solar_impact }
    if ($parsed.irrigation_note) { $parts += $parsed.irrigation_note }

    $ttsText = ($parts -join " ").Trim()
    $detailedSummary = $parsed.detailed_summary

    Write-Log "TTS text ($($ttsText.Length) chars): $ttsText"
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
# STEP 3b: Fallback if Gemini failed
# ============================================================

if (-not $ttsText) {
    Write-Log "Using fallback weather summary (Gemini unavailable)" "WARN"
    $ttsText = "Today will be $minTemp to $maxTemp degrees"
    if ($totalPrecip -gt 0) {
        $ttsText += " with ${totalPrecip}mm of rain expected"
    } elseif ($avgCloud -gt 60) {
        $ttsText += " with cloudy skies"
    } else {
        $ttsText += " with mostly clear skies"
    }
    $ttsText += "."
    $detailedSummary = $ttsText
}

# ============================================================
# STEP 4: Update HA sensor
# ============================================================

# HA sensor state has a 255 char limit; store full text in attributes
$sensorState = $ttsText
if ($sensorState.Length -gt 250) {
    $sensorState = $sensorState.Substring(0, 247) + "..."
}

Write-Log "Updating sensor.weather_briefing..."

$sensorBody = @{
    state      = $sensorState
    attributes = @{
        friendly_name    = "Weather Briefing"
        icon             = "mdi:weather-partly-cloudy"
        min_temp_c       = $minTemp
        max_temp_c       = $maxTemp
        avg_cloud_pct    = $avgCloud
        total_precip_mm  = $totalPrecip
        max_wind_kmh     = $maxWind
        conditions       = $conditions
        tts_text         = $ttsText
        detailed_summary = $detailedSummary
        forecast_hours       = $daytimeHours.Count
        hourly_cloud_cover   = $hourlyCloud
        last_updated         = (Get-Date).ToString("o")
    }
} | ConvertTo-Json -Depth 5

try {
    $null = Invoke-WebRequest `
        -Uri "$haBase/api/states/sensor.weather_briefing" `
        -Method POST -Headers $haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($sensorBody)) `
        -UseBasicParsing -TimeoutSec 15
    Write-Log "sensor.weather_briefing updated successfully"
} catch {
    Write-Log "Failed to update sensor: $($_.Exception.Message)" "ERROR"
}

Write-Log "=== Weather briefing run complete ==="
