# Integrations Setup & Status

Track the setup progress of each Home Assistant integration.

## Status Legend

| Status | Meaning |
|--------|---------|
| Not Started | Haven't begun setup |
| In Progress | Currently configuring |
| Working | Connected and functional |
| Issue | Has problems, see Troubleshooting |

---

## Priority 1: Sunsynk (Solar/Energy)

**Status**: Working
**Type**: HACS Custom Component
**Integration**: `MorneSaunders360/Solar-Sunsynk`

### Setup Steps

- [x] Install HACS (prerequisite)
- [x] Add Sunsynk repository to HACS
- [x] Install the Sunsynk integration
- [x] Configure integration with cloud API credentials
- [x] Verify entities: 38 sensors across 2 inverters (S/N 2207207800, 2305136364)
- [ ] Set up the HA Energy Dashboard (solar/battery/grid)
- [ ] Verify Sunsynk Power Flow Card entity mappings

### Entities Expected

- Solar panel power (W) and daily yield (kWh)
- Battery state of charge (%), power (W), daily charge/discharge
- Grid import/export power (W) and daily totals
- Inverter load power (W)
- Battery and inverter temperatures

### Notes

- Uses cloud API - requires internet connectivity
- Polling interval: typically 60 seconds (configurable)
- Alternative integrations if primary doesn't work: `sunsynk-power-flow-card` (card only), manual REST sensors

---

## Priority 2: eWeLink / Sonoff

**Status**: Working
**Type**: HACS Custom Component
**Integration**: `AlexxIT/SonoffLAN` (cloud mode)

### Setup Steps

- [x] Install `AlexxIT/SonoffLAN` via HACS
- [x] Configure with eWeLink account credentials (mhokloppers@gmail.com)
- [x] Verify all 50 devices appear
- [ ] Rename entities to meaningful names
- [ ] Organize devices by room/area in HA
- [ ] Consider enabling LAN mode for frequently-used switches

### Devices Covered

- Light switches and dimmers
- Door/window sensors
- Temperature/humidity sensors
- Presence/motion sensors
- Power monitoring plugs (geysers)
- Relay switches (gates, doors, pumps)
- Water valves (irrigation, borehole)
- Power meters

### Notes

- The `sonoff` integration by AlexxIT supports both cloud and LAN modes
- LAN mode is faster but requires devices on the same network
- Cloud mode works for all devices but has slight latency
- Consider setting up LAN mode for frequently-controlled devices

---

## Priority 3: Tapo Cameras

**Status**: Working
**Type**: HACS Custom Component (`JurajNyiri/HomeAssistant-Tapo-Control`) + ffmpeg YAML for RTSP-only cameras
**Integration**: `tapo_control` (6 cameras) + `ffmpeg` (2 gate cameras)

### Setup

- [x] 6 Tapo cameras discovered via `deploy/07b-Setup-TapoCameras.ps1` (network scan ports 443+2020)
- [x] 12 camera entities (HD + SD stream each)
- [x] 2 RTSP gate cameras added via ffmpeg in configuration.yaml (`deploy/07c-Setup-RtspCameras.ps1`)
- [x] Camera tab added to Security dashboard (`deploy/07d-Add-CameraDashboard.ps1`)
- [x] All 8 cameras analyzed by Gemini Vision every 60s
- [ ] Assign static IPs (DHCP reservations) for all cameras
- [ ] Verify all streams load in HA dashboard

### Camera Inventory

| Name | IP | Integration | Entity (SD) |
|------|------|-------------|-------------|
| Chickens | .101 | tapo_control | `camera.chickens_sd_stream` |
| Backyard | .106 | tapo_control | `camera.backyard_camera_sd_stream` |
| Back door | .111 | tapo_control | `camera.back_door_camera_sd_stream` |
| Veggie Garden | .195 | tapo_control | `camera.veggie_garden_sd_stream` |
| Dining Room | .214 | tapo_control | `camera.dining_room_camera_sd_stream` |
| Kitchen | .249 | tapo_control | `camera.kitchen_camera_sd_stream` |
| Main Gate | .2:5102 | ffmpeg (YAML) | `camera.main_gate_camera` |
| Visitor Gate | .2:5103 | ffmpeg (YAML) | `camera.visitor_gate_camera` |

