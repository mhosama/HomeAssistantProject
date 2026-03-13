# Home Assistant - Randpark House

**Version 2.2.0** | [Changelog](#changelog)

Comprehensive home automation system managing solar/energy, lighting, sensors, security cameras, media, pool, irrigation, and more.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Home Network (192.168.0.x)             │
│                                                         │
│  ┌──────────────────────┐    ┌────────────────────────┐ │
│  │  Windows 10 Server   │    │   IoT Devices          │ │
│  │  192.168.0.156       │    │                        │ │
│  │                      │    │  Sonoff/eWeLink ─┐     │ │
│  │  ┌────────────────┐  │    │  Tapo Cameras ───┤     │ │
│  │  │  Hyper-V VM    │  │    │  Google Home ────┤     │ │
│  │  │                │  │    │  Samsung TV ─────┤     │ │
│  │  │  HAOS (HA OS)  │◄─┼────│  Alliance Pool ──┘     │ │
│  │  │  192.168.0.x   │  │    │                        │ │
│  │  └────────────────┘  │    └────────────────────────┘ │
│  └──────────────────────┘                               │
│                                                         │
│  ┌──────────────────────┐    ┌────────────────────────┐ │
│  │  Cloud Services      │    │  Sunsynk Portal        │ │
│  │                      │    │  (Solar/Battery/Grid)   │ │
│  │  eWeLink Cloud ──────┤    │                        │ │
│  │  Tapo Cloud ─────────┘    └────────────────────────┘ │
│  └──────────────────────┘                               │
└─────────────────────────────────────────────────────────┘
```

## Equipment Summary

| Category | Devices | Protocol | Status |
|----------|---------|----------|--------|
| Solar/Energy | 2 Sunsynk inverters, batteries, panels | Cloud API (HACS) | Working |
| Lighting & Switches | 50 Sonoff switches | eWeLink Cloud | Working |
| Sensors | Sonoff temp, presence, door/window | eWeLink Cloud | Working |
| Water Management | Sonoff valves (irrigation, borehole, pumps) | eWeLink Cloud | Working |
| Geysers | 3 Sonoff power switches | eWeLink Cloud | Working |
| Security Cameras | 6 Tapo + 2 RTSP gate cameras | Tapo Control + ffmpeg | Working |
| Vision Analysis | 8 cameras → Gemini Flash (every 60s) | Google Gemini API | Working |
| Media | 10 Google Cast + Samsung TV | Cast / Samsung API | Working |
| Pool | Alliance heat pump + Sonoff pump switch | AquaTemp Cloud (HACS) | Working |
| Gates/Doors | Sonoff relay switches | eWeLink Cloud | Working |

## Server Details

- **Host**: Windows 10 Enterprise (192.168.0.156)
- **Virtualization**: Hyper-V Gen2 VM
- **OS**: Home Assistant Operating System (HAOS)
- **Access**: `http://<HA_IP>:8123`

## Quick Start

1. Review the setup guide: [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md)
2. Follow infrastructure deployment steps (Hyper-V + HAOS)
3. Install integrations per priority: [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md)
4. Configure dashboards: [`docs/DASHBOARDS.md`](docs/DASHBOARDS.md)

## Documentation

| Document | Purpose |
|----------|---------|
| [`CLAUDE.md`](CLAUDE.md) | Project context for Claude sessions |
| [`docs/EQUIPMENT.md`](docs/EQUIPMENT.md) | Full device inventory |
| [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md) | Infrastructure deployment |
| [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) | Integration setup & status |
| [`docs/DASHBOARDS.md`](docs/DASHBOARDS.md) | Dashboard design |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Architecture decisions |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Issues & solutions |

## Project Phases

- **Phase 1**: Documentation scaffolding *(done)*
- **Phase 2**: Infrastructure deployment — Hyper-V VM + HAOS *(done)*
- **Phase 3**: Core integrations — Sonoff, Sunsynk, Samsung TV, Google Cast, Tapo cameras, Alliance heat pump *(done)*
- **Phase 4**: Dashboards — 6 dashboards + Vision AI sections *(done)*
- **Phase 5**: Automations — Morning Greeting, Gate Alert, Geyser/Borehole alerts, Battery Full, Inverter High Temp *(done)*
- **Phase 6**: LLM Vision Analysis — 8 cameras → Gemini Flash → sensors/alerts every 60s *(done)*
- **Phase 7**: Polish — entity renaming, DHCP reservations, phone notifications, local mode *(in progress)*

## Changelog

### v2.2.0 — 2026-03-13
- **Added**: CameraObjectDetection pipeline cleanup — removed ~400MB of unused files/models/experiments
- **Added**: Supervisor process monitor (`supervisor.py`) — auto-restarts crashed detection scripts
- **Added**: Central config (`config.py`) — all paths, tuning params, HA settings in one place
- **Added**: HA sensor integration (`ha_metrics.py`) — street camera detection counts pushed to HA every 60s
- **Added**: Street Stats dashboard — detection summary, hourly breakdown, by-type counts
- **Added**: `deploy/15-Setup-ObjectDetection.ps1` — server deployment + scheduled task + HA setup
- **Changed**: Active scripts (SampleImages, DetectObjects3, ProcessCropFiles) refactored with logging, error handling, auto-reconnect

### v2.1.0 — 2026-03-13
- **Added**: Pool Status + Garage Doors sections on Security > Vision AI dashboard
- **Added**: Pool cover + garage door cards on Overview dashboard
- **Added**: Info dashboard with vision analysis stats (per-camera daily counts, history)
- **Added**: `2min` schedule tier; pool camera uses 2-min intervals during afternoon swim hours (14–19h)
- **Changed**: Dashboard update script now replaces existing cards in-place (idempotent)

### v2.0.0 — 2026-03-13
- **Added**: Per-camera vision analysis scheduling with 7 tiers (10s–1hr) + time-of-day overrides
- **Added**: Motion burst mode for Tapo cameras (10s → 30s → 60s taper)
- **Added**: Pool camera sensors (adult_count, child_count, pool_cover_status) + unsupervised children alert
- **Added**: Garage door sensors (left/right open/closed) + door-left-open alerts
- **Added**: Daily analysis count tracking per camera with 30-day history
- **Added**: Camera health check script (auto-reconnect every 30 min)
- **Added**: EZVIZ farm camera scripts (cloud capture + Gemini analysis)
- **Removed**: AI-based light detection (unreliable, replaced by Sonoff switch states)

### v1.9.0 — 2026-03-13
- **Updated**: Tapo camera IPs (7 cameras reconfigured after DHCP changes)
- **Added**: 5 new RTSP cameras (Lawn, Pool, Garage, Lounge, Street)

### v1.8.0 — 2026-03-12
- **Added**: Sensor recreation on HA restart (`deploy/11-Recreate-Sensors.ps1` + startup task)

### v1.7.0 — 2026-03-12
- **Fixed**: Morning Greeting TTS cutoff — replaced hardcoded 20s delay with `wait_for_trigger` (speaker playing→idle, 60s timeout)
- **Added**: Remote deployment via PS Remoting to host server (`hadeploy` account)
- **Fixed**: Scheduled tasks (`HA-VisionAnalysis`, `HA-RefreshNews`, `HA-RefreshWeather`) now run on host server, not dev PC
- **Added**: All deploy scripts synced to server via `_sync_to_server.ps1`

### v1.6.0 — 2026-03-12
- **Added**: Weather briefing — Open-Meteo + Gemini → `sensor.weather_briefing` → morning greeting TTS
- **Added**: `deploy/09-Setup-Weather.ps1` and `deploy/09a-Refresh-Weather.ps1`

### v1.5.0 — 2026-03-12
- **Added**: Food accumulation in vision analysis — meals tracked with timestamps, fuzzy dedup
- **Added**: Vision AI dashboard sections on Overview + Security dashboards

### v1.4.0 — 2026-03-12
- **Added**: LLM Vision Analysis — 8 cameras → Gemini Flash → sensors/alerts every 60s
- **Added**: Gate status detection, chicken counting, human detection, food tracking
- **Added**: `deploy/08-Setup-VisionAnalysis.ps1`, `08a-Run-VisionAnalysis.ps1`, `08b-Add-VisionDashboard.ps1`

### v1.3.0 — 2026-03-11
- **Added**: Sky News Daily — RSS feed → MP3 → morning greeting + dashboard controls
- **Added**: Geyser & borehole TTS alerts, battery full alert, inverter high temp alert
- **Added**: Android Auto template sensors (Solar vs Load, Pool Temperature)

### v1.2.0 — 2026-03-11
- **Added**: 6 Tapo cameras + 2 RTSP gate cameras, camera dashboard
- **Added**: Alliance heat pump (pool) integration via AquaTemp
- **Added**: Morning Greeting + Gate Alert automations

### v1.1.0 — 2026-03-10
- **Added**: 6 dashboards (Overview, Energy, Lighting, Security, Water & Climate, Media)
- **Added**: Template sensors, Battery Time To Twenty, Sunsynk Power Flow Card

### v1.0.0 — 2026-03-10
- **Initial release**: Hyper-V VM + HAOS, Sonoff (50 switches), Sunsynk (2 inverters), Samsung TV, Google Cast (10 devices)
- **Added**: HACS + integrations, add-ons (Samba, SSH, File Editor, Terminal)
