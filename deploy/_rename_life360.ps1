<#
.SYNOPSIS
    Rename Life360 entity friendly names via HA Entity Registry WebSocket API.

.DESCRIPTION
    Renames:
      - device_tracker.life360_mauritz_kloppers_2 -> "Oupa"
      - device_tracker.life360_lizette_kloppers   -> "Ouma"
      - device_tracker.life360_chandre_kloppers   -> "Chandre" (registry name; TTS uses Shandrey)

    Uses WebSocket config/entity_registry/update command.
    This persists across HA restarts (stored in entity registry).

.EXAMPLE
    .\deploy\_rename_life360.ps1
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"
Assert-Config -RequiredKeys @("HA_IP", "HA_TOKEN")

function Write-Step    { param([string]$Message); Write-Host ""; Write-Host "===================================================" -ForegroundColor Cyan; Write-Host " $Message" -ForegroundColor Cyan; Write-Host "===================================================" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

# WebSocket helpers
$script:ws = $null
$script:cts = $null
$script:wsId = 0

function Connect-HAWS {
    $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
    $script:cts = New-Object System.Threading.CancellationTokenSource
    $script:cts.CancelAfter(120000)
    $script:wsId = 0
    $uri = [Uri]"ws://$($Config.HA_IP):8123/api/websocket"
    Write-Info "Connecting to WebSocket..."
    $script:ws.ConnectAsync($uri, $script:cts.Token).Wait()
    $null = Receive-HAWS
    $authMsg = @{type = "auth"; access_token = $Config.HA_TOKEN} | ConvertTo-Json -Compress
    Send-HAWS $authMsg
    $authResp = Receive-HAWS | ConvertFrom-Json
    if ($authResp.type -ne "auth_ok") { Write-Fail "Auth failed"; exit 1 }
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

function Invoke-WSCommand {
    param([string]$Type, [hashtable]$Extra = @{})
    $script:wsId++
    $msg = @{ id = $script:wsId; type = $Type } + $Extra
    Send-HAWS ($msg | ConvertTo-Json -Depth 20 -Compress)
    $resp = Receive-HAWS | ConvertFrom-Json
    return $resp
}

function Disconnect-HAWS {
    if ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $script:cts.Token).Wait()
    }
}

# Entity renames
$renames = @(
    @{ EntityId = "device_tracker.life360_mauritz_kloppers";   NewName = "Mauritz" }
    @{ EntityId = "device_tracker.life360_mauritz_kloppers_2"; NewName = "Oupa" }
    @{ EntityId = "device_tracker.life360_lizette_kloppers";   NewName = "Ouma" }
    @{ EntityId = "device_tracker.life360_chandre_kloppers";   NewName = "Chandre" }
)

Write-Step "Renaming Life360 Entities via WebSocket"

Connect-HAWS

foreach ($rename in $renames) {
    $entityId = $rename.EntityId
    $newName = $rename.NewName

    Write-Info "Renaming $entityId -> '$newName'"

    $result = Invoke-WSCommand -Type "config/entity_registry/update" -Extra @{
        entity_id = $entityId
        name      = $newName
    }

    if ($result.success) {
        $updatedName = $result.result.name
        Write-Success "Renamed $entityId -> '$updatedName'"
    } else {
        Write-Fail "Failed to rename $entityId : $($result.error.message)"
    }
}

# Verify by listing
Write-Step "Verifying Renames"

$listResult = Invoke-WSCommand -Type "config/entity_registry/list"
if ($listResult.success) {
    $targetIds = $renames | ForEach-Object { $_.EntityId }
    $updated = $listResult.result | Where-Object { $targetIds -contains $_.entity_id }
    foreach ($e in $updated) {
        $displayName = if ($e.name) { $e.name } else { $e.original_name }
        Write-Success "$($e.entity_id) -> name='$($e.name)' (displayed as '$displayName')"
    }
}

Disconnect-HAWS

Write-Host ""
Write-Host "  Done! Check Developer Tools > States to verify the new friendly names." -ForegroundColor Green
Write-Host ""
