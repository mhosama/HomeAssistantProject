# CLAUDE.md - Project Context for Claude Sessions

## IMPORTANT: Check TODO.md every session!

**Always read `TODO.md` at the start of each session.** It tracks all outstanding work. Update it as tasks are completed or new ones are discovered.

## Project Overview

Home Assistant installation for a house in Randpark, South Africa. Deployed on a Windows 10 server running Hyper-V with HAOS (Home Assistant Operating System).

## Server Details

- **Host Server**: Windows 10 Enterprise (192.168.0.156)
- **Virtualization**: Hyper-V with HAOS Gen2 VM
- **HA Access**: `http://homeassistant.local:8123`
- **Network**: 192.168.0.x subnet, external virtual switch bridged to physical NIC
- **HA API**: Use WebSocket API (`ws://homeassistant.local:8123/api/websocket`) for Supervisor operations. The REST `/api/hassio/` endpoints return 401 with long-lived tokens - this is by design.

## Current State (as of 2026-03-13)

### Working Integrations
| Integration | Method | Entities | Notes |
|---|---|---|---|
| Sonoff/eWeLink | HACS (AlexxIT/SonoffLAN) | 50 switches + sensors | Cloud mode, 2 devices unavailable |
| Sunsynk Solar | HACS (MorneSaunders360/Solar-Sunsynk) | 38 sensors (2 inverters) | Cloud API |
| Samsung TV | Built-in (samsungtv) | media_player + remote | IP: 192.168.0.27 |
| Google Cast | Built-in (cast) | 10 media players | Auto-discovered |
| Tapo Cameras | HACS (JurajNyiri/Tapo-Control) | 14 entities (7 cams x HD+SD) | Cloud: mhokloppers@gmail.com |
| RTSP Cameras | Generic Camera (ffmpeg) | 6 cameras | .2:5101-5110 (gates, pool, garage, lounge, street) |
| Alliance Heat Pump | HACS (radical-squared/aquatemp) | climate + 100+ sensors | Cloud: tuksmaestro@gmail.com |
| Google Assistant SDK | Built-in | send_text_command | Limited: no news/podcast |
| Gemini Vision Analysis | External API + Scheduled Task | 8 sensors | 12 cameras, per-camera schedules + motion burst |
| Weather Briefing | Open-Meteo API + Gemini + Scheduled Task | 1 sensor | Daily at 04:15, TTS in morning greeting |
| EZVIZ Farm Cameras | Built-in (ezviz) + Scheduled Task | 10 sensors | 6 cameras every 5 min, cloud-only (4G) |

### HACS Installed
- `AlexxIT/SonoffLAN` (integration)
- `MorneSaunders360/Solar-Sunsynk` (integration)
- `JurajNyiri/HomeAssistant-Tapo-Control` (integration)
- `radical-squared/aquatemp` (integration)
- `slipx06/sunsynk-power-flow-card` (dashboard card)
- `piitaya/lovelace-mushroom` (dashboard card)
- `kalkih/mini-media-player` (dashboard card)

### Scheduled Tasks (Windows)
| Task | Script | Schedule |
|---|---|---|
| `HA-RefreshNews` | `deploy/06a-Refresh-News.ps1` | Daily at 04:30 |
| `HA-RefreshWeather` | `deploy/09a-Refresh-Weather.ps1` | Daily at 04:15 |
| `HA-VisionAnalysis` | `deploy/08a-Run-VisionAnalysis.ps1` | Every 10 seconds (per-camera schedules) |
| `HA-EzvizVision` | `deploy/10a-Run-EzvizVision.ps1` | Every 5 minutes |
| `HA-RecreateSensors` | `deploy/11-Recreate-Sensors.ps1` | On server startup (2 min delay) |
| `HA-CameraHealthCheck` | `deploy/12-Camera-HealthCheck.ps1` | Every 30 minutes |
| `HA-CameraObjectDetection` | `CameraObjectDetection/supervisor.py` | On server startup |
| `HA-RefreshTTTProjection` | `deploy/05d-Refresh-TTT-Projection.ps1` | Every 10 minutes |