### Credentials
- Cloud: mhokloppers@gmail.com / T3rrabyte!
- Local camera account: mhocontrol / T3rrabyte
- Config flow: IP+port 443 → local creds (skip_rtsp=false) → cloud password

---

## Priority 4: Google Cast

**Status**: Working
**Type**: Built-in Integration
**Integration**: Google Cast (auto-discovered)

### Setup

- [x] Auto-discovered 10 media players
- [x] TTS working via `tts.speak` + `tts.google_translate_en_com`
- Speakers: Kitchen, Dining Room, Front Home, Airbnb, Study, Guest Room, Bedroom, Baby Room
- TV Chromecast, Home Speakers (group)

---

## Priority 5: Samsung Smart TV

**Status**: Working
**Type**: Built-in Integration
**Integration**: Samsung Smart TV (samsungtv)

### Setup

- [x] Model: QA65Q70BAKXXA at 192.168.0.27
- [x] `media_player` + `remote` entities created
- [ ] Test media control (power, volume, source switching)
- [ ] Configure Wake-on-LAN for power-on capability

---

## Priority 6: Alliance Heat Pump (Pool)

**Status**: Working
**Type**: HACS Custom Component
**Integration**: `radical-squared/aquatemp` v3.0.37

### Setup

- [x] Integrated via HACS `radical-squared/aquatemp`
- [x] Cloud account: tuksmaestro@gmail.com / T3rrabyte (secondary account, device shared from main)
- [x] API type: `aqua_temp`
- [x] Climate entity: `climate.289c6e4f7352`
- [x] 100+ sensor entities (inlet/outlet water temp, ambient, compressor, fault status)
- Key sensors: T02 (inlet water), T03 (outlet water), T05 (ambient), O09 (IPM temp), O08 (compressor current)

---

## Priority 7: Google Assistant SDK (Google News)

