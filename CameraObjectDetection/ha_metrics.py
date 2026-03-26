"""
ha_metrics.py - Publishes CameraObjectDetection metrics to Home Assistant sensors.
Scans OUTPUT_DIR for today's detection files and pushes counts to HA via REST API.

Can be run standalone (loops every METRICS_INTERVAL seconds) or imported and called
from supervisor.py as a background thread.

Sensors published:
  - sensor.street_cam_detections_today  (total count, with by_type and hourly attributes)
  - sensor.street_cam_people_today      (person count)
  - sensor.street_cam_vehicles_today    (car + truck + bus count)
  - sensor.street_cam_last_detection    (ISO timestamp of most recent detection)
  - sensor.street_cam_last_object       (object type of most recent detection)
  - sensor.street_cam_status            ("running" / "error" / "offline")
"""

import os
import sys
import time
import json
import logging
import threading
from datetime import datetime, date
from collections import defaultdict
from logging.handlers import RotatingFileHandler

import requests

import config

# ============================================================
# Logging setup
# ============================================================
os.makedirs(config.LOG_DIR, exist_ok=True)
logger = logging.getLogger("HAMetrics")
logger.setLevel(logging.INFO)
handler = RotatingFileHandler(
    os.path.join(config.LOG_DIR, "ha_metrics.log"),
    maxBytes=config.LOG_MAX_BYTES,
    backupCount=config.LOG_BACKUP_COUNT,
)
handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(handler)
logger.addHandler(logging.StreamHandler(sys.stdout))

VEHICLE_TYPES = {"car", "truck", "bus"}


def scan_detections():
    """
    Scan today's detection directory and return metrics.
    Returns dict with: total, by_type, hourly, people, vehicles, last_time, last_object
    """
    today_str = date.today().strftime("%Y_%m_%d")
    cam_dir = os.path.join(config.OUTPUT_DIR, config.CAMERA_NAME)

    by_type = defaultdict(int)
    hourly = defaultdict(int)
    last_time = None
    last_object = None
    last_mtime = 0

    if not os.path.isdir(cam_dir):
        return {
            "total": 0, "by_type": {}, "hourly": {},
            "people": 0, "vehicles": 0,
            "last_time": None, "last_object": None,
        }

    # Walk through object type subdirectories
    try:
        for obj_type in os.listdir(cam_dir):
            obj_dir = os.path.join(cam_dir, obj_type)
            if not os.path.isdir(obj_dir):
                continue

            # Skip LicensePlate folder (derived, not a detection type)
            if obj_type == "LicensePlate":
                continue

            today_dir = os.path.join(obj_dir, today_str)
            if not os.path.isdir(today_dir):
                continue

            for fname in os.listdir(today_dir):
                fpath = os.path.join(today_dir, fname)
                if not os.path.isfile(fpath):
                    continue

                by_type[obj_type] += 1

                # Extract hour from filename (HH_MM_SS.jpg)
                basename = os.path.splitext(fname)[0]
                parts = basename.split("_")
                if len(parts) >= 1 and parts[0].isdigit():
                    hour = parts[0].zfill(2)
                    hourly[hour] += 1

                # Track most recent detection
                mtime = os.path.getmtime(fpath)
                if mtime > last_mtime:
                    last_mtime = mtime
                    last_time = datetime.fromtimestamp(mtime).isoformat()
                    last_object = obj_type

    except Exception:
        logger.exception("Error scanning detections")

    total = sum(by_type.values())
    people = by_type.get("person", 0)
    vehicles = sum(by_type.get(v, 0) for v in VEHICLE_TYPES)

    # Ensure all 24 hours are present in hourly
    hourly_full = {str(h).zfill(2): hourly.get(str(h).zfill(2), 0) for h in range(24)}

    return {
        "total": total,
        "by_type": dict(by_type),
        "hourly": hourly_full,
        "people": people,
        "vehicles": vehicles,
        "last_time": last_time,
        "last_object": last_object,
    }


