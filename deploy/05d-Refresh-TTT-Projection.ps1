<#
.SYNOPSIS
    Refresh battery projection sensor with 48-hour SOC/solar/load forecast.

.DESCRIPTION
    Reads current battery SOC, house load, and hourly cloud cover from HA sensors,
    runs an hour-by-hour simulation of battery drain/charge with solar generation
    attenuated by cloud cover, and posts sensor.battery_projection with array
    attributes for the apexcharts dashboard graph.

    Should run every 10 minutes via the HA-RefreshTTTProjection scheduled task.

.EXAMPLE
    .\05d-Refresh-TTT-Projection.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

$haBase  = "http://$($Config.HA_IP):8123"
$haToken = $Config.HA_TOKEN

$logDir  = Join-Path $scriptDir "logs"
$logFile = Join-Path $logDir "ttt_projection.log"
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
}

# Trim log if > 1MB
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    $lines = Get-Content $logFile -Tail 500
    $lines | Set-Content $logFile
}

# ============================================================
# Step 1: Read current SOC, load, and cloud data from HA
# ============================================================

try {
    $socState = Invoke-RestMethod -Uri "$haBase/api/states/sensor.battery_soc" -Headers $haHeaders -TimeoutSec 10
    $soc = [double]$socState.state
} catch {
    Write-Log "Failed to read battery SOC: $($_.Exception.Message)" "ERROR"
    exit 0
}

try {
    $loadState = Invoke-RestMethod -Uri "$haBase/api/states/sensor.solar_total_load" -Headers $haHeaders -TimeoutSec 10
    $load = [double]$loadState.state
} catch {
    Write-Log "Failed to read solar load: $($_.Exception.Message)" "ERROR"
    exit 0
}

# Cloud data is optional — default to clear sky if unavailable
$cloudData = @()
try {
    $weatherState = Invoke-RestMethod -Uri "$haBase/api/states/sensor.weather_briefing" -Headers $haHeaders -TimeoutSec 10
    if ($weatherState.attributes.hourly_cloud_cover) {
        $cloudData = $weatherState.attributes.hourly_cloud_cover
    }
} catch {
    Write-Log "Weather sensor unavailable, assuming clear sky" "WARN"
}

Write-Log "SOC=$soc%, Load=${load}W, Cloud entries=$($cloudData.Count)"

# ============================================================
# Step 2: Run 48-hour simulation
# ============================================================

$capacity = 40 * 0.95  # 38 kWh usable
$currentSoc = $soc
$now = Get-Date

$hours = @()
$projectedSoc = @()
$projectedSolar = @()
$projectedLoad = @()
$tttHour = $null

for ($h = 0; $h -lt 48; $h++) {
    $future = $now.AddHours($h)
    $hod = $future.Hour + $future.Minute / 60.0

    # Record the timestamp
    $hours += $future.ToString("yyyy-MM-ddTHH:00:00")

    # Nominal solar curve: parabolic 8AM-5PM, peak ~16kW at 12:30
    if ($hod -ge 8 -and $hod -le 17) {
        $nominal = 800 + 15200 * (1 - [math]::Pow(($hod - 12.5) / 4.5, 2))
        if ($nominal -lt 0) { $nominal = 0 }
    } else {
        $nominal = 0
    }

    # Look up cloud cover for this hour
    $cloud = 0
    $futureStr = $future.ToString("yyyy-MM-ddTHH:00")
    foreach ($entry in $cloudData) {
        if ($entry.hour -eq $futureStr) {
            $cloud = [double]$entry.cloud_pct
            break
        }
    }

    # Cloud attenuation factor
    if ($cloud -le 50) {
        $factor = 1.0 - $cloud * 0.006
    } else {
        $factor = 1.2 - $cloud * 0.01
    }

    $solarW = [math]::Round($nominal * $factor, 0)
    $projectedSolar += $solarW
    $projectedLoad += [math]::Round($load, 0)

    # Net drain/charge
    $net = $load - $solarW
    if ($net -gt 0) {
        # Discharging
        $drainKwh = $net / 1000
        $socDrop = $drainKwh / $capacity * 100
        $currentSoc -= $socDrop
    } else {
        # Charging (95% efficiency)
        $chargeKwh = ($solarW - $load) / 1000 * 0.95
        $socGain = $chargeKwh / $capacity * 100
        $currentSoc = [math]::Min($currentSoc + $socGain, 100)
    }

    # Floor at 0%
    if ($currentSoc -lt 0) { $currentSoc = 0 }

    $projectedSoc += [math]::Round($currentSoc, 1)

    # Track when SOC crosses 20%
    if ($null -eq $tttHour -and $currentSoc -le 20) {
        $tttHour = $h
    }
}

Write-Log "Simulation complete. TTT hour=$tttHour, final SOC=$($projectedSoc[-1])%"

# ============================================================
# Step 3: Post sensor.battery_projection to HA
# ============================================================

$sensorBody = @{
    state      = if ($null -ne $tttHour) { "$tttHour" } else { "48+" }
    attributes = @{
        friendly_name   = "Battery Projection"
        icon            = "mdi:chart-timeline-variant"
        hours           = $hours
        projected_soc   = $projectedSoc
        projected_solar = $projectedSolar
        projected_load  = $projectedLoad
        ttt_hour        = $tttHour
        current_soc     = $soc
        current_load    = $load
        cloud_entries   = $cloudData.Count
        last_updated    = (Get-Date).ToString("o")
    }
} | ConvertTo-Json -Depth 5

try {
    $null = Invoke-WebRequest `
        -Uri "$haBase/api/states/sensor.battery_projection" `
        -Method POST -Headers $haHeaders `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($sensorBody)) `
        -UseBasicParsing -TimeoutSec 15
    Write-Log "sensor.battery_projection updated"
} catch {
    Write-Log "Failed to update sensor: $($_.Exception.Message)" "ERROR"
}
