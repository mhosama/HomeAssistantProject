<#
.SYNOPSIS
    Install essential HA add-ons and HACS via the WebSocket API.

.DESCRIPTION
    Run AFTER completing onboarding in the HA web UI.
    Requires HA_IP and HA_TOKEN to be set in config.ps1.

    Installs: File Editor, Terminal & SSH, Samba Share, HACS

.EXAMPLE
    .\02-Setup-Addons.ps1
#>

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
}

function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

# ============================================================
# WebSocket API helpers
# ============================================================

$script:ws = $null
$script:cts = $null
$script:wsId = 0

function Connect-HAWS {
    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $script:cts.CancelAfter(300000)  # 5 min global timeout
    $script:wsId = 0

    $uri = [Uri]"ws://$($Config.HA_IP):8123/api/websocket"
    Write-Info "Connecting to WebSocket at $uri..."
    $script:ws.ConnectAsync($uri, $script:cts.Token).Wait()

    # Receive auth_required
    $null = Receive-HAWS

    # Authenticate
    $authMsg = @{type = "auth"; access_token = $Config.HA_TOKEN} | ConvertTo-Json -Compress
    Send-HAWS $authMsg
    $authResp = Receive-HAWS | ConvertFrom-Json

    if ($authResp.type -ne "auth_ok") {
        Write-Fail "WebSocket authentication failed: $($authResp | ConvertTo-Json -Compress)"
        exit 1
    }
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

function Invoke-Supervisor {
    param(
        [string]$Endpoint,
        [string]$Method = "get",
        [hashtable]$Data = $null
    )
    $script:wsId++
    $msg = @{
        id       = $script:wsId
        type     = "supervisor/api"
        endpoint = $Endpoint
        method   = $Method
    }
    if ($Data) { $msg.data = $Data }

    Send-HAWS ($msg | ConvertTo-Json -Depth 10 -Compress)
    $resp = Receive-HAWS | ConvertFrom-Json
    return $resp
}

function Disconnect-HAWS {
    if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $script:ws.CloseAsync(
            [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "",
            $script:cts.Token
        ).Wait()
    }
}

# ============================================================
# Connect
# ============================================================

Write-Step "Connecting to Home Assistant"
Connect-HAWS

# ============================================================
# Install Add-ons
# ============================================================

$addons = @(
    @{ Slug = "core_configurator"; Name = "File Editor" },
    @{ Slug = "core_ssh";          Name = "Terminal & SSH" },
    @{ Slug = "core_samba";        Name = "Samba Share" }
)

foreach ($addon in $addons) {
    Write-Step "Add-on: $($addon.Name)"

    # Get current info
    $info = Invoke-Supervisor -Endpoint "/addons/$($addon.Slug)/info"

    if (-not $info.success) {
        Write-Fail "Could not get info for $($addon.Slug)"
        continue
    }

    $state = $info.result.state

    # Install if needed
    if ($state -eq "unknown" -and -not $info.result.version) {
        Write-Info "Installing..."
        $result = Invoke-Supervisor -Endpoint "/addons/$($addon.Slug)/install" -Method "post"
        if ($result.success) {
            Write-Success "Installed"
            Write-Info "Waiting for image pull..."
            Start-Sleep -Seconds 15
        } else {
            Write-Fail "Install failed: $($result.error.message)"
            continue
        }
    } else {
        Write-Success "Already installed (v$($info.result.version))"
    }

    # Start if not running
    $info = Invoke-Supervisor -Endpoint "/addons/$($addon.Slug)/info"
    if ($info.result.state -ne "started") {
        Write-Info "Starting..."
        $result = Invoke-Supervisor -Endpoint "/addons/$($addon.Slug)/start" -Method "post"

        # Wait for startup
        for ($i = 1; $i -le 12; $i++) {
            Start-Sleep -Seconds 5
            $info = Invoke-Supervisor -Endpoint "/addons/$($addon.Slug)/info"
            if ($info.result.state -eq "started") { break }
            Write-Host "    Waiting for startup ($i)..." -ForegroundColor DarkGray
        }

        if ($info.result.state -eq "started") {
            Write-Success "Running"
        } else {
            Write-Info "State: $($info.result.state) (may still be starting)"
        }
    } else {
        Write-Success "Already running"
    }

    # Enable in sidebar
    if (-not $info.result.ingress_panel) {
        Invoke-Supervisor -Endpoint "/addons/$($addon.Slug)/options" -Method "post" -Data @{ ingress_panel = $true } | Out-Null
        Write-Success "Added to sidebar"
    }
}

# ============================================================
# Configure Samba
# ============================================================

Write-Step "Configuring Samba Share"

$sambaInfo = Invoke-Supervisor -Endpoint "/addons/core_samba/info"
if ($sambaInfo.success -and $sambaInfo.result.state -eq "started") {
    $result = Invoke-Supervisor -Endpoint "/addons/core_samba/options" -Method "post" -Data @{
        options = @{
            workgroup   = "WORKGROUP"
            username    = "homeassistant"
            password    = "homeassistant"
            allow_hosts = @("192.168.0.0/24")
        }
    }
    if ($result.success) {
        Write-Success "Samba configured (user: homeassistant / pass: homeassistant)"
        Write-Info "Access: \\$($Config.HA_IP)\config"
        Invoke-Supervisor -Endpoint "/addons/core_samba/restart" -Method "post" | Out-Null
    } else {
        Write-Info "Samba config update: $($result.error.message)"
    }
}

# ============================================================
# Install HACS
# ============================================================

Write-Step "Installing HACS (Home Assistant Community Store)"

# Check if HACS is already present
$headers = @{ "Authorization" = "Bearer $($Config.HA_TOKEN)"; "Content-Type" = "application/json" }
$services = Invoke-RestMethod -Uri "http://$($Config.HA_IP):8123/api/services" -Headers $headers -UseBasicParsing
$hacsInstalled = ($services | Where-Object { $_.domain -eq "hacs" }).Count -gt 0

if ($hacsInstalled) {
    Write-Success "HACS is already installed"
} else {
    Write-Info "HACS must be installed via the Terminal add-on."
    Write-Info "Sending install command to SSH add-on..."

    # Execute HACS install via the SSH addon command API
    $result = Invoke-Supervisor -Endpoint "/addons/core_ssh/stdin" -Method "post" -Data @{
        command = "wget -O - https://get.hacs.xyz | bash -"
    }

    Write-Info ""
    Write-Info "HACS installation requires manual steps:"
    Write-Info ""
    Write-Info "  1. Open Terminal & SSH from the HA sidebar"
    Write-Info "  2. Run:  wget -O - https://get.hacs.xyz | bash -"
    Write-Info "  3. Restart HA:  Settings > System > Restart"
    Write-Info "  4. Add HACS:    Settings > Devices & Services > Add Integration"
    Write-Info "     Search for 'HACS' and follow the GitHub auth flow"
    Write-Info ""
}

# ============================================================
# Summary
# ============================================================

Write-Step "Setup Complete!"

# Show final status
foreach ($addon in $addons) {
    $info = Invoke-Supervisor -Endpoint "/addons/$($addon.Slug)/info"
    $stateColor = if ($info.result.state -eq "started") { "Green" } else { "Yellow" }
    Write-Host "  $($addon.Name.PadRight(20)) $($info.result.state)" -ForegroundColor $stateColor
}
Write-Host "  HACS                 $(if ($hacsInstalled) { 'installed' } else { 'manual install needed' })" -ForegroundColor $(if ($hacsInstalled) { "Green" } else { "Yellow" })

Write-Host ""
Write-Host "  Samba access: \\$($Config.HA_IP)\config" -ForegroundColor White
Write-Host ""
Write-Host "  Next: Install HACS (if needed), then run 03-Setup-Integrations.ps1" -ForegroundColor Cyan
Write-Host ""

Disconnect-HAWS
