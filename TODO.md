# TODO - Home Assistant Project

> **Keep this file updated!** Add new items as they come up. Check items off as they're completed.

## Infrastructure

- [ ] Set static IP / DHCP reservation for HA VM (currently using `homeassistant.local`)
- [ ] Set DHCP reservations for all key devices on the router (cameras, TV, etc.)
- [ ] Configure HA VM auto-start on host reboot (done in script, verify it works)
- [ ] Take a baseline VM snapshot now that core integrations are working
- [ ] Set up HA backups (automated scheduled backups)

## Integrations - Needs Attention

- [x] **Sky News Daily** - Plays on kitchen speaker via Morning Greeting + dashboard buttons
  - [x] Google Assistant SDK installed (but `send_text_command` doesn't support news playback)
  - [x] Using direct MP3 from Sky News Daily RSS feed instead
  - [x] `deploy/06-Setup-News.ps1` - Full setup (automation + scripts + dashboard)
  - [x] `deploy/06a-Refresh-News.ps1` - Refreshes episode URL daily
  - [x] Set up Windows Scheduled Task `HA-RefreshNews` to run `06a-Refresh-News.ps1` daily at 04:30
- [x] **Tapo Cameras** - 6 cameras configured via network scan (ports 443 + 2020/ONVIF)
  - `deploy/07b-Setup-TapoCameras.ps1` - Scans subnet, discovers cameras, sets up via config flow
  - Chickens (.101), Backyard (.106), Back door (.111), Veggie Garden (.195), Dining Room (.214), Kitchen (.249)
  - 12 camera entities (HD + SD stream each)
  - .102 has ONVIF+443 open but connection_failed (unknown device)
  - [x] Camera feeds added to Security dashboard (Cameras tab) via `deploy/07d-Add-CameraDashboard.ps1`
  - [ ] Verify all streams load in HA dashboard
  - [ ] Identify unknown device at 192.168.0.102
  - [x] **RTSP gate cameras** (.2:5102 and .2:5103) - added via ffmpeg YAML in configuration.yaml
    - Main Gate Camera (`camera.main_gate_camera`) and Visitor Gate Camera (`camera.visitor_gate_camera`)
    - Generic Camera config flow timed out; ffmpeg platform in YAML bypasses validation
- [x] **Alliance Heat Pump (Pool)** - Integrated via HACS `radical-squared/aquatemp` v3.0.37
  - Cloud account: tuksmaestro@gmail.com (shared device from main account)
  - Climate entity: `climate.289c6e4f7352` + 100+ sensor entities
  - Key sensors: inlet/outlet water temp, ambient temp, compressor status, fault status
- [ ] **Unavailable devices** - 2 Sonoff devices showing unavailable:
  - `switch.sonoff_100160713a` (Alarm_Trigger_Motion)
  - `switch.sonoff_1000a21e3c` (Tank pump)
  - Check if these devices are powered on and connected to WiFi

## Integrations - Working (verify & optimize)

- [x] **Sonoff/eWeLink** - 50 switches connected via cloud
  - [ ] Rename entities to cleaner names where needed
  - [ ] Organize devices into HA Areas (rooms/zones)
  - [ ] Consider enabling LAN mode for frequently-used switches (faster response)
- [x] **Sunsynk Solar** - 2 inverters, 38 sensors
  - [ ] Verify all sensor values match the Sunsynk portal
  - [ ] Set up the HA Energy Dashboard (solar/battery/grid)
  - [ ] Configure Sunsynk Power Flow Card on a dashboard
- [x] **Samsung TV** (QA65Q70BAKXXA) at 192.168.0.27
  - [ ] Test media control (power, volume, source switching)
  - [ ] Configure Wake-on-LAN for power-on capability
- [x] **Google Cast** - 10 speakers/chromecasts discovered
  - Kitchen, Dining Room, Front Home, Airbnb, Study, Guest Room, Bedroom, Baby Room speakers
  - TV Chromecast
  - Home Speakers (group)
  - [ ] Test TTS (text-to-speech) announcements
  - [ ] Set up media player cards on dashboard

## Dashboards

- [x] **Overview Dashboard** - whole-house status at a glance (deploy/04-Setup-Dashboards.ps1)
  - Energy flow (Sunsynk Power Flow Card)
  - Security summary (doors, gates)
  - Climate (temps, geysers)
  - Lighting quick toggles
  - Media player status
- [x] **Energy Dashboard** - combined + per-inverter views with Power Flow Card
- [x] **Lighting Dashboard** - room-by-room controls using Mushroom cards
- [x] **Security Dashboard** - door sensors, gates, motion, alarm
- [x] **Water & Climate Dashboard** - geysers, irrigation, pumps, temps (combined climate + irrigation)
- [x] **Media Dashboard** - TV + speakers using mini-media-player, grouped by zone
- [x] Install recommended HACS cards:
  - [x] Sunsynk Power Flow Card (installed)
  - [x] Mushroom Cards (04-Setup-Dashboards.ps1)
  - [x] Mini Media Player (04-Setup-Dashboards.ps1)
- [x] Template sensors: combined inverter totals, lights-on count, doors-open count
- [x] **Battery Time To Twenty** - TTT sensor + Overview dashboard updated (deploy/05a-Add-TimeToTwenty.ps1)
- [ ] **Post-deploy**: Verify entity IDs match actual devices (door sensors, motion sensors)
- [ ] **Post-deploy**: Rename Sonoff entities for cleaner display names
- [ ] **Post-deploy**: Verify Sunsynk Power Flow Card entity mappings

## Android Auto Favorites

- [x] **Template Sensors** - Run `deploy/07a-AA-Sensors.ps1` to create:
  - [x] `sensor.solar_vs_load` - Solar generation + house load combined
  - [x] `sensor.pool_temperature` - Pool inlet + outlet water temps combined
- [ ] **Add favorites on phone** (HA Companion App > entity > More Info > Add to > Automotive):
  - [ ] `sensor.solar_vs_load`
  - [ ] `sensor.pool_temperature`
  - [ ] `switch.sonoff_100114809c` (Visitor Gate)
  - [ ] `switch.sonoff_1001f8b132` (Pool Pump)
  - [ ] `sensor.sonoff_a48007a2b0_temperature` (Inverter Room Temp)

## Phone Notifications (Companion App)

- [ ] **HA Companion App** - Install on phone, connect to `http://homeassistant.local:8123`
  - [ ] Grant notification permissions
  - [ ] Run `deploy/07-Setup-PhoneAlerts.ps1` to add push notifications to critical automations
  - Alerts with phone notifications: Inverter Room High Temp, Battery Full, Gate Open

## Weather Briefing (Open-Meteo + Gemini)

- [x] **Setup script** - `deploy/09-Setup-Weather.ps1` creates sensor + scheduled task (daily at 04:15)
- [x] **Run script** - `deploy/09a-Refresh-Weather.ps1` fetches Open-Meteo → Gemini → sensor.weather_briefing
- [x] **Morning Greeting updated** - `deploy/06a-Refresh-News.ps1` now includes weather template in TTS
- [x] **Run setup** - Executed `09-Setup-Weather.ps1` (sensor created; scheduled task needs admin)
- [x] **Test manually** - `09a-Refresh-Weather.ps1` runs, sensor updates in Developer Tools > States
- [x] **Register scheduled task** - All 3 tasks (`HA-VisionAnalysis`, `HA-RefreshNews`, `HA-RefreshWeather`) deployed to host server via PS Remoting
- [x] **Test morning greeting** - Triggered, TTS plays fully before Sky News (wait_for_trigger fix)
- [ ] **Monitor logs** - Check `deploy/logs/weather_briefing.log` for clean execution

## Automations

- [x] Morning Greeting - TTS + Sky News Daily + weather briefing on kitchen door open (05:00-10:00) (deploy/05-Setup-Automations.ps1 + 06-Setup-News.ps1)
  - [x] Fixed TTS cutoff: replaced hardcoded 20s delay with `wait_for_trigger` (speaker playing→idle, 60s timeout)
- [x] Gate Open Alert - TTS + phone notification when main/visitor gate opens
- [x] Geyser & Borehole Alert - TTS on kitchen speaker when geysers or borehole pump switch on/off (deploy/05b-Add-Geyser-Alerts.ps1)
- [x] Battery Fully Charged - TTS + phone notification when SOC >= 99%, once per day
- [x] Inverter Room High Temp - TTS + phone notification when inverter room temp reaches 30°C+ (sensor.sonoff_a48007a2b0_temperature)
- [ ] ~~Geyser Schedule~~ - Removed (Sonoff switches have built-in timers)
- [ ] ~~Goodnight Routine~~ - Removed
- [ ] ~~Door Left Open Alert~~ - Removed (too noisy)
- [ ] Irrigation schedules (time-based, possibly weather-aware)
- [ ] Pool pump schedule
- [ ] Motion detection alerts (once cameras are connected)
- [ ] Solar battery management (grid export control)
- [ ] Light scenes (evening, movie, goodnight, etc.)
- [ ] Presence-based automation (lights on/off)
- [ ] Alarm arming/disarming based on presence

## LLM Vision Analysis (Gemini Flash)

- [x] **Setup script** - `deploy/08-Setup-VisionAnalysis.ps1` creates sensors, automations, scheduled task
- [x] **Run script** - `deploy/08a-Run-VisionAnalysis.ps1` captures 8 cameras, calls Gemini, updates sensors/alerts
- [x] **Run setup** - Executed `08-Setup-VisionAnalysis.ps1` (sensors + automations + scheduled task created)
- [x] **Test manually** - `08a-Run-VisionAnalysis.ps1` runs, sensors update in Developer Tools > States
- [x] **Verify security alerts** - TTS alerts fire on kitchen speaker for human detection (8PM-6AM)
- [x] **Verify gate status** - Main gate and visitor gate status correctly detected (palisade fence gap = open)
- [x] **Dashboard cards** - `08b-Add-VisionDashboard.ps1` added Vision AI to Overview + Security dashboards
- [ ] **Verify light auto-off** - Dining/kitchen lights turn off after midnight if no human detected
- [ ] **Verify chicken count** - Check `sensor.chicken_count` updates correctly
- [ ] **Verify food detection** - Check meal sensors during breakfast/lunch/dinner windows
  - [x] Food items now accumulate with timestamps (e.g. "toast and eggs (07:30), porridge (07:45)")
  - [x] Fuzzy dedup prevents duplicate detections; longer descriptions replace shorter ones
  - [x] Items reset on new day; state stored in `.vision_state.json` under `food_items`
- [ ] **Monitor logs** - Check `deploy/logs/vision_analysis.log` for errors
- [ ] **Add phone notifications** - Update alert actions once Companion App `notify.mobile_app_*` entity is available

## Network & Security

- [ ] Create a DHCP reservation map for all smart devices
- [ ] Consider VLAN isolation for IoT devices
- [ ] Set up HA external access (if needed) via Nabu Casa or reverse proxy
- [ ] Review HA user accounts and permissions
- [ ] Back up the HA long-lived access token securely (remove from config.ps1 after setup)

## Integrations - Planned (Research Done)

> See `docs/INTEGRATIONS-PLANNED.md` for full research details on each.

- [ ] **Life360** — HACS `pnbruckner/ha-life360`, location tracking + driving state, zone automations (arrival/departure, presence-based heating)
  - Viable but uses undocumented API (built-in integration was removed in 2024.2)
  - User has Gold/Platinum membership
- [ ] **Garmin Dashcam** — BLOCKED: no public API, no HA integration exists. Revisit later.
- [ ] **Google Find Hub** — HACS `BSkando/GoogleFindMy-HA`, Horizen tags + phones, 60-min polling
  - Complex auth setup (Python script to generate `secrets.json`)
  - SA coverage may be spotty in suburban areas
- [ ] **EZVIZ Farm Cameras** — Built-in `ezviz` integration (EU region), cloud-only entities (no live stream on 4G)
  - [x] Deploy scripts created: `10-Setup-Ezviz.ps1`, `10a-Run-EzvizVision.ps1`, `10b-Add-EzvizDashboard.ps1`
  - [x] Sensors: 6x per-camera status, fire/smoke, rain, animal summary, human/vehicle summary
  - [x] Automations: Farm Fire Smoke Detected, Farm Intruder Detected (night)
  - [x] Scheduled task: `HA-EzvizVision` (every 5 minutes)
  - [ ] Fill in EZVIZ password in `deploy/config.ps1` (2FA must be disabled)
  - [ ] Run `10-Setup-Ezviz.ps1` to add integration + discover entity IDs
  - [ ] Update camera entity IDs in `10a-Run-EzvizVision.ps1` with actual EZVIZ entities
  - [ ] Test `10a-Run-EzvizVision.ps1` manually
  - [ ] Deploy `HA-EzvizVision` scheduled task to host server via PS Remoting
  - [ ] Run `10b-Add-EzvizDashboard.ps1` to add Farm Cameras tab to Security dashboard
  - [ ] Rename cameras (FarmCam1-6) with actual locations once known

## Discovered Devices (not yet integrated)

- [ ] Plex Media Server ("MHO and Bo") - DLNA discovered
- [ ] Archer C64 router (UPnP) - could provide network stats
- [ ] Archer AX72 router (UPnP) - could provide network stats

---

*Last updated: 2026-03-12 (v1.8.0: EZVIZ farm camera integration — deploy scripts, sensors, automations, dashboard)*