def push_sensor(entity_id, state, attributes=None):
    """Push a sensor state to HA via REST API."""
    if not config.HA_TOKEN:
        logger.debug("No HA_TOKEN configured — skipping push")
        return False

    url = f"{config.HA_URL}/api/states/{entity_id}"
    headers = {
        "Authorization": f"Bearer {config.HA_TOKEN}",
        "Content-Type": "application/json",
    }
    payload = {
        "state": str(state),
        "attributes": attributes or {},
    }

    try:
        resp = requests.post(url, json=payload, headers=headers, timeout=10)
        if resp.status_code in (200, 201):
            return True
        else:
            logger.warning("HA API %d for %s: %s", resp.status_code, entity_id, resp.text[:200])
            return False
    except Exception:
        logger.exception("Failed to push %s", entity_id)
        return False


def publish_image_sensors():
    """Publish image gallery sensors with entity_picture attributes."""
    for category in ("person", "vehicle"):
        for i in range(1, config.IMAGE_SLOTS + 1):
            filename = f"street_{category}_{i}.jpg"
            entity_id = f"sensor.street_cam_{category}_{i}"
            # Check if the image file exists on Samba
            samba_path = os.path.join(config.HA_WWW_SAMBA, filename)
            exists = os.path.isfile(samba_path)
            push_sensor(entity_id, "available" if exists else "empty", {
                "friendly_name": f"Street Cam {category.title()} {i}",
                "icon": "mdi:walk" if category == "person" else "mdi:car",
                "entity_picture": f"/local/{filename}" if exists else None,
            })


