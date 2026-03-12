# Troubleshooting Guide

Common issues and solutions encountered during setup and operation.

---

## Hyper-V / VM Issues

### VM won't boot - "Secure Boot" error

**Symptom**: VM fails to start with a Secure Boot policy error.

**Solution**: Disable Secure Boot on the VM:
```powershell
Set-VMFirmware -VMName "HomeAssistant" -EnableSecureBoot Off
```

### VM has no network connectivity

**Symptom**: HAOS boots but shows no IP address or can't reach the internet.

**Possible causes**:
1. Virtual switch not configured as External
2. Physical NIC not selected for the switch
3. VLAN tagging mismatch

**Solution**:
```powershell
# Verify switch type
Get-VMSwitch | Select-Object Name, SwitchType

# Should show "External" - if not, recreate:
Remove-VMSwitch -Name "HA-External"
New-VMSwitch -Name "HA-External" -NetAdapterName "Ethernet" -AllowManagementOS $true
```

### HA takes forever to load after VM start

**Symptom**: VM is running but `http://<IP>:8123` shows "Preparing Home Assistant" for a very long time.

**Solution**: First boot can take 10-20 minutes. Subsequent boots are faster. If stuck for over 30 minutes:
1. Check VM console for error messages
2. Verify VM has internet access (needed for initial setup)
3. Try restarting the VM

---

## Home Assistant Issues

### Can't access HA web interface

**Symptom**: Browser can't connect to `http://<IP>:8123`.

**Checklist**:
1. Is the VM running? (`Get-VM -Name "HomeAssistant"`)
2. Does the VM have an IP? (Check VM console)
3. Can you ping the VM from the host? (`ping <HA_IP>`)
4. Is port 8123 blocked by Windows Firewall on the host?
5. Try accessing from the Hyper-V host itself

### HACS installation fails

**Symptom**: The HACS install script fails or HACS doesn't appear after restart.

**Solution**:
1. Ensure you're running the command in the HA Terminal add-on (not the HAOS console)
2. Verify internet access: `ping github.com`
3. Try the manual installation method from HACS documentation
4. Clear browser cache and hard-refresh after HA restart

---

## Integration Issues

### Sunsynk integration not showing data

**Symptom**: Integration configured but entities show "unavailable" or no data.

**Checklist**:
- [ ] Verify Sunsynk portal credentials are correct (log in at mysunsynk.com)
- [ ] Check HA logs for API errors (Settings > System > Logs)
- [ ] Verify inverter serial number is correct
- [ ] Check if Sunsynk API is experiencing downtime
- [ ] Try removing and re-adding the integration

### eWeLink devices not appearing

**Symptom**: Integration configured but no devices discovered.

**Checklist**:
- [ ] Verify eWeLink app credentials are correct
- [ ] Ensure devices are online in the eWeLink app
- [ ] Check if the integration supports your specific device models
- [ ] Look at HA logs for authentication or API errors
- [ ] Some devices may take a few minutes to appear after initial sync

### Tapo camera stream not loading

**Symptom**: Camera entity exists but shows no video feed.

**Checklist**:
- [ ] Verify camera IP is correct and reachable (`ping <camera_ip>`)
- [ ] Confirm RTSP is enabled in Tapo app
- [ ] Test RTSP URL in VLC: `rtsp://username:password@<ip>:554/stream1`
- [ ] Check that camera credentials are correct
- [ ] Ensure camera firmware is up to date

---

## Vision Analysis Issues

### Food sensor not accumulating / showing old data

**Symptom**: `sensor.breakfast_food` shows a single item or stale data from yesterday.

**Checklist**:
1. Check state file: `cat deploy/.vision_state.json` — look at `food_items.breakfast.date` and `.items`
2. Date should match today — if not, items will reset on next detection
3. Check logs: `tail deploy/logs/vision_analysis.log` for "Added new food item" or "already tracked"
4. If state file is corrupt, delete it and let the script recreate: `rm deploy/.vision_state.json`

### Vision/farm sensors show "entity not found" after HA restart

**Symptom**: Dashboard cards show "entity not found" for vision sensors (chicken_count, food sensors, farm_cam sensors, etc.) after a HA restart or power loss.

**Cause**: Sensors created via `POST /api/states` are temporary — they only exist in HA's memory and do NOT survive restarts. Unlike template sensors or integration entities, they have no persistent config.

