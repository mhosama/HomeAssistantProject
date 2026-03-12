# Planned Integrations — Research Notes

Research findings for integrations under consideration. See [INTEGRATIONS.md](INTEGRATIONS.md) for currently active integrations.

---

## 1. Life360 (Location Tracking + Driving Safety)

**Viability**: Viable via HACS custom integration
**Integration**: `pnbruckner/ha-life360` (HACS)
**Account**: User has Gold/Platinum membership

### What HA Gets

- `device_tracker` entities for each family member
- Location (lat/lon), speed, driving state, GPS accuracy
- Zone-based automations (arrival/departure, geofencing)
- Presence detection for automations (lights, alarm, etc.)

### What HA Does NOT Get

- Crash detection alerts (stays in Life360 app only)
- Emergency SOS / emergency dispatch
- Driver reports and safety scores
- These features require the Life360 app directly

### Installation

1. HACS → Custom repositories → Add `pnbruckner/ha-life360`
2. Install and restart HA
3. Config flow: enter Life360 email + password
4. Device trackers appear for all circle members

### Risks & Limitations

- **API stability**: The HA built-in Life360 integration was removed in 2024.2 because Life360 started blocking API access. The custom integration (`pnbruckner/ha-life360`) works again using undocumented API endpoints, but could break again if Life360 changes their API.
- **No official API**: Life360 does not provide a public developer API. All access is reverse-engineered.
- **Battery impact**: Life360 app on phones uses GPS continuously, which affects battery life.

### Proposed Automations

- **Arrival home**: Turn on porch lights, disarm alarm
- **Departure**: Arm alarm, turn off all lights
- **Driving state**: Suppress non-critical notifications while driving
- **Presence-based heating**: Pool heat pump schedule based on whether anyone is home

---

## 2. Garmin Dashcam / Drive App / Vault

**Viability**: BLOCKED — No public API, no HA integration exists
**Integration**: None available

### Why It's Blocked

- Garmin Vault storage is managed exclusively through the Garmin Drive mobile app
- No developer API exists for accessing dashcam footage or vault-stored videos
- The only Garmin HA project (`HomeAssistant-Garmin-Connect`) is for fitness watches (controlling HA from a Garmin watch), not dashcams
- No HACS integrations, no community projects, no REST API documentation

### Action

- Document as blocked. Revisit if Garmin opens a public API or a community project emerges.
- Periodically check HACS and HA community forums for new developments.

---

## 3. Google Find My Device / Find Hub (Horizen Tags + Phones)

**Viability**: Viable via HACS custom integration
**Integration**: `BSkando/GoogleFindMy-HA` (HACS)
**Devices**: Android phones/tablets + Horizen tracker tags (Google Find My compatible, Bluetooth 5.2)

### What HA Gets

- `device_tracker` entities with location updates for phones and tags
- Configurable polling interval (default 60 minutes)
- Zone-based automations (similar to Life360 but for objects/keys/bags)

### Installation

1. **Generate auth secrets** (one-time, on a PC with Python):
   - Clone `BSkando/GoogleFindMy-HA` repo
   - Run the provided Python authentication script
   - Complete 2-part Google login (email → password → 2FA)
   - Script generates `secrets.json` with auth tokens
2. **Install in HA**:
   - HACS → Custom repositories → Add `BSkando/GoogleFindMy-HA`
   - Install and restart HA
   - Config flow: upload `secrets.json`
   - Select devices to track

### Alternative Approach

- `txitxo0/GoogleFindMyTools-homeassistant` — MQTT-based
- Requires MQTT broker (Mosquitto add-on) + Docker container
- More complex setup but potentially more reliable updates

### Risks & Limitations

- **Setup complexity**: The Python auth script is fiddly — requires desktop Python environment, manual Google login, and generated secrets file.
- **South Africa coverage**: Google Find Hub network relies on nearby Android devices to relay Bluetooth signals. Coverage is still growing in SA — works best in high-traffic urban areas, may be spotty in quiet suburban/residential neighborhoods like Randpark.
- **60-minute polling**: Location updates are not real-time. Default is 60 minutes, configurable but Google may rate-limit faster polling.
- **No official Google API**: Uses reverse-engineered endpoints; could break with Google changes.

