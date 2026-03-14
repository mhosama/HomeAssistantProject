"""
ProcessCropFiles.py - Sorts YOLOv5 crop detections into organized directories.
Reads from RUNS_DIR, moves files to OUTPUT_DIR organized by camera/objectType/date.
Also runs OCR on car detections to extract license plates (saved locally).
"""

import os
import sys
import logging
import json
import time
import re
import shutil
import platform
from datetime import datetime
from logging.handlers import RotatingFileHandler

import cv2
import numpy as np
import pytesseract
import requests
from scipy import ndimage

import config
import alerts

# ============================================================
# Logging setup
# ============================================================
os.makedirs(config.LOG_DIR, exist_ok=True)
logger = logging.getLogger("ProcessCropFiles")
logger.setLevel(logging.INFO)
handler = RotatingFileHandler(
    os.path.join(config.LOG_DIR, "process_crops.log"),
    maxBytes=config.LOG_MAX_BYTES,
    backupCount=config.LOG_BACKUP_COUNT,
)
handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(handler)
logger.addHandler(logging.StreamHandler(sys.stdout))

# Tesseract path (Windows)
pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"

# ============================================================
# Plate Registry (hot-reloaded on file change)
# ============================================================
_plate_registry = None
_plate_registry_mtime = 0


def _load_plate_registry():
    """Load plate registry from JSON, hot-reloading on file change."""
    global _plate_registry, _plate_registry_mtime
    path = config.PLATE_REGISTRY_PATH
    if not os.path.exists(path):
        _plate_registry = {"plates": {}, "unknown_night_alert": {"enabled": False}}
        return _plate_registry
    try:
        mtime = os.path.getmtime(path)
        if _plate_registry is None or mtime > _plate_registry_mtime:
            with open(path, "r") as f:
                _plate_registry = json.load(f)
            _plate_registry_mtime = mtime
            logger.info("Plate registry loaded (%d plates)", len(_plate_registry.get("plates", {})))
    except Exception:
        logger.exception("Error loading plate registry")
        if _plate_registry is None:
            _plate_registry = {"plates": {}, "unknown_night_alert": {"enabled": False}}
    return _plate_registry


def _load_plate_state():
    """Load plate alert state (cooldowns, daily counts)."""
    path = config.PLATE_STATE_PATH
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {"cooldowns": {}, "known_today": {}, "known_date": ""}


def _save_plate_state(state):
    """Save plate alert state."""
    try:
        with open(config.PLATE_STATE_PATH, "w") as f:
            json.dump(state, f, indent=2)
    except Exception:
        logger.exception("Error saving plate state")


def _push_sensor(entity_id, state, attributes=None):
    """Push a sensor state to HA via REST API."""
    if not config.HA_TOKEN:
        return
    url = f"{config.HA_URL}/api/states/{entity_id}"
    headers = {
        "Authorization": f"Bearer {config.HA_TOKEN}",
        "Content-Type": "application/json",
    }
    try:
        requests.post(url, json={"state": str(state), "attributes": attributes or {}},
                       headers=headers, timeout=10)
    except Exception:
        logger.exception("Failed to push %s", entity_id)


def _is_night_time(night_start, night_end):
    """Check if current time falls within night window."""
    now = datetime.now().strftime("%H:%M")
    if night_start <= night_end:
        return night_start <= now <= night_end
    else:  # e.g., 22:00 - 06:00 (wraps midnight)
        return now >= night_start or now <= night_end


