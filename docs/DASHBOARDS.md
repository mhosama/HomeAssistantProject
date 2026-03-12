# Dashboard Design & Implementation

Dashboards deployed via `deploy/04-Setup-Dashboards.ps1` using the Lovelace WebSocket API.

## Dashboard Hierarchy

```
Home Overview (default)       /lovelace
├── Energy                    /energy-dashboard
│   ├── Combined Overview     (tab)
│   ├── Inverter 1 Detail     (tab) S/N 2207207800
│   └── Inverter 2 Detail     (tab) S/N 2305136364
├── Lighting & Rooms          /lighting-dashboard
├── Security                  /security-dashboard
├── Water & Climate           /water-climate-dashboard
└── Media                     /media-dashboard
```

## HACS Frontend Cards

| Card | Repository | Purpose | Status |
|------|-----------|---------|--------|
| Sunsynk Power Flow Card | `slipx06/sunsynk-power-flow-card` | Solar/battery/grid visualization | Installed |
| Mushroom Cards | `piitaya/lovelace-mushroom` | Modern entity cards | Via script |
| Mini Media Player | `kalkih/mini-media-player` | Compact media player controls | Via script |

## Template Sensors

Created via HA config flow API (`POST /api/config/config_entries/flow`). Each sensor is a separate config entry - no YAML editing needed. These combine data from 2 Sunsynk inverters:

| Sensor | Entity ID | Purpose |
|--------|-----------|---------|
| Solar Total Generation | `sensor.solar_total_generation` | Combined PV power (W) |
| Solar Total Load | `sensor.solar_total_load` | Combined load (W) |
| Solar Total Battery IO | `sensor.solar_total_battery_io` | Combined battery power (W) |
| Solar Total Grid IO | `sensor.solar_total_grid_io` | Combined grid power (W) |
| Solar Daily Production | `sensor.solar_daily_production` | Combined daily solar (kWh) |
| Solar Battery SOC Average | `sensor.solar_battery_soc_average` | Average battery % |
| Solar Daily Load | `sensor.solar_daily_load` | Combined daily load (kWh) |
| Lights On Count | `sensor.lights_on_count` | Count of Sonoff lights that are on |
| Doors Open Count | `sensor.doors_open_count` | Count of door sensors in "open" state |

### Vision Analysis Sensors (updated by `08a-Run-VisionAnalysis.ps1`)

| Sensor | Entity ID | Format |
|--------|-----------|--------|
| Chicken Count | `sensor.chicken_count` | Integer |
| Breakfast Food | `sensor.breakfast_food` | Accumulated items: `"toast and eggs (07:30), porridge (07:45)"` |
| Lunch Food | `sensor.lunch_food` | Same format, lunch window (11:00-14:00) |
| Dinner Food | `sensor.dinner_food` | Same format, dinner window (17:00-21:00) |
| Main Gate Status | `sensor.main_gate_status` | `open` / `closed` |
| Visitor Gate Status | `sensor.visitor_gate_status` | `open` / `closed` |
| Main Gate Car Count | `sensor.main_gate_car_count` | Integer |
| Visitor Gate Car Count | `sensor.visitor_gate_car_count` | Integer |

Food sensors include attributes: `items_count`, `items_list` (array), `last_updated`.

## Dashboard Details

### 1. Home Overview (default)

6-card grid layout (3 cols desktop, responsive mobile):
- **Energy**: Battery gauge + solar/load stats, tap navigates to Energy
- **Security**: Door count + gate toggles, tap navigates to Security
- **Climate**: Temp/humidity + geyser toggles, tap navigates to Water & Climate
- **Lighting**: Lights-on count + 4 quick toggles (Lounge/Kitchen/Bedroom/Yard)
- **Water**: Borehole + pool pump controls, tap navigates to Water & Climate
- **Media**: Samsung TV media player card, tap navigates to Media

### 2. Energy Dashboard

3 tabs:
- **Combined**: Sunsynk Power Flow Card with combined sensors, stats row, daily totals, battery SOC gauges (Inv1 vs Inv2), top energy consumers
- **Inverter 1** (2207207800): PPV1+PPV2 breakdown, battery SOC gauge, load/grid/battery stats, daily table
- **Inverter 2** (2305136364): Same layout as Inv1

### 3. Lighting & Rooms

Room sections with Mushroom toggle cards in grids:
- **Living Areas**: Lounge (2), Kitchen (2), Dining (2), Bar (2+fan), Hallway, TV Lights
- **Bedrooms**: Main (2), Baby Room, Guest Room
- **Utility**: Laundry, Scullery, Garage, Workshop, Wine Cellar
- **Outdoor**: Front Porch, Courtyard, Yard, Backdoor, Pool Lights, Reception, Visitor Gate Lights
- **Airbnb**: Bed Lights, TV Lights, Bathroom Lights, Bathroom Fan, Towel Rack

### 4. Security

- Status summary with doors-open count
- 8 door contact sensors (entity IDs need verification)
- Main Gate + Visitor Gate toggles
- 5 motion sensors (entity IDs need verification)
- Alarm system: Magnets + Motion trigger switches
- Offline devices alert markdown card

### 5. Water & Climate

- **Geysers**: Main (power monitored), Flat (power monitored), Guest - all toggleable
- **Irrigation**: 4 valve toggles (Hose, Veg Garden, Shed Garden, Buffer Tank) + water usage
- **Pumps**: Borehole, Pool Pump (power monitored), Tank Pump (unavailable)
- **Climate**: Main bedroom temp/humidity, aircon toggle
- **Pool**: Pool lights + pool pump

### 6. Media

- Samsung TV: Full media control card
- Living speakers: Kitchen, Dining Room, Front Home, Study (mini-media-player)
- Bedroom speakers: Bedroom, Baby Room, Guest Room
- Other: Airbnb, All Speakers group, TV Chromecast
- TTS instructions markdown card

## Post-Deployment Checklist

- [ ] Verify all dashboards render at `http://homeassistant.local:8123`
- [ ] Update door sensor entity IDs (currently placeholders)
- [ ] Update motion sensor entity IDs (currently placeholders)
- [ ] Verify Sunsynk Power Flow Card entity mappings
- [ ] Confirm template sensors show correct combined values
- [ ] Test switch toggles from dashboard
- [ ] Verify navigation between Overview and sub-dashboards
- [ ] Test on mobile (HA Companion app)

## Entity ID Notes

The script uses actual Sonoff entity IDs where known from the integration (e.g., `switch.sonoff_1000e4e53f`). However:

- **Door sensors**: Entity IDs (`binary_sensor.sonoff_ds01_*`) are placeholders - update after checking actual entity IDs in HA
- **Motion sensors**: Entity IDs (`binary_sensor.sonoff_snzb_03_*`) are placeholders - update after checking
- **Temperature sensors**: Verify `sensor.sonoff_th_main_bedroom_temperature` matches actual entity
- **Water meters**: Verify `sensor.sonoff_*_water` entity pattern matches actual Sonoff water sensors

To find actual entity IDs: Settings > Devices & Services > (device) > Entities tab
