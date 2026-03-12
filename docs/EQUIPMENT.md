# Equipment Inventory

Complete inventory of all devices, protocols, IP addresses, and integration methods.

## Solar & Energy

| Device | Model | IP/ID | Protocol | Integration | Status |
|--------|-------|-------|----------|-------------|--------|
| Sunsynk Inverter | TBD | Cloud | Sunsynk API | HACS `sunsynk` | Pending |
| Battery Pack | TBD | - | Via inverter | Via Sunsynk | Pending |
| Solar Panels | TBD | - | Via inverter | Via Sunsynk | Pending |

## Lighting & Switches (Sonoff/eWeLink)

| Device | Location | Model | eWeLink ID | Integration | Status |
|--------|----------|-------|------------|-------------|--------|
| Switch | TBD | TBD | TBD | eWeLink Cloud | Pending |
| Dimmer | TBD | TBD | TBD | eWeLink Cloud | Pending |

> **Note**: Populate this table by exporting device list from eWeLink app once integration is connected.

## Sensors (Sonoff/eWeLink)

| Device | Location | Type | eWeLink ID | Integration | Status |
|--------|----------|------|------------|-------------|--------|
| Temperature sensor | TBD | SNZB-02 (?) | TBD | eWeLink Cloud | Pending |
| Door/window sensor | TBD | SNZB-04 (?) | TBD | eWeLink Cloud | Pending |
| Presence sensor | TBD | SNZB-06P (?) | TBD | eWeLink Cloud | Pending |

## Water Management (Sonoff/eWeLink)

| Device | Purpose | Model | eWeLink ID | Integration | Status |
|--------|---------|-------|------------|-------------|--------|
| Valve/relay | Irrigation | TBD | TBD | eWeLink Cloud | Pending |
| Valve/relay | Borehole pump | TBD | TBD | eWeLink Cloud | Pending |
| Valve/relay | Water pump | TBD | TBD | eWeLink Cloud | Pending |
| Power meter | Water monitoring | TBD | TBD | eWeLink Cloud | Pending |

## Geysers (Sonoff/eWeLink)

| Device | Location | Model | eWeLink ID | Integration | Status |
|--------|----------|-------|------------|-------------|--------|
| Power switch | Geyser 1 | Sonoff POW (?) | TBD | eWeLink Cloud | Pending |
| Power switch | Geyser 2 | TBD | TBD | eWeLink Cloud | Pending |

## Security Cameras (Tapo)

> IPs are auto-discovered by `deploy/07b-Setup-TapoCameras.ps1` via network scan (ports 443 + 2020/ONVIF).
> 6 cameras configured, 12 entities (HD + SD stream each).

| Device | Location | Model | IP Address | Protocol | Integration | Status |
|--------|----------|-------|------------|----------|-------------|--------|
| Chickens | Chicken coop | Tapo | 192.168.0.101 | RTSP | HACS `tapo_control` | Configured |
| Backyard Camera | Backyard | Tapo | 192.168.0.106 | RTSP | HACS `tapo_control` | Configured |
| Back door Camera | Back door | Tapo | 192.168.0.111 | RTSP | HACS `tapo_control` | Configured |
| Veggie Garden | Veggie garden | Tapo | 192.168.0.195 | RTSP | HACS `tapo_control` | Configured |
| Dining Room Camera | Dining room | Tapo | 192.168.0.214 | RTSP | HACS `tapo_control` | Configured |
| Kitchen Camera | Kitchen | Tapo | 192.168.0.249 | RTSP | HACS `tapo_control` | Configured |
| Unknown device | ? | ? | 192.168.0.102 | ? | - | Connection failed (ONVIF+443 open but not Tapo?) |
| Main Gate Camera | Main gate | Tapo C310 | 192.168.0.2:5102 | RTSP only (LAN) | ffmpeg (YAML) | Configured |
| Visitor Gate Camera | Visitor gate | Tapo C310 | 192.168.0.2:5103 | RTSP only (LAN) | ffmpeg (YAML) | Configured |

