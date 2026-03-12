# Home Assistant - Randpark House

**Version 1.7.0** | [Changelog](#changelog)

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
