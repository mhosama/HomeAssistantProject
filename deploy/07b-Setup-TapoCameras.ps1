<#
.SYNOPSIS
    Discover and set up Tapo cameras via network scan + tapo_control config flow.

.DESCRIPTION
    1. Scan 192.168.0.1-254 for ports 443 + 2020 (ONVIF) to discover cameras
    2. Filter out known non-camera IPs
    3. Abort any stale tapo_control flows
    4. Check existing config entries to skip already-configured cameras
    5. Walk each discovered camera through the multi-step config flow:
       - ip: IP address + control port
       - auth: local camera credentials
       - auth_optional_cloud / auth_cloud_password: cloud password
       - other_options: motion sensor, webhooks, stream settings
    6. Verify camera entities were created

.EXAMPLE
    .\07b-Setup-TapoCameras.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

# ============================================================
# Credentials
# ============================================================

$localUsername = "mhocontrol"
$localPassword = "T3rrabyte"
# Cloud password contains "!" - must be handled carefully in PowerShell
$cloudPassword = 'T3rrabyte!'

# Known non-camera IPs to exclude from scan results
$excludeIPs = @(
    "192.168.0.1",    # Router/gateway
    "192.168.0.156",  # Windows server (Hyper-V host)
    "192.168.0.239",  # HA VM
    "192.168.0.27"    # Samsung TV
)

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
# Step 1: Network scan - discover Tapo cameras
# ============================================================

Write-Step "Step 1: Scan network for Tapo cameras (ports 443 + 2020)"

$subnet = "192.168.0"
$timeout = 500  # ms per connection attempt
$maxThreads = 50

# Scan a given port across all 254 IPs using runspace pool for speed
function Scan-SubnetPort {
    param([string]$Subnet, [int]$Port, [int]$TimeoutMs = 500, [int]$MaxThreads = 50)

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    $scriptBlock = {
        param([string]$IP, [int]$Port, [int]$TimeoutMs)
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($IP, $Port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                $tcp.EndConnect($ar)
                return $IP
            }
        } catch {} finally { $tcp.Close() }
        return $null
    }

    $jobs = @()
    1..254 | ForEach-Object {
        $ip = "$Subnet.$_"
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($scriptBlock).AddArgument($ip).AddArgument($Port).AddArgument($TimeoutMs)
        $jobs += @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $results = @()
    foreach ($j in $jobs) {
        $result = $j.PS.EndInvoke($j.Handle)
        if ($result -and $result[0]) { $results += $result[0] }
        $j.PS.Dispose()
    }
    $pool.Close()
    $pool.Dispose()

    return $results
}

Write-Info "Scanning $subnet.1-254 on port 2020 (ONVIF)..."
$onvifHosts = @(Scan-SubnetPort -Subnet $subnet -Port 2020 -TimeoutMs $timeout -MaxThreads $maxThreads)
Write-Info "Found $($onvifHosts.Count) hosts with port 2020 open: $($onvifHosts -join ', ')"

Write-Info "Scanning $subnet.1-254 on port 443 (HTTPS/Tapo API)..."
$httpsHosts = @(Scan-SubnetPort -Subnet $subnet -Port 443 -TimeoutMs $timeout -MaxThreads $maxThreads)
Write-Info "Found $($httpsHosts.Count) hosts with port 443 open: $($httpsHosts -join ', ')"

# Cameras have BOTH ports open
$cameraIPs = @($onvifHosts | Where-Object { $_ -in $httpsHosts -and $_ -notin $excludeIPs }) | Sort-Object { [int]($_ -split '\.')[-1] }

if ($cameraIPs.Count -eq 0) {
    # Fallback: if no dual-port matches, try ONVIF-only hosts (excluding known non-cameras)
    Write-Info "No dual-port matches. Falling back to ONVIF-only hosts..."
    $cameraIPs = @($onvifHosts | Where-Object { $_ -notin $excludeIPs }) | Sort-Object { [int]($_ -split '\.')[-1] }
}

if ($cameraIPs.Count -eq 0) {
    Write-Fail "No cameras discovered on the network!"
    Write-Host "  Check that cameras are powered on and connected to the 192.168.0.x network." -ForegroundColor Gray
    exit 1
}

# Build camera list with auto-naming
$cameras = @()
$camIndex = 1
foreach ($ip in $cameraIPs) {
    $cameras += @{ Name = "Camera $camIndex"; IP = $ip }
    $camIndex++
}

Write-Success "Discovered $($cameras.Count) probable camera(s):"
foreach ($cam in $cameras) {
    Write-Host "    $($cam.Name): $($cam.IP)" -ForegroundColor White
}

# ============================================================
# Step 2: Abort stale tapo_control flows
# ============================================================

Write-Step "Step 2: Clean up stale flows"

$progressResp = Invoke-HAREST -Endpoint "/api/config/config_entries/flow"
if ($progressResp) {
    $staleFlows = @($progressResp | Where-Object { $_.handler -eq "tapo_control" })
    foreach ($sf in $staleFlows) {
        Write-Info "Aborting stale flow $($sf.flow_id)..."
        $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$($sf.flow_id)" -Method "DELETE"
        Write-Success "Aborted"
    }
    if ($staleFlows.Count -eq 0) { Write-Success "No stale flows" }
} else {
    Write-Info "Could not check for stale flows (non-fatal)"
}

# ============================================================
# Step 3: Get existing config entries to check for duplicates
# ============================================================

Write-Step "Step 3: Check existing config entries"