**Status**: Working (limited — `send_text_command` doesn't support news/podcast playback on Cast speakers)
**Type**: Built-in Integration
**Integration**: `google_assistant_sdk`

### What It Does

- Provides `google_assistant_sdk.send_text_command` service
- Send any voice command (e.g., "play the news") to a target speaker
- Audio responses play on the specified `media_player` entity
- Can also broadcast messages, control Google-only devices, etc.

### Step 1: Google Cloud Project Setup (in browser)

1. Go to [Google Developers Console](https://console.developers.google.com/)
2. Sign in with **mhokloppers@gmail.com** (the account linked to your Google Home speakers)
3. **Create a new project** (e.g., "Home Assistant")
4. **Enable the Google Assistant API**:
   - Go to APIs & Services > Library
   - Search for "Google Assistant API"
   - Click Enable
5. **Configure OAuth consent screen**:
   - Go to APIs & Services > OAuth consent screen
   - User Type: **External**
   - App name: "Home Assistant"
   - User support email: your email
   - Developer contact: your email
   - Save (no scopes needed)
   - Under "Test users", add **mhokloppers@gmail.com**
6. **Create OAuth credentials**:
   - Go to APIs & Services > Credentials
   - Click "Create Credentials" > "OAuth client ID"
   - Application type: **Desktop app** (IMPORTANT — not "Web application")
   - Name: "Home Assistant"
   - Click Create
   - **Save the Client ID and Client Secret** (or download the JSON)

### Step 2: Add Integration in Home Assistant

1. Go to **Settings > Devices & Services > Add Integration**
2. Search for **"Google Assistant SDK"**
3. Enter the **Client ID** and **Client Secret** from Step 1
4. A browser window opens for Google OAuth — sign in with mhokloppers@gmail.com
5. Accept the permissions (access to Google Assistant)
6. The integration should complete and create the `google_assistant_sdk` domain

### Step 3: Run Deploy Script

```powershell
cd deploy
.\06-Setup-GoogleNews.ps1
```

This creates:
- Automation: "Play Google News" (manual trigger or add a schedule)
- Script: `script.play_news_kitchen` — Play news on kitchen speaker
- Script: `script.play_news_all_speakers` — Play news on all speakers
- Script: `script.stop_news` — Stop playback on kitchen speaker
- Media Dashboard: "Google News" card with Play/Stop buttons

### Verification

1. Go to **Developer Tools > Services**
2. Select `google_assistant_sdk.send_text_command`
3. Set `command: "play the news"` and `media_player: media_player.kitchen_speaker`
4. Click "Call Service" — Google News should play on the kitchen speaker

### Alternative News Commands

| Command | Source |
|---------|--------|
| `play the news` | Default Google News briefing |
| `play BBC World News` | BBC World Service |
| `play NPR news` | NPR hourly news |
| `play Sky News` | Sky News |
| `what's the news` | Short news summary |

### Notes

- **OAuth credentials must be Desktop app type** — Web app type causes empty response issues
- The integration requires internet (communicates with Google servers)
- Only one active session per Google account — if you use "Hey Google" on a speaker while HA is sending a command, one may be interrupted
- The OAuth consent screen is in "Testing" mode by default, which is fine for personal use

---

## Priority 8: HA Companion App (Phone Notifications)

**Status**: Not Started — Manual App Install Required
**Type**: Built-in Integration (auto-discovered)
**Integration**: `mobile_app`

### What It Does

- Push notifications to your phone for critical HA alerts
- Works alongside existing TTS speaker announcements
- Notifications received even when not in the HA app (while on home WiFi)

### Setup Steps

1. Install **"Home Assistant"** app from Google Play / App Store
2. Open app, enter `http://homeassistant.local:8123`
3. Log in with your HA credentials
4. Grant notification permissions when prompted
5. HA auto-registers the device, creating `notify.mobile_app_<phone_name>`
6. Run `deploy/07-Setup-PhoneAlerts.ps1` to add notifications to automations

### Automations with Phone Notifications

| Automation | Trigger | Notification |
|---|---|---|
| Inverter Room High Temp | Temp sensor >= 30°C | "Warning: Inverter room is at X°C" |
| Battery Fully Charged | SOC >= 99% | "Batteries are now fully charged (X%)" |
| Gate Open Alert | Main/visitor gate opens | "The main/visitor gate has been opened" |

### Verification

1. **Developer Tools > Services** — search for `notify.mobile_app` — your phone should appear
2. Trigger any of the updated automations from **Settings > Automations** — you should get both TTS and phone notification

### Notes

- Phone must be on the home WiFi network (no Nabu Casa / external access set up)
- Notifications are added *alongside* TTS — existing speaker alerts are preserved
- The deploy script auto-detects the mobile app service name

---

## Priority 9: Gemini Vision Analysis (LLM Camera Analysis)

**Status**: Working
**Type**: External API (Google Gemini 2.5 Flash)
**Integration**: PowerShell script + Windows Scheduled Task (`HA-VisionAnalysis`)

### What It Does

Captures snapshots from all 8 cameras every 60 seconds, sends each to Google Gemini Flash for structured JSON analysis, and updates HA sensors / fires alerts based on the results.

### Cameras Analyzed

| Camera | Analysis | Sensors Updated |
|--------|----------|-----------------|
| Chickens (.101) | Chicken count | `sensor.chicken_count` |
| Backyard (.106) | Human detection (night) | — |
| Back door (.111) | Human detection (night) | — |
| Veggie Garden (.195) | Human detection (night) | — |
| Dining Room (.214) | Human detection + lights | — |
| Kitchen (.249) | Human detection + lights + food | `sensor.breakfast_food`, `sensor.lunch_food`, `sensor.dinner_food` |
| Main Gate (.2:5102) | Gate open/closed + car count | `sensor.main_gate_status`, `sensor.main_gate_car_count` |
| Visitor Gate (.2:5103) | Gate open/closed + car count | `sensor.visitor_gate_status`, `sensor.visitor_gate_car_count` |

### Alerts & Actions

| Condition | Action | Time Window |
|-----------|--------|-------------|
| Human detected outdoors | TTS on kitchen speaker | 8PM-6AM |
| Human detected indoors | TTS on kitchen speaker | 8PM-6AM |
| Lights on + no human | Auto turn off lights | 12AM-6AM |
| Gate open > 10 min | TTS (HA automation) | Always |
| No chickens in cage | TTS (HA automation) | 8PM check |
| Chickens still in cage | TTS (HA automation) | 8AM check |
| Food visible in kitchen | Accumulate unique items with timestamps in meal sensor | Meal windows (6-10, 11-14, 17-21) |

### Deploy Scripts

- `deploy/08-Setup-VisionAnalysis.ps1` — One-time setup (sensors + automations + scheduled task)
- `deploy/08a-Run-VisionAnalysis.ps1` — Recurring (runs every 60s via `HA-VisionAnalysis` scheduled task)

### Configuration

- Gemini API key in `deploy/config.ps1` (`GeminiApiKey`, `GeminiModel`)
- Alert notification config at top of `08a-Run-VisionAnalysis.ps1` (`$alertConfig`)
- State file: `deploy/.vision_state.json` (alert throttling, food tracking)
- Logs: `deploy/logs/vision_analysis.log`

### Rate Limits

- 8 cameras x 1 call/60s = 8 RPM (Gemini Flash free tier: 15 RPM)

---

## Priority 10: Weather Briefing (Open-Meteo + Gemini)

**Status**: Working
**Type**: External APIs (Open-Meteo forecast + Google Gemini)
**Integration**: PowerShell script + Windows Scheduled Task (`HA-RefreshWeather`)

### What It Does

Fetches the daily weather forecast from Open-Meteo for Randpark Ridge, sends it to Gemini for natural-language analysis, and updates `sensor.weather_briefing` with a TTS-friendly summary. The morning greeting automation includes this in the spoken message.

### Data Flow

| Time | Step | Result |
|------|------|--------|
| 04:15 | `HA-RefreshWeather` runs | yr.no hourly forecast → Gemini → `sensor.weather_briefing` updated |
| 04:30 | `HA-RefreshNews` runs | Automation rewritten with weather template in TTS message |
| 05:00-10:00 | Morning Greeting fires | TTS: battery SOC + weather briefing + Sky News |

### Sensor

- `sensor.weather_briefing` — State: TTS text (2-3 sentences)
  - Attributes: `min_temp_c`, `max_temp_c`, `avg_cloud_pct`, `total_precip_mm`, `max_wind_ms`, `weather_symbols`, `detailed_summary`, `forecast_hours`, `last_updated`

### Briefing Content

1. **Weather summary**: Temperature range, conditions (always included)
2. **Solar impact**: Cloud/rain impact on solar generation (only if clouds >40% or rain)
3. **Irrigation note**: Skip irrigation advice (only if rain expected)

### Deploy Scripts

- `deploy/09-Setup-Weather.ps1` — One-time setup (sensor + scheduled task at 04:15)
- `deploy/09a-Refresh-Weather.ps1` — Daily runner (yr.no → Gemini → sensor update)

### Configuration

- Gemini API key in `deploy/config.ps1` (`GeminiApiKey`, `GeminiModel`) — same as vision analysis
- Open-Meteo coordinates: lat=-26.103668, lon=27.954189 (Randpark Ridge)
- Open-Meteo is free, no API key or auth needed
- Logs: `deploy/logs/weather_briefing.log`

### Notes

- Originally planned for yr.no, but yr.no returns 403 from South Africa. Switched to Open-Meteo which works without restrictions.
- HA sensor state has a 255 char limit; full TTS text stored in `tts_text` attribute, state is truncated if needed.

### Fallback

If Gemini fails, a basic summary is generated from raw yr.no data: "Today will be X to Y degrees with [rain/cloudy/clear] skies."

---

## Planned Integrations

Research has been completed for the following integrations. See **[INTEGRATIONS-PLANNED.md](INTEGRATIONS-PLANNED.md)** for full details.

| Integration | Type | Viability | Notes |
|---|---|---|---|
| Life360 | HACS (`pnbruckner/ha-life360`) | Viable | Location tracking, zone automations. Undocumented API risk. |
| Garmin Dashcam | None | Blocked | No public API, no integration exists. |
| Google Find Hub | HACS (`BSkando/GoogleFindMy-HA`) | Viable | Horizen tags + phones. Complex auth, SA coverage spotty. |
| EZVIZ Farm Cameras | Built-in (`ezviz`) | **In Progress** | Scripts created, pending deployment. See Priority 11 below. |

---

## Priority 11: EZVIZ Farm Cameras (4G, Cloud-Only)

**Status**: Scripts Created — Pending Deployment
**Type**: Built-in Integration (`ezviz`) + External API (Gemini)
**Integration**: `ezviz` (HA built-in) + `10a-Run-EzvizVision.ps1` (Gemini vision)

### What It Does

6 EZVIZ farm cameras connected via 4G cellular (no WiFi/LAN). Cloud-only integration provides motion sensors, last-event snapshots, siren control, and switches. No live video stream (RTSP requires local network).

Gemini vision analysis runs every 5 minutes on event snapshots, detecting humans, vehicles, animals, fire/smoke (with distance estimate), and rain.

### Entities

**EZVIZ Integration** (per camera):
- Motion binary sensor, last-event image, siren, switches (motion detection toggle), alarm panel

**Vision Analysis Sensors**:
- `sensor.farm_cam_1_status` .. `sensor.farm_cam_6_status` — per-camera AI summary
- `sensor.farm_fire_smoke` — fire/smoke detection (severity + distance)
- `sensor.farm_rain_status` — rain detection (intensity)
- `sensor.farm_animal_summary` — animal count and types
- `sensor.farm_human_vehicle_summary` — human/vehicle detection

**Automations**:
- Farm Fire Smoke Detected — immediate TTS alert
- Farm Intruder Detected — TTS at night (8PM-6AM)

### Setup

1. Fill in EZVIZ password in `deploy/config.ps1` (account: mhokloppers@gmail.com, 2FA must be disabled)
2. Run `deploy/10-Setup-Ezviz.ps1` — adds integration, creates sensors/automations, registers scheduled task
3. Update camera entity IDs in `deploy/10a-Run-EzvizVision.ps1` with discovered EZVIZ entities
4. Test `10a-Run-EzvizVision.ps1` manually
5. Deploy `HA-EzvizVision` scheduled task to host server via PS Remoting
6. Run `deploy/10b-Add-EzvizDashboard.ps1` to add Farm Cameras tab to Security dashboard

### Deploy Scripts

- `deploy/10-Setup-Ezviz.ps1` — One-time setup (integration + sensors + automations + scheduled task)
- `deploy/10a-Run-EzvizVision.ps1` — Recurring (runs every 5 min via `HA-EzvizVision` scheduled task)
- `deploy/10b-Add-EzvizDashboard.ps1` — Farm Cameras tab on Security dashboard

### Configuration

- EZVIZ credentials in `deploy/config.ps1` (`EzvizUsername`, `EzvizPassword`)
- Gemini API key in `deploy/config.ps1` (shared with home camera vision analysis)
- State file: `deploy/.ezviz_vision_state.json` (separate from home cameras)
- Logs: `deploy/logs/ezviz_analysis.log`

### Limitations

- **No live stream**: 4G cameras can't provide RTSP. Only event-based snapshots available.
- **Cloud dependency**: All data via EZVIZ cloud (EU region). Outage = entities unavailable.
- **2FA must be disabled**: EZVIZ account cannot use 2FA while integrated with HA.
- **Event-based snapshots**: Image entity only updates when camera detects an event. Stale if no triggers.
- **Gemini rate limit**: 6 cameras x 1 call/5min = ~1.2 RPM (well within free tier of 15 RPM)

---

## Integration Summary

| # | Integration | Type | Status | Priority |
|---|-------------|------|--------|----------|
| 1 | Sunsynk | HACS | Working | High |
| 2 | eWeLink/Sonoff | HACS | Working | High |
| 3 | Tapo Cameras | HACS + ffmpeg | Working | High |
| 4 | Google Cast | Built-in | Working | Medium |
| 5 | Samsung TV | Built-in | Working | Medium |
| 6 | Alliance Heat Pump | HACS | Working | Low |
| 7 | Google Assistant SDK | Built-in | Working (limited) | Medium |
| 8 | HA Companion App | Built-in | Not Started | High |
| 9 | Gemini Vision Analysis | External API | Working | Medium |
| 10 | Weather Briefing (Open-Meteo + Gemini) | External APIs | Working | Medium |
| 11 | EZVIZ Farm Cameras | Built-in + Gemini | Scripts Created | Medium |