def publish_metrics(status="running"):
    """Scan detections and publish all sensors to HA."""
    metrics = scan_detections()

    push_sensor("sensor.street_cam_detections_today", metrics["total"], {
        "friendly_name": "Street Cam Detections Today",
        "icon": "mdi:cctv",
        "unit_of_measurement": "detections",
        "by_type": metrics["by_type"],
        "hourly": metrics["hourly"],
    })

    push_sensor("sensor.street_cam_people_today", metrics["people"], {
        "friendly_name": "Street Cam People Today",
        "icon": "mdi:walk",
        "unit_of_measurement": "people",
    })

    push_sensor("sensor.street_cam_vehicles_today", metrics["vehicles"], {
        "friendly_name": "Street Cam Vehicles Today",
        "icon": "mdi:car",
        "unit_of_measurement": "vehicles",
    })

    push_sensor("sensor.street_cam_last_detection", metrics["last_time"] or "unknown", {
        "friendly_name": "Street Cam Last Detection",
        "icon": "mdi:clock-outline",
        "device_class": "timestamp" if metrics["last_time"] else None,
    })

    push_sensor("sensor.street_cam_last_object", metrics["last_object"] or "none", {
        "friendly_name": "Street Cam Last Object",
        "icon": "mdi:shape",
    })

    push_sensor("sensor.street_cam_status", status, {
        "friendly_name": "Street Cam Detection Status",
        "icon": "mdi:check-circle" if status == "running" else "mdi:alert-circle",
    })

    # Publish image gallery sensors
    try:
        publish_image_sensors()
    except Exception:
        logger.exception("Error publishing image sensors")

    # Publish plate OCR stats
    try:
        today = date.today().strftime("%Y-%m-%d")
        ocr_defaults = {"gemini_calls_today": 0, "tesseract_calls_today": 0,
                        "plates_detected_today": 0, "known_plates_today": 0}
        ocr_stats = ocr_defaults.copy()
        if os.path.exists(config.PLATE_OCR_STATS_PATH):
            with open(config.PLATE_OCR_STATS_PATH, "r") as f:
                raw = json.load(f)
            if raw.get("date") == today:
                ocr_stats.update({k: raw.get(k, 0) for k in ocr_defaults})

        push_sensor("sensor.street_cam_plate_ocr_stats", ocr_stats["gemini_calls_today"], {
            "friendly_name": "Street Cam Plate OCR Stats",
            "icon": "mdi:card-text-outline",
            **ocr_stats,
        })
    except Exception:
        logger.exception("Error publishing plate OCR stats")

    # Publish plate state sensors (last_plate, known_plates_today, loitering)
    # These are normally pushed by ProcessCropFiles on detection, but must also
    # be kept alive here so they survive HA restarts without a server reboot.
    try:
        plate_state = {}
        if os.path.exists(config.PLATE_STATE_PATH):
            with open(config.PLATE_STATE_PATH, "r") as f:
                plate_state = json.load(f)

        # Last plate sensor — only create if missing (ProcessCropFiles keeps this current)
        try:
            resp = requests.get(
                f"{config.HA_URL}/api/states/sensor.street_cam_last_plate",
                headers={"Authorization": f"Bearer {config.HA_TOKEN}"},
                timeout=5,
            )
            if resp.status_code == 404:
                last_plate = plate_state.get("last_plate", "none")
                last_plate_attrs = {
                    "friendly_name": "Street Cam Last Plate",
                    "icon": "mdi:car-info",
                }
                if plate_state.get("last_known_image"):
                    last_plate_attrs["entity_picture"] = plate_state["last_known_image"]
                if plate_state.get("last_known_owner"):
                    last_plate_attrs["owner"] = plate_state["last_known_owner"]
                push_sensor("sensor.street_cam_last_plate", last_plate, last_plate_attrs)
        except Exception:
            pass  # Non-critical

        # Known plates today sensor
        today = date.today().strftime("%Y-%m-%d")
        known_today = plate_state.get("known_today", {})
        known_date = plate_state.get("known_date", "")
        if known_date != today:
            known_today = {}
        total_known = sum(d.get("count", 0) for d in known_today.values())
        plates_list = sorted(
            [{"plate": p, "owner": d.get("owner", ""), "count": d.get("count", 0),
              "last_seen": d.get("last_seen", "")}
             for p, d in known_today.items()],
            key=lambda x: x["last_seen"], reverse=True
        )
        push_sensor("sensor.street_cam_known_plates_today", total_known, {
            "friendly_name": "Street Cam Known Plates Today",
            "icon": "mdi:car-multiple",
            "unit_of_measurement": "sightings",
            "plates": plates_list,
        })

        # Loitering sensor — only create if missing (don't overwrite active alerts from DetectObjects3)
        try:
            resp = requests.get(
                f"{config.HA_URL}/api/states/sensor.street_cam_loitering",
                headers={"Authorization": f"Bearer {config.HA_TOKEN}"},
                timeout=5,
            )
            if resp.status_code == 404:
                push_sensor("sensor.street_cam_loitering", "clear", {
                    "friendly_name": "Street Cam Loitering",
                    "icon": "mdi:account-clock",
                })
        except Exception:
            pass  # Non-critical — DetectObjects3 will create it on next detection
    except Exception:
        logger.exception("Error publishing plate state sensors")

    logger.info(
        "Published: total=%d, people=%d, vehicles=%d, last=%s",
        metrics["total"], metrics["people"], metrics["vehicles"],
        metrics["last_object"] or "none",
    )


def run_loop():
    """Continuously publish metrics at the configured interval."""
    logger.info("HA Metrics publisher started (interval: %ds)", config.METRICS_INTERVAL)

    while True:
        try:
            publish_metrics("running")
        except Exception:
            logger.exception("Error publishing metrics")
            try:
                publish_metrics("error")
            except Exception:
                pass

        time.sleep(config.METRICS_INTERVAL)


def start_background():
    """Start metrics publishing in a background daemon thread."""
    t = threading.Thread(target=run_loop, daemon=True, name="HAMetrics")
    t.start()
    return t


if __name__ == "__main__":
    run_loop()
