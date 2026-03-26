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
  - [x] Test TTS (text-to-speech) announcements — fixed: internal_url changed from `.local` to IP (Cast speakers can't resolve mDNS)
  - [ ] Set up media player cards on dashboard

## Dashboards

- [x] **Overview Dashboard** - whole-house status at a glance (deploy/04-Setup-Dashboards.ps1)
  - Energy flow (Sunsynk Power Flow Card)
  - Security summary (doors, gates)
  - Climate (temps, geysers)
  - Lighting quick toggles
  - Media player status
- [x] **Energy Dashboard** - combined + per-inverter views with Power Flow Card
  - [x] Fixed `04b` to be Energy-only (no longer overwrites Overview dashboard)
  - [ ] **Run `04b-Fix-Battery-SOC.ps1`** to deploy per-inverter PPV1/PPV2 side-by-side layout to live Energy dashboard
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
- [ ] **Solar-Aware TTT Upgrade** - Solar + cloud-attenuated TTT calculation (deploy/05c-Upgrade-TTT-Solar.ps1)
  - [ ] Run `09a-Refresh-Weather.ps1` to populate `hourly_cloud_cover` attribute (forecast_days=2)
  - [ ] Run `05c-Upgrade-TTT-Solar.ps1` to replace TTT sensor + install apexcharts-card + add graph
  - [ ] Deploy `05d-Refresh-TTT-Projection.ps1` to server with 10-min scheduled task (`HA-RefreshTTTProjection`)
  - [ ] Deploy updated `11-Recreate-Sensors.ps1` to server
  - [ ] Verify TTT shows solar-aware values (higher during sunny daytime vs old load-only estimate)
  - [ ] Verify projection graph on Overview dashboard shows solar/load/SOC curves
- [x] **Vision AI dashboards updated** - Pool Status + Garage Doors sections added to Security > Vision AI tab + Overview (deploy/08b-Add-VisionDashboard.ps1)
- [x] **Info Dashboard** - `deploy/14-Setup-InfoDashboard.ps1` deployed — Vision Stats, Motion Activity, Street Camera (with plate OCR stats)
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
  - Alerts with phone notifications: Inverter Room High Temp, Battery Full, Gate Open, Inverter Door Closed Hot

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
- [x] Inverter Room High Temp - TTS + phone notification when inverter room temp reaches 28°C+ (sensor.sonoff_a48007a2b0_temperature)
  - [x] Added to Overview dashboard (Climate Summary) and Water & Climate dashboard (Climate section)
  - [x] Lowered alert threshold from 30°C to 28°C
- [x] **Inverter Room Door Closed Hot** - TTS + push when temp >= 25°C and door is closed (deploy/07-Setup-PhoneAlerts.ps1)
- [ ] ~~Geyser Schedule~~ - Removed (Sonoff switches have built-in timers)
- [x] **Good Night Routine** - Kitchen door closes 20:00-02:00 → lights off + bedroom TTS with battery/gate/garage status (deploy/05c-Setup-GoodNight.ps1)
  - [x] Fixed midnight gap: replaced OR time condition with single midnight-wrapping condition
  - [x] Deployed to HA via `05c-Setup-GoodNight.ps1` (2026-03-18)
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
- [ ] **Verify egg count** - Check `sensor.egg_count` updates after next chickens camera analysis cycle; verify on Vision AI dashboard
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
- [x] **Cost reduction** - Reduced polling frequency: Kitchen→motion-only, MainGate/VisitorGate→10min, Pool morning→30min, Lawn night override removed
- [x] **Motion burst tweaks** - Taper changed to 10s→60s→120s, first motion frame immediate, heavy activity suppression (>5 triggers in 5min → 30min cooldown), Pool afternoon→5min, Garage night→10min, Lounge→30min
- [x] **Motion sensor diagnostics** - First-tick logging shows found/missing motion sensors to catch wrong entity IDs
- [x] **Motion sensor entity IDs fixed** - Tapo cameras use `*_motion_alarm` not `*_motion` (7 sensors corrected in 08a)
- [x] **Detection history** - `sensor.vision_last_detections` with last 5 detections per camera (only actual detections), snapshots saved to Samba `/local/vision_*.jpg`
- [x] **Detection history dashboards** - Recent Detections sections on Security > Vision AI tab + Farm Cameras tab with clickable snapshot images
  - `sensor.farm_last_detections` mirrors home camera pattern for EZVIZ cameras
  - Snapshots saved to `/local/farm_detect_{N}_{slot}.jpg`
- [ ] **Monitor logs** - Check `deploy/logs/vision_analysis.log` for scheduling decisions and camera counts
- [ ] **Check daily analysis counts** - Monitor `sensor.vision_analysis_stats` for per-camera daily counts (attributes: `*_today`, `*_history`). 30-day history stored in state file.
- [ ] **Add phone notifications** - Update alert actions once Companion App `notify.mobile_app_*` entity is available
- [ ] **Implement light auto-off via Sonoff switches** - Replace removed AI-based light detection with actual switch state monitoring for dining/kitchen/lounge lights
- [ ] **Consider event-driven motion triggers** - Current motion detection relies on 10s polling from host server, which could miss brief motion events (<10s). Could add HA automations that set `input_boolean` flags on motion state change, ensuring no events are lost between polls. Low priority since Tapo `motion_alarm` entities hold `on` state for 30-60s.

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
- [x] **23 HA sensors** — 6 original + 2 plate + 1 plate OCR stats + 10 image gallery + 1 loitering + 3 loitering verification counters
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
- [x] **Tightened fuzzy plate matching** — min plate length raised from 3→5, tier 3 requires detected text >= 60% of registry plate length (prevents short OCR fragments like "ELY" matching full plates)
- [x] **Known plate image on dashboard** — markdown card with `<img>` tag showing last known plate crop
- [x] **Known plate image persistence** — `entity_picture` now persisted in plate state; unknown plates no longer wipe the last known plate image
- [x] **Plate crop orientation fix** — aspect-ratio-aware rotation + dual-orientation OCR with SA province suffix scoring
- [x] **Improve license plate OCR** — replaced Tesseract with Gemini Flash as primary OCR (Tesseract kept as fallback). SA plate format validation, daily OCR stats sensor + Info dashboard tab
- [x] **Fix Gemini plate OCR cost** — reversed to Tesseract-first, Gemini-fallback-on-contour-crop-only. Added daily cap (100). ~95% reduction in Gemini plate calls.
- [x] **Info dashboard deployed** — `14-Setup-InfoDashboard.ps1` run, plate OCR stats now visible on Street Camera tab
- [x] **Gemini token usage tracking** — All 5 Gemini callers (08a vision, 09a weather, 10a ezviz, ProcessCropFiles plate OCR, gemini_verify loitering) now capture `usageMetadata` tokens, write to shared `.gemini_token_stats.json`, published as `sensor.gemini_token_usage` by 08a, Info dashboard Gemini Usage tab with per-source breakdown + daily cost history

## Smart Energy Scheduler

- [x] **Setup script** - `deploy/18-Setup-EnergySchedule.ps1` creates input_booleans, sensors, automations, scheduled tasks, dashboard
- [x] **Daily refresh** - `deploy/18a-Refresh-EnergySchedule.ps1` reads weather → Gemini → optimal device schedule
- [x] **5-min runner** - `deploy/18b-Run-EnergySchedule.ps1` switches devices on/off per hourly plan
- [x] **Morning Greeting updated** - `deploy/06a-Refresh-News.ps1` includes energy schedule TTS summary
- [x] **Sensor recreation** - `deploy/11-Recreate-Sensors.ps1` includes energy_schedule + energy_schedule_log
- [x] **Integrity check** - `deploy/17-Integrity-Check.ps1` covers all new entities + tasks
- [ ] **Run setup** - Execute `18-Setup-EnergySchedule.ps1` to create input_booleans, sensors, automations, dashboard
- [ ] **Test daily refresh** - Run `18a-Refresh-EnergySchedule.ps1` manually → verify sensor.energy_schedule populated
- [ ] **Test 5-min runner** - Run `18b-Run-EnergySchedule.ps1` manually → verify device switching logic
- [ ] **Verify dashboard** - Check Overview → Energy Schedule section (table + ApexCharts + toggles)
- [ ] **Deploy to server** - Deploy scheduled tasks (`HA-RefreshEnergySchedule`, `HA-RunEnergySchedule`) to host server
- [ ] **Verify automations** - Test `automation.borehole_pump_schedule` and `automation.irrigation_veggie_garden`
- [ ] **Verify entity IDs** - Confirm borehole pump (`switch.sonoff_10016a6ba8`) and irrigation valve (`switch.sonoff_1001614e7a`) entity IDs are correct
- [ ] **Run integrity check** - `17-Integrity-Check.ps1` passes with all new entities
- [ ] **Monitor logs** - Check `deploy/logs/energy_schedule.log` for clean execution

## Network & Security

- [ ] Create a DHCP reservation map for all smart devices
- [ ] Consider VLAN isolation for IoT devices
- [ ] Set up HA external access (if needed) via Nabu Casa or reverse proxy
- [ ] Review HA user accounts and permissions
- [ ] Back up the HA long-lived access token securely (remove from config.ps1 after setup)

## Integrations - Planned (Research Done)

> See `docs/INTEGRATIONS-PLANNED.md` for full research details on each.

- [x] **Life360** — HACS `pnbruckner/ha-life360`, location tracking + driving state, presence dashboard
  - [x] Setup script created: `deploy/16-Setup-Life360.ps1` (HACS install + config flow + automations)
  - [x] Dashboard script created: `deploy/16a-Add-Life360Dashboard.ps1` (map + member cards + history)
  - [x] Extract Life360 access token from browser (email-code auth workaround)
  - [x] Add `Life360TokenType` + `Life360AccessToken` to `deploy/config.ps1`
  - [x] Run `16-Setup-Life360.ps1` — HACS installed, config flow completed, 5 members discovered
  - [x] Run `16a-Add-Life360Dashboard.ps1` — Presence dashboard + Overview section created
  - [x] Device trackers: Mauritz, Chandré, Lizette, Melandi, Mauritz (2nd device)
  - [x] Arrival/departure automations created with real entity IDs
  - [x] Entity renames: mauritz_kloppers_2→Oupa, lizette_kloppers→Ouma, chandre_kloppers→Chandre
  - [x] TTS pronunciation fix: Chandre→Shandrey via Jinja replace() filter
  - [x] Samsung phone tracker hidden from dashboard (entity kept as backup)
  - [x] Run `_rename_life360.ps1` to apply entity renames
  - [x] Run `_update_life360_automations.ps1` to fix automations
  - [x] Run `16a-Add-Life360Dashboard.ps1` to rebuild dashboard without samsung_phone
  - [x] Fixed dashboard to use Life360 `place` attribute instead of HA `state` (home/not_home)
  - [ ] Test arrival/departure TTS on kitchen speaker
  - Uses undocumented API (built-in integration was removed in 2024.2). User has Gold/Platinum membership.
- [ ] **Garmin Dashcam** — BLOCKED: no public API, no HA integration exists. Revisit later.
- [x] **Google Find Hub** — HACS `BSkando/GoogleFindMy-HA`, Horizen tags + vehicles, 5-min polling
  - [x] Setup script created: `deploy/20-Setup-GoogleFindMy.ps1` (HACS install + config flow + automations)
  - [x] Dashboard script created: `deploy/20a-Add-FindMyDashboard.ps1` (Find My tab on Presence + Overview section)
  - [x] Integrity check updated: `deploy/17-Integrity-Check.ps1` (2 automations + 6 trackers)
  - [x] Generated `secrets.json` using GoogleFindMyTools (moons-14 cert_sha1 fork for FCM fix)
  - [x] Added `GoogleFindMySecretsPath` to `deploy/config.ps1`
  - [x] Ran `20-Setup-GoogleFindMy.ps1` — HACS install, config flow, automations created
  - [x] 6 devices discovered: Galaxy S24 Ultra, KIA SORENTO, Honey Trap, FORD EVEREST, Elle tag, Lana tag
  - [x] Entity IDs added to `17-Integrity-Check.ps1` (device_tracker.{device_name} pattern)
  - [x] Ran `20a-Add-FindMyDashboard.ps1` — Find My tab + Overview section
  - [x] Ran `17-Integrity-Check.ps1` — automations 20/20, trackers 11/11, dashboards 10/10
  - [x] External URL set on HA (required for FCM push transport)
  - [x] Full HA restart (required after external URL set for FCM to connect)
  - **Key lessons**: FCM needs external_url + full HA restart (not just reload). GoogleFindMyTools needs cert_sha1 fork. Config flow: user→secrets_json→device_selection (secrets must be escaped as raw string, not ConvertTo-Json). Entity IDs are device_tracker.{device_name}, not device_tracker.googlefindmy_*.
  - [ ] Verify location history retention in HA (default recorder keeps 10 days, sufficient for 5-day requirement)
  - SA suburban coverage: 4/6 devices showing home, 2 tags unknown (expected for Bluetooth-only tags)
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

## Deployment Integrity

- [x] **Integrity check script** - `deploy/17-Integrity-Check.ps1` validates sensors, cameras, automations, dashboards, scheduled tasks
  - Run with `-IncludeTasks` on server to also check scheduled tasks + host processes + log freshness + sensor recency
  - Current: 56 sensors, 20 cameras, 12 automations, 9 dashboards, 8 scheduled tasks, 5 host processes
- [x] **Garage camera stale image fix** - `Test-IsDetection` now includes `human_detected` for garage camera, so person alerts get fresh snapshots
- [x] **Good Night automation deployed** - `05c-Setup-GoodNight.ps1` run against HA (was previously only a local script)

*Last updated: 2026-03-22 (Smart Energy Scheduler — 18/18a/18b scripts, Gemini-optimized device scheduling)*