## Farm Cameras (EZVIZ, 4G Cloud-Only)

> 6 EZVIZ cameras connected via 4G cellular. Cloud-only (no local RTSP). EU region.
> Entity IDs to be discovered after running `deploy/10-Setup-Ezviz.ps1`.

| Device | Location | Model | Connection | Integration | Status |
|--------|----------|-------|------------|-------------|--------|
| Farm Camera 1 | TBD | EZVIZ | 4G Cloud (EU) | Built-in `ezviz` | Pending |
| Farm Camera 2 | TBD | EZVIZ | 4G Cloud (EU) | Built-in `ezviz` | Pending |
| Farm Camera 3 | TBD | EZVIZ | 4G Cloud (EU) | Built-in `ezviz` | Pending |
| Farm Camera 4 | TBD | EZVIZ | 4G Cloud (EU) | Built-in `ezviz` | Pending |
| Farm Camera 5 | TBD | EZVIZ | 4G Cloud (EU) | Built-in `ezviz` | Pending |
| Farm Camera 6 | TBD | EZVIZ | 4G Cloud (EU) | Built-in `ezviz` | Pending |

## Media

| Device | Location | Model | IP Address | Protocol | Integration | Status |
|--------|----------|-------|------------|----------|-------------|--------|
| Samsung TV | Living room | QA65Q70BAKXXA | 192.168.0.27 | Samsung API | Samsung TV (built-in) | Working |
| Kitchen Speaker | Kitchen | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| Dining Room Speaker | Dining room | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| Front Home Speaker | Front | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| Airbnb Speaker | Airbnb | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| Study Speaker | Study | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| Guest Room Speaker | Guest room | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| Bedroom Speaker | Bedroom | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| Baby Room Speaker | Baby room | Google Home | DHCP | Cast | Google Cast (built-in) | Working |
| TV Chromecast | Living room | Chromecast | DHCP | Cast | Google Cast (built-in) | Working |
| Home Speakers | Group | - | - | Cast | Google Cast (built-in) | Working |

## Pool

| Device | Model | IP Address | Protocol | Integration | Status |
|--------|-------|------------|----------|-------------|--------|
| Alliance Heat Pump | AquaTemp compatible | Cloud API | WiFi/Cloud | HACS `radical-squared/aquatemp` | Working |
| Pool pump switch | Sonoff | eWeLink Cloud | eWeLink | `switch.sonoff_1001f8b132` | Working |

## Gates & Doors (Sonoff/eWeLink)

| Device | Location | Model | eWeLink ID | Integration | Status |
|--------|----------|-------|------------|-------------|--------|
| Gate relay | Main gate | TBD | TBD | eWeLink Cloud | Pending |
| Gate relay | Garage | TBD | TBD | eWeLink Cloud | Pending |

---

## Network Map

| Device/Service | IP Address | Notes |
|----------------|------------|-------|
| Windows Server (Hyper-V host) | 192.168.0.156 | Static |
| Home Assistant VM | 192.168.0.239 | DHCP - reservation recommended |
| Samsung TV | 192.168.0.27 | DHCP |
| Chickens Camera | 192.168.0.101 | DHCP |
| Unknown Device | 192.168.0.102 | ONVIF+443 open, not Tapo |
| Backyard Camera | 192.168.0.106 | DHCP |
| Back Door Camera | 192.168.0.111 | DHCP |
| Veggie Garden Camera | 192.168.0.195 | DHCP |
| Dining Room Camera | 192.168.0.214 | DHCP |
| Kitchen Camera | 192.168.0.249 | DHCP |
| Gate Camera Host (NVR?) | 192.168.0.2 | RTSP :5102 (Main), :5103 (Visitor) |

> **Tip**: Use your router's DHCP client list to discover device IPs. Set DHCP reservations for cameras and HA VM.