def check_plate_registry(plate_text):
    """Look up a detected plate against the registry and fire alerts."""
    if not plate_text or len(plate_text) < 3:
        return

    registry = _load_plate_registry()
    state = _load_plate_state()
    now = time.time()
    today = datetime.now().strftime("%Y-%m-%d")

    # Reset daily known counts if new day
    if state.get("known_date") != today:
        state["known_today"] = {}
        state["known_date"] = today

    # Normalize plate: uppercase, strip non-alphanumeric
    normalized = re.sub(r"[^A-Z0-9]", "", plate_text.upper())
    if len(normalized) < 3:
        return

    # Check cooldown
    last_alert = state["cooldowns"].get(normalized, 0)
    on_cooldown = (now - last_alert) < config.PLATE_ALERT_COOLDOWN

    plates_dict = registry.get("plates", {})
    # Substring match: check if any registry plate appears within the detected text
    # (OCR often adds extra characters). Case-insensitive.
    match_key = None
    match_info = None
    for reg_plate, info in plates_dict.items():
        reg_normalized = re.sub(r"[^A-Z0-9]", "", reg_plate.upper())
        if reg_normalized in normalized or normalized in reg_normalized:
            match_key = reg_plate
            match_info = info
            break

    is_known = match_info is not None
    owner = match_info.get("owner", "Unknown") if match_info else "Unknown"

    # Push last plate sensor
    _push_sensor("sensor.street_cam_last_plate", normalized, {
        "friendly_name": "Street Cam Last Plate",
        "icon": "mdi:car-info",
        "owner": owner,
        "known": is_known,
        "time": datetime.now().isoformat(),
    })

    if is_known:
        # Track known plate daily sightings
        reg_upper = re.sub(r"[^A-Z0-9]", "", match_key.upper())
        if reg_upper not in state["known_today"]:
            state["known_today"][reg_upper] = {"count": 0, "last_seen": "", "owner": owner}
        state["known_today"][reg_upper]["count"] += 1
        state["known_today"][reg_upper]["last_seen"] = datetime.now().isoformat()
        state["known_today"][reg_upper]["owner"] = owner

        # Push known plates today sensor
        total = sum(e["count"] for e in state["known_today"].values())
        plates_list = sorted(
            [{"plate": p, "owner": d["owner"], "count": d["count"], "last_seen": d["last_seen"]}
             for p, d in state["known_today"].items()],
            key=lambda x: x["last_seen"], reverse=True,
        )
        _push_sensor("sensor.street_cam_known_plates_today", total, {
            "friendly_name": "Street Cam Known Plates Today",
            "icon": "mdi:car-multiple",
            "unit_of_measurement": "sightings",
            "plates": plates_list,
        })

        # Known plate — alert per toggle settings
        if not on_cooldown:
            msg = f"{owner}'s vehicle detected. Plate: {normalized}"
            speaker = match_info.get("speaker_alert", False)
            mobile = match_info.get("mobile_alert", False)
            if speaker or mobile:
                alerts.send_alert(msg, title="Known Vehicle", speaker=speaker, mobile=mobile)
                state["cooldowns"][normalized] = now
                logger.info("Known plate alert: %s (%s)", normalized, owner)
    else:
        # Unknown plate — night alert only (no daily tracking)
        night_cfg = registry.get("unknown_night_alert", {})
        if night_cfg.get("enabled") and not on_cooldown:
            if _is_night_time(night_cfg.get("night_start", "22:00"), night_cfg.get("night_end", "06:00")):
                msg = f"Unknown vehicle detected at night. Plate: {normalized}"
                alerts.send_alert(
                    msg,
                    title="Unknown Night Vehicle",
                    speaker=night_cfg.get("speaker_alert", True),
                    mobile=night_cfg.get("mobile_alert", True),
                )
                state["cooldowns"][normalized] = now
                logger.info("Unknown night plate alert: %s", normalized)

    _save_plate_state(state)


# ============================================================
# Image Sliding Window (ring buffer to HA www)
# ============================================================

def _load_image_slots():
    """Load image slot indices."""
    path = config.IMAGE_STATE_PATH
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {"person": 0, "vehicle": 0}


def _save_image_slots(slots):
    """Save image slot indices."""
    try:
        with open(config.IMAGE_STATE_PATH, "w") as f:
            json.dump(slots, f)
    except Exception:
        logger.exception("Error saving image slots")


def copy_to_ha_sliding_window(src_path, object_type):
    """Copy a detection image to the HA www sliding window (5 slots per category)."""
    if object_type == "person":
        category = "person"
    elif object_type in ("car", "truck", "bus"):
        category = "vehicle"
    else:
        return  # Only person and vehicle types

    samba_dir = config.HA_WWW_SAMBA
    if not os.path.isdir(samba_dir):
        logger.debug("Samba www dir not accessible: %s", samba_dir)
        return

    slots = _load_image_slots()
    idx = (slots.get(category, 0) % config.IMAGE_SLOTS) + 1  # 1-based
    filename = f"street_{category}_{idx}.jpg"
    dest = os.path.join(samba_dir, filename)

    try:
        # YOLOv5 crop files have R↔B channels swapped (PIL saves RGB input with
        # channel reversal). Read with cv2, swap channels back, then write correct JPEG.
        img = cv2.imread(src_path)
        if img is not None:
            img_fixed = img[:, :, ::-1]  # swap R↔B to correct the double-reversal
            cv2.imwrite(dest, img_fixed)
        else:
            shutil.copy2(src_path, dest)  # fallback: copy as-is if imread fails
        logger.info("Image slot %s -> %s", filename, dest)
        slots[category] = idx  # Next call wraps via modulo
        _save_image_slots(slots)
    except Exception:
        logger.exception("Error copying to sliding window: %s", filename)


def rotate_image(image, angle):
    """Rotate image by angle degrees, filling background with white."""
    return ndimage.rotate(image, angle, cval=255)