## Project Structure

```
HomeAssistantProject/
├── CLAUDE.md              # This file - project context for Claude sessions
├── TODO.md                # Outstanding tasks - CHECK EVERY SESSION
├── README.md              # Project overview, architecture, quick-start
├── deploy/                # Deployment scripts (run on server)
│   ├── config.ps1         # Shared config (IPs, tokens, credentials) - NOT in git
│   ├── .vision_state.json       # Vision analysis state (alert throttling, food tracking)
│   ├── .ezviz_vision_state.json # EZVIZ farm camera state (alert throttling)
│   ├── logs/              # Runtime logs (vision_analysis.log, ezviz_analysis.log)
│   ├── 01-Deploy-HomeAssistant.ps1  # Hyper-V VM creation (needs admin)
│   ├── 02-Setup-Addons.ps1         # Add-ons + HACS via WebSocket API
│   ├── 03-Setup-Integrations.ps1   # Integration config flows
│   ├── 04-Setup-Dashboards.ps1     # Initial dashboard creation
│   ├── 04a-Fix-Dashboards.ps1      # Rebuilt dashboards with verified entities
│   ├── 04b-Fix-Battery-SOC.ps1     # Fixed battery SOC gauge
│   ├── 05-Setup-Automations.ps1    # Automations (Morning Greeting, Gate Alert)
│   ├── 05a-Add-TimeToTwenty.ps1    # Battery TTT sensor
│   ├── 05b-Add-Geyser-Alerts.ps1   # Geyser & borehole TTS alerts
│   ├── 05c-Upgrade-TTT-Solar.ps1   # Solar-aware TTT sensor + apexcharts + dashboard
│   ├── 05d-Refresh-TTT-Projection.ps1 # Battery projection runner (every 10 min)
│   ├── 06-Setup-News.ps1           # Sky News Daily setup
│   ├── 06a-Refresh-News.ps1        # Refreshes Sky News URL (scheduled task)
│   ├── 07a-AA-Sensors.ps1          # Android Auto template sensors
│   ├── 07b-Setup-TapoCameras.ps1   # Network scan + Tapo config flows
│   ├── 07c-Setup-RtspCameras.ps1   # RTSP gate cameras (run from server)
│   ├── 07d-Add-CameraDashboard.ps1 # Camera tab on Security dashboard
│   ├── 08-Setup-VisionAnalysis.ps1  # Vision analysis setup (one-time)
│   ├── 08a-Run-VisionAnalysis.ps1   # Vision analysis runner (every 60s)
│   ├── 08b-Add-VisionDashboard.ps1  # Vision AI dashboard sections
│   ├── 09-Setup-Weather.ps1         # Weather briefing setup (sensor + scheduled task)
│   ├── 09a-Refresh-Weather.ps1      # Weather briefing runner (Open-Meteo + Gemini)
│   ├── 10-Setup-Ezviz.ps1           # EZVIZ farm cameras setup (integration + sensors + task)
│   ├── 10a-Run-EzvizVision.ps1      # EZVIZ vision analysis runner (every 5 min)
│   ├── 10b-Add-EzvizDashboard.ps1   # Farm Cameras tab on Security dashboard
│   ├── 11-Recreate-Sensors.ps1      # Recreate temp sensors on HA restart (startup task)
│   ├── 12-Camera-HealthCheck.ps1    # Camera health check + auto-reconnect (every 30 min)
│   ├── 13-Update-CameraIPs.ps1     # One-off: delete stale Tapo entries + recreate with new IPs
│   ├── 14-Setup-InfoDashboard.ps1  # Info dashboard with vision analysis stats
│   ├── 15-Setup-ObjectDetection.ps1 # Street camera object detection deployment
│   ├── 16-Setup-Life360.ps1        # Life360 location tracking (HACS + config flow + automations)
│   ├── 16a-Add-Life360Dashboard.ps1 # Presence dashboard (map + member cards + history)
│   ├── Manage-VM.ps1               # VM management utility (needs admin)
│   └── README.md                   # Deployment instructions
├── CameraObjectDetection/   # YOLOv5 street camera detection pipeline
│   ├── config.py            # Central configuration (paths, tuning, HA settings)
│   ├── supervisor.py        # Process monitor (launches + auto-restarts scripts)
│   ├── ha_metrics.py        # HA sensor publisher (detection counts → REST API)
│   ├── SampleImages.py      # RTSP frame capture with auto-reconnect
│   ├── DetectObjects3.py    # YOLOv5 object detection on sampled frames
│   ├── ProcessCropFiles.py  # Sort detections into organized dirs + OCR plates
│   ├── run.bat              # Simple launcher for supervisor
│   └── requirements.txt     # Python dependencies
├── docs/
│   ├── EQUIPMENT.md       # Device inventory with IPs and protocols
│   ├── SETUP-GUIDE.md     # Hyper-V + HAOS deployment steps
│   ├── INTEGRATIONS.md    # Integration setup notes and status
│   ├── DASHBOARDS.md      # Dashboard design and implementation
│   ├── DECISIONS.md       # Architecture Decision Records
│   └── TROUBLESHOOTING.md # Common issues and solutions
└── config/                # HA configuration files (future)
```

