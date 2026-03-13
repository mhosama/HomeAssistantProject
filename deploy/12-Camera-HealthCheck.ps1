<#
.SYNOPSIS
    Check camera health and reload disconnected camera integrations.

.DESCRIPTION
    Runs every 30 minutes via Windows Scheduled Task (HA-CameraHealthCheck).
    - Checks all camera entities for 'unavailable' state
    - Reloads Tapo config entries that are in setup_retry or have unavailable cameras
    - Restarts ffmpeg for YAML-based gate cameras that are unavailable
    - Logs all actions and results

.EXAMPLE
    .\12-Camera-HealthCheck.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

$logDir  = Join-Path $scriptDir "logs"
$logFile = Join-Path $logDir "camera_healthcheck.log"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    Write-Host "  [$Level] $Message"
}

# Trim log at 1MB
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
    $lines = Get-Content $logFile -Tail 500
    $lines | Set-Content $logFile
}

# ============================================================
# HA API helpers
# ============================================================

$haBase = "http://$($Config.HA_IP):8123"
$headers = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}

# Quick connectivity check
try {
    $null = Invoke-RestMethod -Uri "$haBase/api/" -Headers $headers -TimeoutSec 5
} catch {
    Write-Log "HA not accessible - aborting" "ERROR"
    exit 1
}

# ============================================================
# Check camera states
# ============================================================

Write-Log "=== Camera health check starting ==="

$allStates = Invoke-RestMethod -Uri "$haBase/api/states" -Headers $headers -TimeoutSec 10
$cameras = $allStates | Where-Object { $_.entity_id -like "camera.*" }

$unavailable = @()
$healthy = @()

foreach ($cam in $cameras) {
    if ($cam.state -eq "unavailable") {
        $unavailable += $cam
    } else {
        $healthy += $cam
    }
}

Write-Log "Cameras: $($healthy.Count) healthy, $($unavailable.Count) unavailable"

if ($unavailable.Count -eq 0) {
    Write-Log "All cameras healthy - nothing to do"
    Write-Log "=== Done ==="
    exit 0
}

foreach ($cam in $unavailable) {
    Write-Log "UNAVAILABLE: $($cam.entity_id)" "WARN"
}

# ============================================================
# Reload Tapo config entries with problems
# ============================================================

$configEntries = Invoke-RestMethod -Uri "$haBase/api/config/config_entries/entry" -Headers $headers -TimeoutSec 10
$tapoEntries = $configEntries | Where-Object { $_.domain -eq "tapo_control" }

# Check if any Tapo cameras are unavailable
$tapoUnavailable = $unavailable | Where-Object {
    $_.entity_id -match "(chickens|backyard|back_door|veggie_garden|dining_room|kitchen|lawn)" -and
    $_.entity_id -like "camera.*"
}

if ($tapoUnavailable.Count -gt 0 -or ($tapoEntries | Where-Object { $_.state -ne "loaded" })) {
    # Reload all Tapo config entries - the reload is safe, fast, and idempotent
    foreach ($entry in $tapoEntries) {
        Write-Log "Reloading Tapo entry: $($entry.title) (state: $($entry.state))"
        try {
            $null = Invoke-WebRequest `
                -Uri "$haBase/api/config/config_entries/entry/$($entry.entry_id)/reload" `
                -Method POST -Headers $headers -UseBasicParsing -TimeoutSec 30
            Write-Log "Reload OK: $($entry.title)"
        } catch {
            Write-Log "Reload FAILED: $($entry.title) - $($_.Exception.Message)" "ERROR"
        }
        Start-Sleep -Seconds 2
    }
} else {
    Write-Log "No Tapo cameras need reload"
}

# ============================================================
# Restart ffmpeg for YAML-based gate cameras
# ============================================================

$gateUnavailable = @($unavailable | Where-Object {
    $_.entity_id -in @("camera.main_gate_camera", "camera.visitor_gate_camera", "camera.pool_camera", "camera.garage_camera", "camera.lounge_camera", "camera.street_camera")
})

if ($gateUnavailable.Count -gt 0) {
    foreach ($gate in $gateUnavailable) {
        Write-Log "Restarting ffmpeg for $($gate.entity_id)"
        $body = @{ entity_id = $gate.entity_id } | ConvertTo-Json
        try {
            $null = Invoke-WebRequest `
                -Uri "$haBase/api/services/ffmpeg/restart" `
                -Method POST -Headers $headers `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -UseBasicParsing -TimeoutSec 30
            Write-Log "ffmpeg restart OK: $($gate.entity_id)"
        } catch {
            Write-Log "ffmpeg restart FAILED: $($gate.entity_id) - $($_.Exception.Message)" "ERROR"
        }
    }
}

# ============================================================
# Reload EZVIZ if any farm cameras are unavailable
# ============================================================

$ezvizUnavailable = @($unavailable | Where-Object { $_.entity_id -like "camera.farm_camera_*" })
if ($ezvizUnavailable.Count -gt 0) {
    $ezvizEntry = $configEntries | Where-Object { $_.domain -eq "ezviz" } | Select-Object -First 1
    if ($ezvizEntry) {
        Write-Log "Reloading EZVIZ config entry: $($ezvizEntry.title) ($($ezvizEntry.entry_id))"
        try {
            $null = Invoke-WebRequest `
                -Uri "$haBase/api/config/config_entries/entry/$($ezvizEntry.entry_id)/reload" `
                -Method POST -Headers $headers -UseBasicParsing -TimeoutSec 30
            Write-Log "EZVIZ reload OK"
        } catch {
            Write-Log "EZVIZ reload FAILED: $($_.Exception.Message)" "ERROR"
        }
    }
}

# ============================================================
# Wait and verify
# ============================================================

Write-Log "Waiting 20s for cameras to reconnect..."
Start-Sleep -Seconds 20

$allStates2 = Invoke-RestMethod -Uri "$haBase/api/states" -Headers $headers -TimeoutSec 10
$cameras2 = $allStates2 | Where-Object { $_.entity_id -like "camera.*" }

$recovered = 0
$stillDown = 0
foreach ($cam in $unavailable) {
    $current = $cameras2 | Where-Object { $_.entity_id -eq $cam.entity_id }
    if ($current -and $current.state -ne "unavailable") {
        Write-Log "RECOVERED: $($cam.entity_id) => $($current.state)"
        $recovered++
    } else {
        Write-Log "STILL DOWN: $($cam.entity_id)" "WARN"
        $stillDown++
    }
}

Write-Log "=== Done: $recovered recovered, $stillDown still unavailable ==="
