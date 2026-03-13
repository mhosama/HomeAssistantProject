<#
.SYNOPSIS
    Delete stale Tapo camera config entries and recreate with updated IPs.

.DESCRIPTION
    Camera IPs changed due to DHCP reassignment. This script:
    1. Finds and deletes the 5 stale Tapo config entries (by IP match)
    2. Recreates them with new IPs using the tapo_control config flow
    3. Adds a new Lawn camera (.102)
    4. Skips Kitchen (.249) which hasn't changed

    IP mapping:
      Chickens:     .101 -> .209
      Backyard:     .106 -> .113
      Back Door:    .111 -> .101
      Veggie Garden: .195 -> .106
      Dining Room:  .214 -> .191
      Kitchen:      .249 -> .249 (no change, skip)
      Lawn (NEW):    —  -> .102

.EXAMPLE
    .\13-Update-CameraIPs.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# Camera IP mapping (old -> new)
# ============================================================

$cameraUpdates = @(
    @{ Name = "Chickens";      OldIP = "192.168.0.101"; NewIP = "192.168.0.209" }
    @{ Name = "Backyard";      OldIP = "192.168.0.106"; NewIP = "192.168.0.113" }
    @{ Name = "Back Door";     OldIP = "192.168.0.111"; NewIP = "192.168.0.101" }
    @{ Name = "Veggie Garden"; OldIP = "192.168.0.195"; NewIP = "192.168.0.106" }
    @{ Name = "Dining Room";   OldIP = "192.168.0.214"; NewIP = "192.168.0.191" }
)

$newCameras = @(
    @{ Name = "Lawn Camera"; IP = "192.168.0.102" }
)

# Credentials (same as 07b)
$localUsername = "mhocontrol"
$localPassword = "T3rrabyte"
$cloudPassword = 'T3rrabyte!'

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
# Tapo config flow helper (same multi-step pattern as 07b)
# ============================================================

function New-TapoConfigEntry {
    param([string]$Name, [string]$IP)

    Write-Info "Starting config flow for $Name ($IP)..."
    $flowBody = @{ handler = "tapo_control" } | ConvertTo-Json
    $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody

    if (-not $flow) {
        Write-Fail "Could not start config flow for $Name"
        return $false
    }

    $flowId = $flow.flow_id
    $stepId = $flow.step_id
    Write-Info "Flow $flowId started, first step: $stepId"

    $done = $false
    $success = $false

    for ($i = 0; $i -lt 10; $i++) {
        Write-Info "Processing step: $stepId"

        $stepBody = $null

        switch -Wildcard ($stepId) {
            "ip" {
                $stepBody = @{ ip_address = $IP; control_port = 443 } | ConvertTo-Json
            }
            "auth" {
                $stepBody = @{ username = $localUsername; password = $localPassword; skip_rtsp = $false } | ConvertTo-Json
            }
            "auth_optional_cloud" {
                $stepBody = '{"cloud_password": "' + $cloudPassword + '"}'
            }
            "auth_cloud_password" {
                $stepBody = '{"cloud_password": "' + $cloudPassword + '"}'
            }
            "other_options" {
                $stepBody = @{
                    enable_motion_sensor   = $true
                    enable_webhooks        = $true
                    enable_stream          = $true
                    enable_time_sync       = $false
                    enable_sound_detection = $false
                } | ConvertTo-Json
            }
            default {
                Write-Fail "Unknown step '$stepId'"
                $done = $true
            }
        }

        if ($done) { break }

        if (-not $stepBody) {
            Write-Fail "No body for step '$stepId'"
            break
        }

        Write-Info "Submitting step '$stepId'..."
        $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "POST" -JsonBody $stepBody

        if (-not $flow) {
            Write-Fail "Config flow step '$stepId' failed for $Name"
            $done = $true
            break
        }

        if ($flow.type -eq "create_entry") {
            Write-Success "$Name configured successfully! Entry: $($flow.title)"
            $success = $true
            $done = $true
            break
        }

        if ($flow.type -eq "abort") {
            Write-Fail "$Name flow aborted: $($flow.reason)"
            $done = $true
            break
        }

        if ($flow.errors -and ($flow.errors | Get-Member -MemberType NoteProperty).Count -gt 0) {
            $errJson = $flow.errors | ConvertTo-Json -Compress
            Write-Fail "Errors in step '$stepId': $errJson"
            $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "DELETE"
            $done = $true
            break
        }

        if ($flow.step_id) {
            $stepId = $flow.step_id
        } else {
            Write-Fail "No step_id in response for $Name"
            break
        }
    }

    return $success
}

# ============================================================
# Step 1: Get existing Tapo config entries
# ============================================================