def save_license_plate(path_to_file, path_to_save):
    """Attempt OCR on a car crop to extract license plate text."""
    try:
        original_image = cv2.imread(path_to_file)
        if original_image is None:
            return

        gray_image = cv2.cvtColor(original_image, cv2.COLOR_BGR2GRAY)
        gray_image = cv2.bilateralFilter(gray_image, 11, 17, 17)
        edged_image = cv2.Canny(gray_image, 30, 200)
        contours, _ = cv2.findContours(edged_image.copy(), cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        contours = sorted(contours, key=cv2.contourArea, reverse=True)[:30]

        idx = 0
        for c in contours:
            contour_perimeter = cv2.arcLength(c, True)
            approx = cv2.approxPolyDP(c, 0.018 * contour_perimeter, True)

            if len(approx) == 4:
                x, y, w, h = cv2.boundingRect(c)
                (_, _), (_, _), angle_of_rotation = cv2.minAreaRect(c)

                resX, resY = gray_image.shape[1], gray_image.shape[0]
                target = np.full((resY, resX, 3), 255, dtype=np.uint8)
                mask = np.zeros((resY, resX, 1), dtype=np.uint8)
                box_points = np.intp(cv2.boxPoints(cv2.minAreaRect(c)))
                cv2.drawContours(mask, [box_points], -1, (255), -1)

                inv = 255 - original_image
                target = cv2.bitwise_and(target, inv, mask=mask)
                target = 255 - target
                new_img = target[y : y + h, x : x + w]

                img_rotated = rotate_image(new_img, -90 + angle_of_rotation)
                gray = cv2.cvtColor(img_rotated, cv2.COLOR_BGR2GRAY)
                blur = cv2.GaussianBlur(gray, (3, 3), 0)
                thresh = cv2.adaptiveThreshold(
                    blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 33, 14
                )
                kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
                opening = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, kernel, iterations=1)

                idx += 1
                text = pytesseract.image_to_string(gray, lang="eng")
                text_blur = pytesseract.image_to_string(blur, lang="eng")

                # Use whichever result is longer
                best = text if len(text) >= len(text_blur) else text_blur
                if len(best) > 4:
                    clean = re.sub(r"[\W_]", "", best)
                    out_path = f"{path_to_save}_{clean}_{idx}.jpg"
                    cv2.imwrite(out_path, gray)
                    logger.info("Plate OCR: %s -> %s", clean, out_path)
                    # Check against plate registry
                    try:
                        check_plate_registry(clean)
                    except Exception:
                        logger.exception("Plate registry check error for %s", clean)

    except Exception:
        logger.exception("OCR error on %s", path_to_file)


def creation_date(path_to_file):
    """Get file creation date (falls back to mtime on Linux)."""
    stat = os.stat(path_to_file)
    try:
        return time.localtime(stat.st_birthtime)
    except AttributeError:
        return time.localtime(stat.st_mtime)


def process_file(subdir, file):
    """Process a single detection crop file — move to organized output dir."""
    full_path = os.path.join(subdir, file)
    parts = full_path.replace("\\", "/").split("/")

    # YOLOv5 crop() saves to: runs/cam2/detect/exp/<expN>/<label>/file.jpg
    # The object type (label) is always the PARENT directory of the file.
    # The camera name is always the first dir under 'runs'.
    if len(parts) < 4:
        return

    try:
        # Object type = immediate parent directory of the file
        object_type = parts[-2]

        # Skip if parent looks like an "exp" dir (no label extracted)
        if object_type.startswith("exp") or object_type == "detect":
            return

        # Find 'runs' in path to get camera name
        runs_idx = None
        for i, p in enumerate(parts):
            if p == "runs":
                runs_idx = i
                break

        if runs_idx is None or runs_idx + 1 >= len(parts):
            return

        camera = parts[runs_idx + 1]       # e.g. "cam2"
    except IndexError:
        return

    t = creation_date(full_path)
    date_str = f"{t.tm_year}_{str(t.tm_mon).zfill(2)}_{str(t.tm_mday).zfill(2)}"
    time_str = f"{str(t.tm_hour).zfill(2)}_{str(t.tm_min).zfill(2)}_{str(t.tm_sec).zfill(2)}"

    dest_dir = os.path.join(config.OUTPUT_DIR, camera, object_type, date_str)
    os.makedirs(dest_dir, exist_ok=True)

    # OCR for cars
    if object_type == "car":
        plate_dir = os.path.join(config.OUTPUT_DIR, camera, "LicensePlate", date_str)
        os.makedirs(plate_dir, exist_ok=True)
        save_license_plate(full_path, os.path.join(plate_dir, time_str))

    dest_path = os.path.join(dest_dir, time_str + ".jpg")
    shutil.move(full_path, dest_path)
    logger.debug("Moved %s -> %s", file, dest_path)

    # Copy to HA sliding window (person and vehicle types only)
    try:
        copy_to_ha_sliding_window(dest_path, object_type)
    except Exception:
        logger.exception("Sliding window copy error for %s", dest_path)


def run():
    runs_dir = config.RUNS_DIR
    os.makedirs(runs_dir, exist_ok=True)
    os.makedirs(config.OUTPUT_DIR, exist_ok=True)

    logger.info("Watching: %s -> %s", runs_dir, config.OUTPUT_DIR)

    while True:
        try:
            moved = 0
            for subdir, dirs, files in os.walk(runs_dir):
                for file in files:
                    if not file.lower().endswith((".jpg", ".jpeg", ".png")):
                        continue
                    try:
                        process_file(subdir, file)
                        moved += 1
                    except Exception:
                        logger.exception("Error processing %s", os.path.join(subdir, file))

            if moved > 0:
                logger.info("Moved %d detection files", moved)

        except Exception:
            logger.exception("Error in process loop")

        time.sleep(config.PROCESS_INTERVAL)


if __name__ == "__main__":
    run()