## Key Technical Notes

- **PowerShell + `!` in passwords**: PowerShell escapes `!` in strings. Write JSON to a file with the Write tool, then read it with `Get-Content` to pass to API calls.
- **Supervisor API**: Use WebSocket (`type: "supervisor/api"`) not REST `/api/hassio/`. The REST endpoints are internal-only for the HA frontend.
- **Config flows**: Use REST API `POST /api/config/config_entries/flow` to create integration config flows programmatically. Abort stale flows with DELETE.
- **HA restart after HACS installs**: Always restart HA after downloading HACS integrations before they become available.
- **Deploy scripts don't need admin**: Only `01-Deploy-HomeAssistant.ps1` and `Manage-VM.ps1` need admin. The API scripts (02, 03) run fine without elevation.

## Conventions

- **TODO.md is the source of truth** for what needs to be done
- **Documentation first**: Document decisions and steps before/during execution
- **Credentials**: Never commit credentials to git. `deploy/config.ps1` contains the HA token locally.
- **IPs**: Track all device IPs in `docs/EQUIPMENT.md`. Use DHCP reservations where possible.
- **ADRs**: Log significant decisions in `docs/DECISIONS.md` with context and rationale.
- **Deploy to host server, not dev PC**: Scheduled tasks and recurring scripts (vision analysis, news refresh, weather) must run on the Windows host server (192.168.0.156), not the dev machine. HAOS VM can't run PowerShell — the host server is the execution environment. Only run scripts on the dev PC for one-off testing.

## Claude Session Instructions

1. **Read `TODO.md` first** - check what's outstanding and what's new
2. **Before any server deployment**, read `memory/remote-deploy-patterns.md` for proven patterns (quick deploy, Samba access, health checks, common gotchas)
3. **After ANY deployment** (server deploy, running a setup script against HA, or modifying live config), **always run `deploy/17-Integrity-Check.ps1`** to verify nothing broke. This is mandatory, not optional.
4. **When adding new entities to HA** (sensors, automations, cameras, dashboards, scheduled tasks), **always update the expected arrays in `deploy/17-Integrity-Check.ps1`** so the integrity check covers them. New entities that aren't in the check don't exist as far as validation is concerned.
5. **Update `TODO.md`** when completing tasks or discovering new ones
6. Always check `docs/DECISIONS.md` before proposing architectural changes
7. Update `docs/TROUBLESHOOTING.md` when solving non-trivial issues
8. When adding integrations, update `docs/INTEGRATIONS.md`, `docs/EQUIPMENT.md`, and `TODO.md`
9. Prefer HA's built-in integrations over custom/HACS when quality is comparable
10. Test YAML changes mentally before suggesting them (valid syntax, correct indentation)