**Solution**: The scheduled scripts (08a, 10a) will recreate them automatically on their next run. To recreate immediately:
1. Run `08-Setup-VisionAnalysis.ps1` to recreate home vision sensors
2. Run `10-Setup-Ezviz.ps1` to recreate farm vision sensors
3. Or manually POST to `/api/states/{entity_id}` with the initial state

**Prevention**: The runner scripts (08a, 10a) automatically recreate sensors every time they update them, so after one cycle the sensors will be back. The gap is only the time between HA restart and the first scheduled run.

### Vision analysis not running

**Symptom**: Sensors not updating, no new log entries.

**Checklist**:
1. Check scheduled task: `schtasks /query /tn "HA-VisionAnalysis" /v`
2. Check mutex (another instance stuck?): Restart the scheduled task
3. Check Gemini API key in `deploy/config.ps1`
4. Check logs: `deploy/logs/vision_analysis.log`
5. Run manually: `powershell -File deploy\08a-Run-VisionAnalysis.ps1`

---

## PS Remoting Issues

### PS Remoting "Access Denied" after server reboot/power loss

**Symptom**: `New-PSSession` or `Invoke-Command` to the host server returns "Access is denied" even though credentials are correct.

**Cause**: After a server reboot or power loss, WinRM settings, group memberships, or the `LocalAccountTokenFilterPolicy` registry key may be reset.

**Solution**: Run ALL of these on the **server** in an admin PowerShell:
```powershell
Enable-PSRemoting -Force
net localgroup "Remote Management Users" hadeploy /add
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f
Restart-Service WinRM
net user hadeploy "T3rrabyte!"
```

Then on the **dev machine** (admin PS):
```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "DESKTOP-HG724B5" -Force
```

### `New-PSSession` fails but `Invoke-Command` works

**Symptom**: `New-PSSession` returns "Access is denied" but `Invoke-Command -ComputerName` with the same credentials succeeds.

**Solution**: Don't use `New-PSSession` for persistent sessions — use `Invoke-Command -ComputerName` directly. Bundle all remote work into a single `Invoke-Command` call to avoid connection limit issues.

### Bash heredoc breaks PowerShell `$variable\$path` strings

**Symptom**: When running PowerShell from bash, string interpolation like `"$srcDir\$f"` produces `"C:\path\"` (variable lost).

**Solution**: Write the PowerShell to a `.ps1` file and run with `powershell -File script.ps1` instead of passing code inline via bash.

---

## EZVIZ Farm Camera Issues

### `camera_proxy` returns 500 for EZVIZ 4G cameras

**Symptom**: `GET /api/camera_proxy/camera.farm_camera_X` returns HTTP 500. Camera entity shows `supported_features: 0`.

**Cause**: 4G battery cameras have no local RTSP stream. The HA EZVIZ integration creates a camera entity but cannot serve images from it.

**Solution**: Use the EZVIZ cloud API directly to trigger on-demand captures:
1. Login: `POST /v3/users/login/v5` with MD5(password)
2. Capture: `PUT /v3/devconfig/v1/{serial}/{channel}/capture` → returns `picUrl`
3. Download JPEG from `picUrl`

See `deploy/10a-Run-EzvizVision.ps1` for the full implementation.

### EZVIZ `image_proxy` returns stale images

**Symptom**: `image.farm_camera_X_last_motion_image` always returns the same old image.

**Cause**: The image entity only updates when the camera's PIR sensor detects motion. Between events, it serves the same stale snapshot. `ezviz.wake_device` wakes the camera but does NOT trigger a new capture.

**Solution**: Same as above — use the direct EZVIZ cloud capture API instead of HA's image proxy.

### EZVIZ capture error 2009

**Symptom**: Capture API returns code 2009 (Chinese error message).

**Cause**: Camera is in deep sleep (battery power save mode). Intermittent — the camera sleeps between captures to preserve battery.

**Solution**: Retry on next cycle. The camera will respond when awake. Consider changing `battery_work_mode` to `high_performance` or `plugged_in` if the camera is powered.

### EZVIZ capture error 2003

**Symptom**: Capture API returns code 2003 with device serial.

**Cause**: Device is offline — no 4G signal, battery dead, or physically powered off.

**Solution**: Check the camera physically. `sensor.farm_camera_X_battery` shows battery level. Camera will recover automatically when it comes back online.

---

## General Tips

### Before making big changes

