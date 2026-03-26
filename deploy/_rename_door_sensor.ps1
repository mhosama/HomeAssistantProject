$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter(30000)
$uri = [Uri]"ws://$($Config.HA_IP):8123/api/websocket"
$ws.ConnectAsync($uri, $cts.Token).Wait()

function WSRecv {
    $all = ""
    do {
        $buf = New-Object byte[] 65536
        $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $buf)
        $r = $ws.ReceiveAsync($seg, $cts.Token).Result
        $all += [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    return $all
}

function WSSend([string]$msg) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
}

$null = WSRecv  # auth_required
WSSend ((@{type="auth"; access_token=$Config.HA_TOKEN} | ConvertTo-Json -Compress))
$auth = WSRecv | ConvertFrom-Json
if ($auth.type -ne "auth_ok") { Write-Host "Auth failed"; exit 1 }
Write-Host "Connected to HA"

# Rename entity
$msg = @{id=1; type="config/entity_registry/update"; entity_id="binary_sensor.sonoff_a48003e73f"; name="Inverter Room Door"} | ConvertTo-Json -Compress
WSSend $msg
$resp = WSRecv | ConvertFrom-Json
if ($resp.success) {
    Write-Host "Successfully renamed door sensor to 'Inverter Room Door'"
} else {
    Write-Host "Rename failed: $($resp.error.message)"
}

$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $cts.Token).Wait()
