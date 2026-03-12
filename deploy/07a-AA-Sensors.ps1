<#
.SYNOPSIS
    Create template sensors for Android Auto favorites.

.DESCRIPTION
    Creates two template sensors that combine multiple entity values for display
    on the Android Auto favorites screen via the HA Companion App:
    1. Solar vs Load - shows solar generation and house load in one entity
    2. Pool Temperature - shows inlet and outlet water temps from AquaTemp heat pump

.EXAMPLE
    .\07a-AA-Sensors.ps1
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

# ============================================================
# REST helper
# ============================================================

function Invoke-HAREST {
    param([string]$Endpoint, [string]$Method = "GET", [string]$JsonBody = $null)
    $uri = "http://$($Config.HA_IP):8123$Endpoint"
    $headers = @{ "Authorization" = "Bearer $($Config.HA_TOKEN)"; "Content-Type" = "application/json" }
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($JsonBody) { $params.Body = $JsonBody }
    try { return Invoke-RestMethod @params } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Fail "REST $Method $Endpoint -> HTTP $status"
        return $null
    }
}

# ============================================================
# Template sensor creator
# ============================================================

function New-TemplateSensor {
    param(
        [string]$Name,
        [string]$StateTemplate,
        [string]$Unit = "",
        [string]$DeviceClass = "",
        [string]$StateClass = ""
    )

    Write-Info "Creating: $Name..."

    $flowBody = @{ handler = "template" } | ConvertTo-Json
    $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody
    if (-not $flow) { Write-Fail "Could not start config flow for $Name"; return $false }

    $selectBody = @{ next_step_id = "sensor" } | ConvertTo-Json
    $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody $selectBody

    $sensorData = @{ name = $Name; state = $StateTemplate }
    if ($Unit)        { $sensorData.unit_of_measurement = $Unit }
    if ($DeviceClass) { $sensorData.device_class = $DeviceClass }
    if ($StateClass)  { $sensorData.state_class = $StateClass }

    $result = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($flow.flow_id)" -Method "POST" -JsonBody ($sensorData | ConvertTo-Json)
    if ($result -and $result.type -eq "create_entry") {
        Write-Success "$Name created"
        return $true
    } else {
        Write-Fail "Failed to create $Name"
        Write-Host "  Result: $($result | ConvertTo-Json -Compress)" -ForegroundColor Gray
        return $false
    }
}

# ============================================================
# Check existing template sensors
# ============================================================

Write-Step "Checking existing template sensors"

$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$existingTemplates = @()
if ($existingEntries) {
    $existingTemplates = $existingEntries | Where-Object { $_.domain -eq "template" } | ForEach-Object { $_.title }
}

Write-Info "Existing template sensors: $($existingTemplates -join ', ')"

# ============================================================
# Sensor 1: Solar vs Load
# ============================================================

Write-Step "Step 1: Create Solar vs Load sensor"

$solarName = "Solar vs Load"

if ($existingTemplates -contains $solarName) {
    Write-Success "$solarName already exists - skipping"
} else {
    $solarTemplate = "Solar {{ states('sensor.solar_total_generation') }}W / Load {{ states('sensor.solar_total_load') }}W"
    $null = New-TemplateSensor -Name $solarName -StateTemplate $solarTemplate
}

# ============================================================
# Sensor 2: Pool Temperature
# ============================================================

Write-Step "Step 2: Create Pool Temperature sensor"

$poolName = "Pool Temperature"

if ($existingTemplates -contains $poolName) {
    Write-Success "$poolName already exists - skipping"
} else {
    $poolTemplate = "In {{ states('sensor.289c6e4f7352_inlet_water_temp_t02') }}°C / Out {{ states('sensor.289c6e4f7352_outlet_water_temp_t03') }}°C"
    $null = New-TemplateSensor -Name $poolName -StateTemplate $poolTemplate
}

# ============================================================
# Step 3: Verify sensors
# ============================================================

Write-Step "Step 3: Verify new sensors"

Start-Sleep -Seconds 3

$sensors = @(
    @{ Id = "sensor.solar_vs_load"; Name = "Solar vs Load" },
    @{ Id = "sensor.pool_temperature"; Name = "Pool Temperature" }
)

foreach ($s in $sensors) {
    $state = Invoke-HAREST -Endpoint "/api/states/$($s.Id)"
    if ($state) {
        Write-Success "$($s.Name): $($state.state)"
    } else {
        Write-Fail "$($s.Name) not found - may need a moment to initialize"
    }
}

# ============================================================
# Summary
# ============================================================

Write-Step "Done!"
Write-Host ""
Write-Host "  Template sensors created for Android Auto favorites." -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps (on your phone):" -ForegroundColor Yellow
Write-Host "    1. Open HA Companion App" -ForegroundColor White
Write-Host "    2. For each entity below, tap it > More Info > 'Add to' > Automotive favorite:" -ForegroundColor White
Write-Host "       - sensor.solar_vs_load" -ForegroundColor White
Write-Host "       - sensor.pool_temperature" -ForegroundColor White
Write-Host "       - switch.sonoff_100114809c  (Visitor Gate)" -ForegroundColor White
Write-Host "       - switch.sonoff_1001f8b132  (Pool Pump)" -ForegroundColor White
Write-Host "       - sensor.sonoff_a48007a2b0_temperature  (Inverter Room Temp)" -ForegroundColor White
Write-Host ""
