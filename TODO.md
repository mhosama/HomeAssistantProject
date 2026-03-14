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
- [x] **Tapo Cameras** - 7 cameras configured (IPs updated 2026-03-13)
  - `deploy/13-Update-CameraIPs.ps1` - Deleted stale entries + recreated with new IPs
  - Chickens (.209), Backyard (.113), Back door (.101), Veggie Garden (.106), Dining Room (.191), Kitchen (.249), Lawn (.102)
  - 14 camera entities (HD + SD stream each)
  - [x] Camera feeds added to Security dashboard (Cameras tab) via `deploy/07d-Add-CameraDashboard.ps1`
  - [ ] Verify all streams load in HA dashboard
  - [x] **RTSP cameras** - 6 cameras via Generic Camera (ffmpeg)
    - Main Gate (.2:5102), Visitor Gate (.2:5103), Pool (.2:5104), Garage (.2:5106), Lounge (.2:5110), Street (.2:5101)
    - `deploy/07c-Setup-RtspCameras.ps1` - updated with all 6 cameras
  - [x] Run `deploy/13-Update-CameraIPs.ps1` to update Tapo entries (all 7 Tapo configured)
  - [x] RTSP cameras added via ffmpeg YAML in configuration.yaml (config flow times out)
  - [x] Run `deploy/07d-Add-CameraDashboard.ps1` to update dashboard (16 cameras)
  - [ ] Investigate Dining Room Camera (.191) — showing unavailable after config, may be wrong IP
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
- [x] **Vision AI dashboards updated** - Pool Status + Garage Doors sections added to Security > Vision AI tab + Overview (deploy/08b-Add-VisionDashboard.ps1)
- [ ] **Info Dashboard** - Run `deploy/14-Setup-InfoDashboard.ps1` to create Info dashboard with vision analysis stats
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
- [x] **Run script** - `deploy/08a-Run-VisionAnalysis.ps1` captures 13 cameras, calls Gemini, updates sensors/alerts
- [x] **Run setup** - Executed `08-Setup-VisionAnalysis.ps1` (sensors + automations + scheduled task created)
- [x] **Test manually** - `08a-Run-VisionAnalysis.ps1` runs, sensors update in Developer Tools > States
- [x] **Verify security alerts** - TTS alerts fire on kitchen speaker for human detection (8PM-6AM)
- [x] **Verify gate status** - Main gate and visitor gate status correctly detected (palisade fence gap = open)
- [x] **Dashboard cards** - `08b-Add-VisionDashboard.ps1` added Vision AI to Overview + Security dashboards
- [x] **Camera health check** - `deploy/12-Camera-HealthCheck.ps1` runs every 30 min, reloads Tapo/EZVIZ config entries and restarts ffmpeg for unavailable cameras
- [x] ~~**Verify light auto-off**~~ - Removed: light analysis via AI removed in v2.0 scheduling rewrite (will use Sonoff switch states instead)
- [ ] **Verify Tapo motion sensor entity IDs** - Check HA Developer Tools > States for `binary_sensor.*_motion` entities from Tapo cameras. Update entity IDs in `08a-Run-VisionAnalysis.ps1` if they differ from assumed names.
- [ ] **Verify chicken count** - Check `sensor.chicken_count` updates correctly
- [ ] **Verify food detection** - Check meal sensors during breakfast/lunch/dinner windows
  - [x] Food items now accumulate with timestamps (e.g. "toast and eggs (07:30), porridge (07:45)")
  - [x] Fuzzy dedup prevents duplicate detections; longer descriptions replace shorter ones
  - [x] Items reset on new day; state stored in `.vision_state.json` under `food_items`
- [x] **Pool camera enhanced** - Adult/child counting, pool cover status, unsupervised children alert (5min throttle, daytime only)
  - New sensors: `sensor.pool_adult_count`, `sensor.pool_child_count`, `sensor.pool_cover_status`
  - [x] Added to Security > Vision AI tab + Overview dashboard
- [x] **Garage camera enhanced** - Left/right garage door open/closed detection, 5-min open alerts (10min throttle)
  - New sensors: `sensor.left_garage_door`, `sensor.right_garage_door`
  - Door timing tracked in `.vision_state.json` under `garage_doors`
  - [x] Added to Security > Vision AI tab + Overview dashboard