### Proposed Use Cases

- Track car keys, bags, or other tagged items
- Know which family members' phones are home (presence detection)
- Alert if a tagged item leaves a zone (e.g., bag left at school)

---

## 4. EZVIZ Farm Cameras (4G, Cloud-Only) — IN PROGRESS

**Viability**: Partially viable — cloud entities work, but NO live video stream for 4G cameras
**Status**: Deploy scripts created (`10-Setup-Ezviz.ps1`, `10a-Run-EzvizVision.ps1`, `10b-Add-EzvizDashboard.ps1`). Pending password entry and deployment.
**Integration**: Built-in `ezviz` integration
**Account**: EZVIZ account (EU region), 2FA must be disabled
**Cameras**: 4-8 cameras, 4G cellular only (no WiFi/LAN)

### What HA Gets (Without RTSP)

- **Motion binary sensors** — triggered when camera detects motion
- **Last-event image** — `image` entity with the most recent event snapshot
- **Siren control** — trigger camera's built-in siren
- **Alarm panel** — arm/disarm motion detection zones
- **Switches** — toggle motion detection, LED, follow-move, etc.
- **Battery work mode select** — configure power management (if battery-powered)

### What HA Does NOT Get

- **Live video stream** — RTSP requires local network access; 4G cameras can't provide this
- **Continuous recording** — cloud storage only, not accessible from HA
- **PTZ control** — may not work without local connection

### Installation

1. **EZVIZ account prep**:
   - Log in at ezvizlife.com (EU region)
   - Disable 2FA (required for HA integration)
   - Do NOT use OAuth (Google/Facebook) — direct email/password only
2. **Add integration in HA**:
   - Settings → Devices & Services → Add Integration → "EZVIZ"
   - Enter EZVIZ email + password
   - Region auto-detected (EU = `apiieu.ezviz...`)
   - All cameras appear as devices with sensors + switches

### Animal/Fire Detection Plan

Since live video isn't available, leverage the `image` entity (last event snapshot) with Gemini vision analysis:

1. Add EZVIZ cameras to the vision analysis pipeline (`08a-Run-VisionAnalysis.ps1`)
2. Use the `image` entity URL instead of camera snapshot (since RTSP isn't available)
3. Run analysis every 5 minutes (less frequent than home cameras since snapshots are event-based)
4. Gemini prompts for farm cameras:
   - Animal detection: count livestock, detect predators, identify species
   - Fire/smoke detection: look for smoke, flames, unusual haze
   - Fence integrity: check for broken fences or open gates
5. Alerts via TTS + phone notification for critical detections

### Risks & Limitations

- **No live stream**: The biggest limitation. Can only see last-event snapshots, not continuous video.
- **Cloud dependency**: All data goes through EZVIZ cloud servers (EU region). If EZVIZ has an outage, all entities become unavailable.
- **2FA must be disabled**: Security trade-off — the EZVIZ account cannot use 2FA while integrated with HA.
- **Event-based snapshots**: The `image` entity only updates when the camera detects an event (motion, etc.). If nothing triggers the camera, the snapshot may be stale.
- **4G data usage**: Each camera uses cellular data for cloud uploads. High-frequency polling could increase data costs.
- **Users report up to 16 cameras working** on the EU region endpoint.

### Proposed Automations

- **Animal alert**: TTS + phone notification when livestock count changes or predator detected
- **Fire/smoke alert**: Immediate phone notification + TTS on all speakers
- **Motion at night**: Alert when motion detected at farm cameras between sunset and sunrise
- **Camera offline**: Alert when a camera goes unavailable (battery dead, signal lost)

---

## Summary

| Integration | Viability | Type | Priority | Blocker |
|---|---|---|---|---|
| Life360 | Viable | HACS (`pnbruckner/ha-life360`) | Medium | API may break |
| Garmin Dashcam | Blocked | None | Low | No API exists |
| Google Find Hub | Viable | HACS (`BSkando/GoogleFindMy-HA`) | Low | Complex auth setup, SA coverage |
| EZVIZ Farm Cameras | **In Progress** | Built-in (`ezviz`) | Medium | Scripts created, pending deployment |

---

*Created: 2026-03-12*
