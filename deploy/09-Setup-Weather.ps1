<#
.SYNOPSIS
    One-time setup for daily weather briefing via yr.no + Gemini.

.DESCRIPTION
    Creates the sensor.weather_briefing entity in HA and registers a
    Windows Scheduled Task (HA-RefreshWeather) to run 09a-Refresh-Weather.ps1
    daily at 04:15 (before news refresh at 04:30).

    Run this ONCE after the project is deployed.

.EXAMPLE
    .\09-Setup-Weather.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN", "GeminiApiKey")

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
# STEP 1: Create weather briefing sensor
# ============================================================

Write-Step "1/2 - Creating Weather Briefing Sensor"

$sensor = @{
    entity_id  = "sensor.weather_briefing"
    state      = "Waiting for first weather update"
    attributes = @{
        friendly_name = "Weather Briefing"
        icon          = "mdi:weather-partly-cloudy"
    }
}

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

# ============================================================
# STEP 2: Register Windows Scheduled Task
# ============================================================

Write-Step "2/2 - Registering Scheduled Task"

$taskName = "HA-RefreshWeather"
$scriptPath = Join-Path $scriptDir "09a-Refresh-Weather.ps1"

Write-Info "Script path: $scriptPath"

# Check if task already exists
try {
    $existingTask = schtasks /query /tn $taskName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Task '$taskName' already exists, deleting..."
        schtasks /delete /tn $taskName /f 2>&1 | Out-Null
    }
} catch {
    # Task doesn't exist, that's fine
}

Write-Info "Creating scheduled task '$taskName' (daily at 04:15)..."
$result = schtasks /create /tn $taskName /tr "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" /sc daily /st 04:15 /ru SYSTEM /f
if ($LASTEXITCODE -eq 0) {
    Write-Success "Scheduled task '$taskName' created"
} else {
    Write-Fail "Failed to create scheduled task (run as admin for SYSTEM account, or remove /ru SYSTEM)"
    Write-Info "Manual command: schtasks /create /tn `"$taskName`" /tr `"powershell -ExecutionPolicy Bypass -File $scriptPath`" /sc daily /st 04:15"
}

# ============================================================
# Create logs directory
# ============================================================

$logsDir = Join-Path $scriptDir "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    Write-Success "Created logs directory: $logsDir"
}

# ============================================================
# Summary
# ============================================================

Write-Step "Weather Briefing Setup Complete"

Write-Host ""
Write-Host "  Sensor created:" -ForegroundColor Green
Write-Host "    - sensor.weather_briefing (Weather Briefing)" -ForegroundColor White
Write-Host ""
Write-Host "  Scheduled task: $taskName (daily at 04:15)" -ForegroundColor Green
Write-Host ""
Write-Host "  Daily execution order:" -ForegroundColor Yellow
Write-Host "    04:15  HA-RefreshWeather  -> yr.no + Gemini -> sensor.weather_briefing" -ForegroundColor White
Write-Host "    04:30  HA-RefreshNews     -> RSS + automation rewrite (includes weather)" -ForegroundColor White
Write-Host "    05:00  Morning Greeting   -> TTS: battery + weather + Sky News" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Run 09a-Refresh-Weather.ps1 manually to test" -ForegroundColor Yellow
Write-Host "    2. Check Developer Tools > States for sensor.weather_briefing" -ForegroundColor Yellow
Write-Host "    3. Check logs at deploy/logs/weather_briefing.log" -ForegroundColor Yellow
Write-Host ""