Always take a VM snapshot:
```powershell
Checkpoint-VM -Name "HomeAssistant" -SnapshotName "Before-<description>"
```

### Checking HA logs

- **Web UI**: Settings > System > Logs
- **Terminal add-on**: `ha core logs`
- **Full system logs**: `ha host logs`

### Restarting services

- **Restart HA Core**: Settings > System > Restart (or `ha core restart`)
- **Restart Supervisor**: `ha supervisor restart`
- **Restart entire VM**: `Stop-VM` / `Start-VM` from PowerShell on the host

---

## Dashboard / Lovelace Issues

### Samba share not accessible from remote machine

**Symptom**: `\\homeassistant.local\config` or `\\192.168.0.239\config` returns "network name cannot be found" (error 67).

**Cause**: SMB/Samba connectivity issues between Windows client and HAOS. Port 445 is open but share enumeration fails.

**Workaround**: Use the HA APIs instead of Samba for config changes:
- **Template sensors**: Create via config flow API (`POST /api/config/config_entries/flow` with `handler: template`)
- **Dashboard config**: Use WebSocket API (`lovelace/config/save`, `lovelace/dashboards/create`)
- **HACS cards**: Use WebSocket API (`hacs/repositories/list` to get repo IDs, then `hacs/repository/download`)

**To fix Samba**: Check Samba add-on options (password changed to "terrabyte"), verify SMB client compatibility on Windows side.

### Lovelace REST API returns 404

**Symptom**: `GET /api/lovelace/dashboards` or `POST /api/lovelace/config` returns HTTP 404.

**Solution**: Use WebSocket API instead:
- `lovelace/dashboards/list` - list dashboards
- `lovelace/dashboards/create` - create dashboard with url_path, title, icon
- `lovelace/config/save` - save dashboard config (add `url_path` for sub-dashboards)

### HACS `hacs/repository/add` returns "Unknown command"

**Symptom**: HACS WebSocket command `hacs/repository/add` fails.

**Solution**: Use `hacs/repositories/list` (no params) to get all repos with numeric IDs, then `hacs/repository/download` with the numeric `repository` ID (not the GitHub path).

---

## Issue Log

Track issues encountered during this specific deployment:

| # | Date | Issue | Resolution | Related |
|---|------|-------|------------|---------|
| 1 | 2026-03-10 | Samba share inaccessible from dev machine | Used config flow API for templates, WS API for dashboards | Dashboard setup |
| 2 | 2026-03-10 | HACS WS `repository/add` unknown command | Used `repositories/list` + numeric IDs for `repository/download` | HACS cards |
| 3 | 2026-03-10 | Lovelace REST API 404 | Switched to WebSocket API for all dashboard operations | Dashboard setup |

| 4 | 2026-03-11 | Gemini 2.0 Flash deprecated | Switched to `gemini-2.5-flash` in config.ps1 | Vision analysis |
| 5 | 2026-03-11 | Gate camera RTSP 500/timeout | Script handles gracefully, skips failed snapshots | Vision analysis |
| 6 | 2026-03-11 | Veggie garden false human detection | Added explicit prompt about wire cage being chicken run, not humans | Vision analysis |
| 7 | 2026-03-11 | Gate open detection fails at night | Rewrote prompt to describe palisade fence gap specifically | Vision analysis |
| 8 | 2026-03-12 | Food sensor showed single detection only | Rewrote to accumulate unique items with timestamps + fuzzy dedup | Vision analysis |
| 9 | 2026-03-12 | PS Remoting "Access Denied" after power loss | Need to re-run Enable-PSRemoting + LocalAccountTokenFilterPolicy + TrustedHosts | Server deployment |
| 10 | 2026-03-12 | EZVIZ camera_proxy 500 (4G cameras) | Bypass HA, use EZVIZ cloud API directly for on-demand captures | EZVIZ farm cameras |
| 11 | 2026-03-12 | EZVIZ image entity returns stale images | image entity only updates on PIR motion events, not on demand | EZVIZ farm cameras |
| 12 | 2026-03-12 | New-PSSession fails but Invoke-Command works | Use Invoke-Command directly, bundle work into single call | Server deployment |
| 13 | 2026-03-12 | Vision/farm sensors vanish after HA restart | Sensors via POST /api/states are temporary — scripts recreate on next run | Vision + EZVIZ |

> Update this log as issues are discovered and resolved.