- [ ] **Monitor logs** - Check `deploy/logs/vision_analysis.log` for scheduling decisions and camera counts
- [ ] **Check daily analysis counts** - Monitor `sensor.vision_analysis_stats` for per-camera daily counts (attributes: `*_today`, `*_history`). 30-day history stored in state file.
- [ ] **Add phone notifications** - Update alert actions once Companion App `notify.mobile_app_*` entity is available
- [ ] **Implement light auto-off via Sonoff switches** - Replace removed AI-based light detection with actual switch state monitoring for dining/kitchen/lounge lights

## Street Camera Object Detection (YOLOv5)

- [x] **Clean up CameraObjectDetection folder** — removed ~400MB of unused files, models, experiments
- [x] **Refactor active scripts** — SampleImages, DetectObjects3, ProcessCropFiles use central config.py, logging, error handling
- [x] **Supervisor (supervisor.py)** — auto-monitors and restarts the 3 detection scripts
- [x] **HA metrics (ha_metrics.py)** — publishes detection counts to HA sensors every 60s
- [x] **Deploy script (15-Setup-ObjectDetection.ps1)** — copies to server, creates scheduled task, HA sensors, dashboard
- [x] **Plate registry (plate_registry.json + ProcessCropFiles.py)** — known plate lookup, per-plate alert toggles, unknown night alerts, 5-min cooldown
- [x] **Image gallery (ProcessCropFiles.py + ha_metrics.py)** — last 5 people + 5 vehicles as sliding window in HA www via Samba
- [x] **Loitering detection (DetectObjects3.py + deep-sort-realtime)** — Deep SORT tracker, 60s threshold, TTS + mobile alerts, cropped image to HA
- [x] **Alerts module (alerts.py)** — shared TTS + mobile notification module, auto-discovers `notify.mobile_app_*`
- [x] **Dashboard updated** — plate info, image galleries (person/vehicle), conditional loitering alert card
- [x] **22 HA sensors** — 6 original + 2 plate + 10 image gallery + 1 loitering + 3 loitering verification counters
- [x] **Recreate sensors (11-Recreate-Sensors.ps1)** — all 22 street cam sensors added to boot recreate list
- [x] **Gemini loitering verification** — two-crop comparison via Gemini Flash confirms same object before alerting; 3 daily counter sensors (unconfirmed/confirmed/false)
- [x] **Image color fix** — RGB→BGR conversion before cv2.imwrite for gallery crops and loitering crops
- [x] **Clickable gallery/loitering images** — `<a href>` wrappers open full-resolution images in new tab
- [ ] **Deploy to server** — run `deploy/15-Setup-ObjectDetection.ps1` to deploy pipeline
- [ ] **Verify Python dependencies on server** — `pip install -r requirements.txt` (inc. deep-sort-realtime)
- [ ] **Start scheduled task** — `schtasks /run /tn HA-CameraObjectDetection` or reboot server
- [ ] **Verify sensors** — check `sensor.street_cam_*` entities in Developer Tools > States (19 total)
- [ ] **Verify dashboard** — view Street Stats at `http://homeassistant.local:8123/street-stats`
- [ ] **Verify image gallery** — check `/local/street_person_*.jpg` and `/local/street_vehicle_*.jpg` URLs load
- [x] **Fix loitering false positives** — gap detection (10s), min hit count (10), reduced max_age (30→10) to prevent different objects triggering alerts
- [ ] **Test loitering** — stand in front of camera >60s, verify TTS + mobile alert fires
- [ ] **Kill test** — kill one Python process, verify supervisor restarts it within 30s
- [x] **Add known plates** — 3 plates in `plate_registry.json` (KH78WWGP, MR80BWGP, JHS001MP) + replaced unknown plates tracker with known plates daily count sensor
- [ ] **Improve license plate OCR** — current Tesseract-based OCR is basic; consider cloud OCR or dedicated ANPR model

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

*Last updated: 2026-03-14 (Gemini loitering verification + image color fix + clickable photos)*
