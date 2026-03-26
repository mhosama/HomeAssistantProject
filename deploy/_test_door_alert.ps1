$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

$haHeaders = @{
    "Authorization" = "Bearer $($Config.HA_TOKEN)"
    "Content-Type"  = "application/json"
}
$baseUrl = "http://$($Config.HA_IP):8123"

# TTS alert
Write-Host "Sending TTS alert to kitchen speaker..."
$ttsJson = @{
    entity_id = "tts.google_translate_en_com"
    media_player_entity_id = "media_player.kitchen_speaker"
    message = "Warning. The inverter room temperature is 27 degrees and the door is closed. Please open the inverter room door."
} | ConvertTo-Json -Compress

$resp = Invoke-WebRequest -Uri "$baseUrl/api/services/tts/speak" -Method POST -Headers $haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($ttsJson)) -UseBasicParsing -TimeoutSec 30
Write-Host "TTS sent (HTTP $($resp.StatusCode))"

# Phone notification
Write-Host "Sending phone notification..."
$notifyJson = @{
    title = "Inverter Room Door Closed"
    message = "Inverter room is at 27°C and the door is closed. Please open it."
} | ConvertTo-Json -Compress

$resp = Invoke-WebRequest -Uri "$baseUrl/api/services/notify/mobile_app_samsung_phone" -Method POST -Headers $haHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($notifyJson)) -UseBasicParsing -TimeoutSec 30
Write-Host "Phone notification sent (HTTP $($resp.StatusCode))"

Write-Host "Done! Check kitchen speaker + phone."