Write-Step "Step 1: Find existing Tapo config entries"

$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
if (-not $existingEntries) {
    Write-Fail "Could not read config entries"
    exit 1
}

$tapoEntries = @($existingEntries | Where-Object { $_.domain -eq "tapo_control" })
Write-Info "Found $($tapoEntries.Count) tapo_control config entries"

# Build a lookup of IP -> entry_id
$tapoByIP = @{}
foreach ($te in $tapoEntries) {
    if ($te.data -and $te.data.host) {
        $tapoByIP[$te.data.host] = $te
        Write-Info "  $($te.title) -> $($te.data.host) (entry_id: $($te.entry_id), state: $($te.state))"
    }
}

# ============================================================
# Step 2: Delete stale entries
# ============================================================

Write-Step "Step 2: Delete stale Tapo config entries"

$deleteCount = 0
foreach ($cam in $cameraUpdates) {
    $entry = $tapoByIP[$cam.OldIP]
    if ($entry) {
        Write-Info "Deleting $($cam.Name) ($($cam.OldIP)) - entry_id: $($entry.entry_id)..."
        $result = Invoke-HAREST -Endpoint "/api/config/config_entries/entry/$($entry.entry_id)" -Method "DELETE"
        if ($result -ne $null -or $true) {
            # DELETE may return empty body on success
            Write-Success "Deleted $($cam.Name)"
            $deleteCount++
        }
    } else {
        Write-Info "$($cam.Name) not found at old IP $($cam.OldIP) - may already be removed"
    }
}

Write-Info "Deleted $deleteCount entries"

# Wait for HA to process deletions
Write-Info "Waiting 5 seconds for HA to process deletions..."
Start-Sleep -Seconds 5

# ============================================================
# Step 3: Abort any stale tapo_control flows
# ============================================================

Write-Step "Step 3: Clean up stale flows"

$progressResp = Invoke-HAREST -Endpoint "/api/config/config_entries/flow"
if ($progressResp) {
    $staleFlows = @($progressResp | Where-Object { $_.handler -eq "tapo_control" })
    foreach ($sf in $staleFlows) {
        Write-Info "Aborting stale flow $($sf.flow_id)..."
        $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($sf.flow_id)" -Method "DELETE"
        Write-Success "Aborted"
    }
    if ($staleFlows.Count -eq 0) { Write-Success "No stale flows" }
}

# ============================================================
# Step 4: Recreate cameras with new IPs
# ============================================================

Write-Step "Step 4: Recreate cameras with new IPs"

$successCount = 0
$failedCount = 0

foreach ($cam in $cameraUpdates) {
    Write-Step "Recreating $($cam.Name) at $($cam.NewIP)"
    if (New-TapoConfigEntry -Name $cam.Name -IP $cam.NewIP) {
        $successCount++
    } else {
        $failedCount++
    }
    Start-Sleep -Seconds 2
}

# ============================================================
# Step 5: Add new cameras
# ============================================================

Write-Step "Step 5: Add new cameras"

foreach ($cam in $newCameras) {
    Write-Step "Adding $($cam.Name) at $($cam.IP)"
    if (New-TapoConfigEntry -Name $cam.Name -IP $cam.IP) {
        $successCount++
    } else {
        $failedCount++
    }
    Start-Sleep -Seconds 2
}

# ============================================================
# Step 6: Verify camera entities
# ============================================================

Write-Step "Step 6: Verify camera entities"

Write-Info "Waiting 10 seconds for entities to register..."
Start-Sleep -Seconds 10

$states = Invoke-HAREST -Endpoint "/api/states"
if ($states) {
    $cameraEntities = @($states | Where-Object { $_.entity_id -like "camera.*" })
    Write-Info "Found $($cameraEntities.Count) camera entities:"
    foreach ($ce in ($cameraEntities | Sort-Object entity_id)) {
        $state = $ce.state
        $friendly = $ce.attributes.friendly_name
        $color = if ($state -eq "idle") { "Green" } elseif ($state -eq "unavailable") { "Red" } else { "White" }
        Write-Host "    $($ce.entity_id) ($friendly) - $state" -ForegroundColor $color
    }
}

# ============================================================
# Done
# ============================================================

$total = $cameraUpdates.Count + $newCameras.Count
Write-Step "Done! ($successCount OK, $failedCount failed out of $total cameras)"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Run 07c-Setup-RtspCameras.ps1 to add new RTSP cameras" -ForegroundColor Gray
Write-Host "    2. Run 07d-Add-CameraDashboard.ps1 to update the dashboard" -ForegroundColor Gray
Write-Host "    3. Verify all cameras in HA UI" -ForegroundColor Gray
Write-Host ""