$existingEntries = Invoke-HAREST -Endpoint "/api/config/config_entries/entry"
$existingTapoIPs = @()
if ($existingEntries) {
    $tapoEntries = @($existingEntries | Where-Object { $_.domain -eq "tapo_control" })
    foreach ($te in $tapoEntries) {
        if ($te.data -and $te.data.host) {
            $existingTapoIPs += $te.data.host
        }
    }
    Write-Info "Found $($tapoEntries.Count) existing tapo_control entries: $($existingTapoIPs -join ', ')"
} else {
    Write-Info "No existing config entries found"
}

# ============================================================
# Step 4: Set up each discovered camera
# ============================================================

$successCount = 0
$skippedCount = 0
$failedCount = 0

foreach ($cam in $cameras) {
    Write-Step "Setting up $($cam.Name) ($($cam.IP))"

    # Check if already configured
    if ($existingTapoIPs -contains $cam.IP) {
        Write-Success "$($cam.Name) already configured - skipping"
        $successCount++
        $skippedCount++
        continue
    }

    # Start config flow
    Write-Info "Starting config flow..."
    $flowBody = @{ handler = "tapo_control" } | ConvertTo-Json
    $flow = Invoke-HAREST -Endpoint "/api/config/config_entries/flow" -Method "POST" -JsonBody $flowBody

    if (-not $flow) {
        Write-Fail "Could not start config flow for $($cam.Name)"
        $failedCount++
        continue
    }

    $flowId = $flow.flow_id
    $stepId = $flow.step_id
    Write-Info "Flow $flowId started, first step: $stepId"

    # Walk through steps dynamically
    $done = $false
    $maxSteps = 10

    for ($i = 0; $i -lt $maxSteps; $i++) {
        Write-Info "Processing step: $stepId"

        $stepBody = $null

        switch -Wildcard ($stepId) {
            "ip" {
                $stepBody = @{ ip_address = $cam.IP; control_port = 443 } | ConvertTo-Json
            }
            "auth" {
                $stepBody = @{ username = $localUsername; password = $localPassword; skip_rtsp = $false } | ConvertTo-Json
            }
            "auth_optional_cloud" {
                # Cloud password has "!" - build JSON as literal string
                $stepBody = '{"cloud_password": "' + $cloudPassword + '"}'
            }
            "auth_cloud_password" {
                # Alternative step name for cloud password
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
                Write-Fail "Unknown step '$stepId' - dumping response:"
                Write-Host "  $($flow | ConvertTo-Json -Depth 5 -Compress)" -ForegroundColor Gray
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
            Write-Fail "Config flow step '$stepId' failed for $($cam.Name)"
            $failedCount++
            $done = $true
            break
        }

        # Check if we got a create_entry result (success)
        if ($flow.type -eq "create_entry") {
            Write-Success "$($cam.Name) configured successfully! Entry: $($flow.title)"
            $successCount++
            $done = $true
            break
        }

        # Check for abort
        if ($flow.type -eq "abort") {
            Write-Fail "$($cam.Name) flow aborted: $($flow.reason)"
            $failedCount++
            $done = $true
            break
        }

        # Check for form errors
        if ($flow.errors -and ($flow.errors | Get-Member -MemberType NoteProperty).Count -gt 0) {
            $errJson = $flow.errors | ConvertTo-Json -Compress
            Write-Fail "Errors in step '$stepId': $errJson"

            # Already configured - skip (no point retrying)
            if ($errJson -like "*already_configured*") {
                Write-Info "$($cam.Name) already configured in HA - skipping"
                $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "DELETE"
                $successCount++
                $skippedCount++
                $done = $true
                break
            }

            # Connection failed - device may not be a Tapo camera
            if ($errJson -like "*connection_failed*") {
                Write-Fail "$($cam.Name) connection failed - may not be a Tapo camera"
                $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "DELETE"
                $failedCount++
                $done = $true
                break
            }

            # Auth error - abort to avoid cloud lockout
            if ($stepId -like "auth*") {
                Write-Fail "Auth error - aborting to avoid cloud lockout"
                $null = Invoke-HAREST -Endpoint "/api/config/config_entries/flow/$flowId" -Method "DELETE"
                $failedCount++
                $done = $true
                break
            }
        }

        # Move to next step
        if ($flow.step_id) {
            $stepId = $flow.step_id
        } else {
            Write-Fail "No step_id in response for $($cam.Name)"
            Write-Host "  $($flow | ConvertTo-Json -Depth 5 -Compress)" -ForegroundColor Gray
            $failedCount++
            break
        }
    }

    if (-not $done) {
        Write-Fail "Exceeded max steps for $($cam.Name)"
        $failedCount++
    }
}

# ============================================================
# Step 5: Verify camera entities
# ============================================================

Write-Step "Step 5: Verify camera entities"

Write-Info "Waiting 5 seconds for entities to register..."
Start-Sleep -Seconds 5

$states = Invoke-HAREST -Endpoint "/api/states"
if ($states) {
    $cameraEntities = @($states | Where-Object { $_.entity_id -like "camera.*" })
    Write-Info "Found $($cameraEntities.Count) camera entities:"
    foreach ($ce in $cameraEntities) {
        $state = $ce.state
        $friendly = $ce.attributes.friendly_name
        Write-Host "    $($ce.entity_id) ($friendly) - $state" -ForegroundColor White
    }
} else {
    Write-Info "Could not query states"
}

# ============================================================
# Done
# ============================================================

Write-Step "Done! ($successCount OK, $skippedCount skipped, $failedCount failed out of $($cameras.Count) discovered)"
Write-Host ""
Write-Host "  Verify:" -ForegroundColor White
Write-Host "    1. HA UI > Settings > Devices & Services > Tapo: Control" -ForegroundColor Gray
Write-Host "    2. Developer Tools > States > camera.*" -ForegroundColor Gray
Write-Host "    3. Try loading a camera stream in a dashboard" -ForegroundColor Gray
Write-Host ""
