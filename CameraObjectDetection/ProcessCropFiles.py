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

import base64

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
    return {"cooldowns": {}, "known_today": {}, "known_date": "",
            "last_known_image": "", "last_known_owner": ""}


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


# OCR confusable characters — normalize lookalikes to digits
_CONFUSABLES = str.maketrans("OISZB", "01528")


def _normalize_confusables(text):
    """Map OCR-confusable letters to their digit lookalikes."""
    return text.translate(_CONFUSABLES)


# ============================================================
# Plate OCR daily stats (persisted to disk)
# ============================================================

def _load_plate_ocr_stats():
    """Load plate OCR stats from disk, reset on new day."""
    path = config.PLATE_OCR_STATS_PATH
    today = datetime.now().strftime("%Y-%m-%d")
    default = {"gemini_calls_today": 0, "tesseract_calls_today": 0,
               "plates_detected_today": 0, "known_plates_today": 0, "date": today}
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                stats = json.load(f)
            if stats.get("date") != today:
                return default
            return stats
        except Exception:
            pass
    return default


def _save_plate_ocr_stats(stats):
    """Save plate OCR stats to disk."""
    try:
        with open(config.PLATE_OCR_STATS_PATH, "w") as f:
            json.dump(stats, f, indent=2)
    except Exception:
        logger.exception("Error saving plate OCR stats")


# ============================================================
# SA plate validation
# ============================================================

_SA_PLATE_RE = re.compile(r"^[A-Z]{1,3}[0-9]{1,3}[A-Z]{2,4}$")


def _validate_sa_plate(text):
    """Check if text matches SA license plate format (6-10 chars).
    Format: 1-3 letters + 1-3 digits + 2-4 letters (registration + province code)."""
    if not text or len(text) < 6 or len(text) > 10:
        return False
    return bool(_SA_PLATE_RE.match(text))


# ============================================================
# Gemini plate OCR
# ============================================================

def _gemini_read_plate(img_bgr):
    """Send a car crop image to Gemini Flash for plate reading.

    Args:
        img_bgr: BGR numpy array (OpenCV format)

    Returns:
        (plate_text, confidence) or ("", 0) on failure
    """
    if not config.GEMINI_API_KEY:
        logger.debug("No GEMINI_API_KEY — skipping Gemini plate OCR")
        return ("", 0)

    # Encode image to base64 JPEG
    success, buf = cv2.imencode(".jpg", img_bgr)
    if not success:
        logger.warning("Failed to encode image for Gemini plate OCR")
        return ("", 0)
    b64_img = base64.b64encode(buf).decode("utf-8")

    url = (
        f"{config.GEMINI_API_URL}/{config.GEMINI_MODEL}:generateContent"
        f"?key={config.GEMINI_API_KEY}"
    )

    payload = {
        "contents": [
            {
                "parts": [
                    {"text": config.GEMINI_PLATE_PROMPT},
                    {
                        "inline_data": {
                            "mime_type": "image/jpeg",
                            "data": b64_img,
                        }
                    },
                ]
            }
        ],
        "generationConfig": {
            "responseMimeType": "application/json",
            "temperature": 0.1,
        },
    }

    # Track stats
    stats = _load_plate_ocr_stats()
    stats["gemini_calls_today"] = stats.get("gemini_calls_today", 0) + 1
    _save_plate_ocr_stats(stats)

    try:
        resp = requests.post(url, json=payload, timeout=config.GEMINI_TIMEOUT)
        if resp.status_code != 200:
            logger.warning("Gemini plate API error %d: %s", resp.status_code, resp.text[:200])
            return ("", 0)

        data = resp.json()

        # Track Gemini token usage
        usage = data.get("usageMetadata", {})
        try:
            config.update_gemini_token_stats(
                "plate_ocr",
                calls=1,
                prompt_tokens=usage.get("promptTokenCount", 0),
                completion_tokens=usage.get("candidatesTokenCount", 0),
                total_tokens=usage.get("totalTokenCount", 0),
            )
        except Exception:
            pass

        text = data["candidates"][0]["content"]["parts"][0]["text"]
        result = json.loads(text)

        plate = re.sub(r"[^A-Z0-9]", "", result.get("plate", "").upper())
        confidence = float(result.get("confidence", 0))

        logger.info("Gemini plate: %s (conf=%.2f)", plate, confidence)
        return (plate, confidence)

    except (requests.RequestException, KeyError, json.JSONDecodeError, ValueError) as e:
        logger.warning("Gemini plate OCR failed: %s", e)
        return ("", 0)


def _levenshtein(s1, s2):
    """Compute Levenshtein edit distance between two strings."""
    if len(s1) < len(s2):
        return _levenshtein(s2, s1)
    if len(s2) == 0:
        return len(s1)
    prev = list(range(len(s2) + 1))
    for i, c1 in enumerate(s1):
        curr = [i + 1]
        for j, c2 in enumerate(s2):
            curr.append(min(prev[j + 1] + 1, curr[j] + 1, prev[j] + (c1 != c2)))
        prev = curr
    return prev[-1]


def _best_substring_distance(registry_plate, detected_text):
    """Slide registry plate over detected text, return min Levenshtein distance.
    Handles detected text being longer (extra OCR chars) + substitution errors."""
    rlen = len(registry_plate)
    dlen = len(detected_text)
    if dlen < rlen:
        return _best_substring_distance(detected_text, registry_plate)
    if rlen == 0:
        return dlen
    best = _levenshtein(registry_plate, detected_text)
    for i in range(dlen - rlen + 1):
        window = detected_text[i:i + rlen]
        dist = _levenshtein(registry_plate, window)
        best = min(best, dist)
        if best == 0:
            return 0
    return best


def check_plate_registry(plate_text, crop_path=None, plate_img=None):
    """Look up a detected plate against the registry and fire alerts."""
    if not plate_text or len(plate_text) < 5:
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
    if len(normalized) < 5:
        return

    # Check cooldown
    last_alert = state["cooldowns"].get(normalized, 0)
    on_cooldown = (now - last_alert) < config.PLATE_ALERT_COOLDOWN

    plates_dict = registry.get("plates", {})
    match_key = None
    match_info = None
    for reg_plate, info in plates_dict.items():
        reg_normalized = re.sub(r"[^A-Z0-9]", "", reg_plate.upper())
        # Tier 1: exact substring
        if reg_normalized in normalized or normalized in reg_normalized:
            match_key = reg_plate
            match_info = info
            break
        # Tier 2: confusable-normalized substring
        reg_conf = _normalize_confusables(reg_normalized)
        det_conf = _normalize_confusables(normalized)
        if reg_conf in det_conf or det_conf in reg_conf:
            match_key = reg_plate
            match_info = info
            logger.info("Fuzzy plate match (confusable): detected=%s registry=%s", normalized, reg_normalized)
            break
        # Tier 3: sliding-window Levenshtein <= 2 (only if detected text is >= 60% of registry plate length)
        if len(det_conf) < len(reg_conf) * 0.6:
            continue
        dist = _best_substring_distance(reg_conf, det_conf)
        if dist <= 2:
            match_key = reg_plate
            match_info = info
            logger.info("Fuzzy plate match (distance=%d): detected=%s registry=%s", dist, normalized, reg_normalized)
            break

    is_known = match_info is not None
    owner = match_info.get("owner", "Unknown") if match_info else "Unknown"

    # Copy plate image to HA www for known plates
    # Prefer plate_img (contour crop, BGR) over crop_path (full car from YOLOv5)
    plate_image_url = ""
    if is_known:
        samba_dir = config.HA_WWW_SAMBA
        if os.path.isdir(samba_dir):
            dest = os.path.join(samba_dir, "street_known_plate.jpg")
            try:
                if plate_img is not None:
                    # plate_img is already BGR from cv2 pipeline — write directly
                    cv2.imwrite(dest, plate_img)
                    plate_image_url = "/local/street_known_plate.jpg"
                    logger.info("Known plate contour image written to %s", dest)
                elif crop_path and os.path.isfile(crop_path):
                    img = cv2.imread(crop_path)
                    if img is not None:
                        img_fixed = img[:, :, ::-1]  # fix R↔B channel swap from YOLOv5
                        cv2.imwrite(dest, img_fixed)
                    else:
                        shutil.copy2(crop_path, dest)
                    plate_image_url = "/local/street_known_plate.jpg"
                    logger.info("Known plate image (full car fallback) copied to %s", dest)
            except Exception:
                logger.exception("Failed to copy plate image to HA www")

    # Persist last known plate image in state so it survives unknown plate detections
    if is_known and plate_image_url:
        state["last_known_image"] = plate_image_url
        state["last_known_owner"] = owner

    # Push last plate sensor — always include entity_picture from current or persisted known plate
    effective_image = plate_image_url or state.get("last_known_image", "")
    attrs = {
        "friendly_name": "Street Cam Last Plate",
        "icon": "mdi:car-info",
        "owner": owner,
        "known": is_known,
        "time": datetime.now().isoformat(),
        "last_known_owner": state.get("last_known_owner", ""),
    }
    if effective_image:
        attrs["entity_picture"] = effective_image
    _push_sensor("sensor.street_cam_last_plate", normalized, attrs)

    if is_known:
        # Increment known plates count in OCR stats
        ocr_stats = _load_plate_ocr_stats()
        ocr_stats["known_plates_today"] = ocr_stats.get("known_plates_today", 0) + 1
        _save_plate_ocr_stats(ocr_stats)

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


_SA_PROVINCES = {"GP", "WP", "NW", "MP", "LP", "FS", "KZN", "EC", "NC"}


def _score_ocr_result(text):
    """Score an OCR result: higher = more likely correctly oriented.
    SA province suffix match is a strong signal; alphanumeric count is secondary."""
    clean = re.sub(r"[^A-Z0-9]", "", text.upper())
    score = len(clean)  # base: number of valid alphanumeric chars
    # Check for SA province suffix (last 2-3 chars)
    for suffix in _SA_PROVINCES:
        if clean.endswith(suffix):
            score += 50  # strong bonus for province match
            break
    return score, clean


def _ocr_on_image(img_bgr):
    """Run OCR on a BGR image, return (score, clean_text, gray_image)."""
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    blur = cv2.GaussianBlur(gray, (3, 3), 0)
    tess_config = "--psm 7 -c tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    text1 = pytesseract.image_to_string(gray, lang="eng", config=tess_config)
    text2 = pytesseract.image_to_string(blur, lang="eng", config=tess_config)
    score1, clean1 = _score_ocr_result(text1)
    score2, clean2 = _score_ocr_result(text2)
    if score1 >= score2:
        return score1, clean1, gray
    return score2, clean2, gray


def _extract_plate_contours(original_image):
    """Find plate-like rectangular contours in a car crop image.

    Returns list of (contour_img_rotated, x, y, w, h) tuples for each
    plate-like 4-sided contour found, sorted by area (largest first).
    """
    gray_image = cv2.cvtColor(original_image, cv2.COLOR_BGR2GRAY)
    gray_image = cv2.bilateralFilter(gray_image, 11, 17, 17)
    edged_image = cv2.Canny(gray_image, 30, 200)
    contours, _ = cv2.findContours(edged_image.copy(), cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    contours = sorted(contours, key=cv2.contourArea, reverse=True)[:30]

    results = []
    resX, resY = gray_image.shape[1], gray_image.shape[0]

    for c in contours:
        contour_perimeter = cv2.arcLength(c, True)
        approx = cv2.approxPolyDP(c, 0.018 * contour_perimeter, True)

        if len(approx) == 4:
            x, y, w, h = cv2.boundingRect(c)
            rect = cv2.minAreaRect(c)
            (cx, cy), (rw, rh), angle = rect

            target = np.full((resY, resX, 3), 255, dtype=np.uint8)
            mask = np.zeros((resY, resX, 1), dtype=np.uint8)
            box_points = np.intp(cv2.boxPoints(rect))
            cv2.drawContours(mask, [box_points], -1, (255), -1)

            inv = 255 - original_image
            target = cv2.bitwise_and(target, inv, mask=mask)
            target = 255 - target
            new_img = target[y : y + h, x : x + w]

            # Aspect-ratio-aware rotation: ensure plate is landscape
            rotation_angle = angle
            if rw < rh:
                rotation_angle += 90

            img_rotated = rotate_image(new_img, rotation_angle)

            # Enforce landscape: if still taller than wide, rotate 90°
            rh2, rw2 = img_rotated.shape[:2]
            if rh2 > rw2:
                img_rotated = rotate_image(img_rotated, 90)

            results.append(img_rotated)

    return results


def save_license_plate(path_to_file, path_to_save):
    """Attempt OCR on a car crop to extract license plate text.

    Two-pass approach (Tesseract-first to minimize Gemini costs):
    Pass 1: Contour-based extraction + Tesseract (free, local)
            If a valid SA plate is found, accept it immediately.
    Pass 2: Gemini fallback on the best plate contour crop (small image)
            Only called when Tesseract found contours but couldn't read them.
            Subject to daily call cap (PLATE_GEMINI_DAILY_CAP).

    Backlog protection: files older than 120s are skipped entirely.
    """
    try:
        original_image = cv2.imread(path_to_file)
        if original_image is None:
            return

        # Check file age — skip expensive OCR + alerts for backlogged files
        file_age = time.time() - os.path.getmtime(path_to_file)
        is_stale = file_age > 120  # older than 2 minutes
        if is_stale:
            logger.debug("Skipping plate OCR for stale file (%.0fs old): %s", file_age, path_to_file)
            return

        stats = _load_plate_ocr_stats()
        stats["tesseract_calls_today"] = stats.get("tesseract_calls_today", 0) + 1
        _save_plate_ocr_stats(stats)

        # === Pass 1: Contour-based extraction + Tesseract (free) ===
        plate_contours = _extract_plate_contours(original_image)

        best_gemini_candidate = None  # best contour crop for Gemini fallback
        best_gemini_candidate_area = 0
        idx = 0

        for img_rotated in plate_contours:
            # Dual-orientation OCR: try normal and 180° flipped, pick best
            img_flipped = cv2.rotate(img_rotated, cv2.ROTATE_180)

            score_normal, text_normal, gray_normal = _ocr_on_image(img_rotated)
            score_flipped, text_flipped, gray_flipped = _ocr_on_image(img_flipped)

            if score_flipped > score_normal:
                best_text = text_flipped
                best_gray = gray_flipped
                best_plate_img = img_flipped
            else:
                best_text = text_normal
                best_gray = gray_normal
                best_plate_img = img_rotated

            idx += 1

            # Track largest contour with >4 chars as Gemini fallback candidate
            area = img_rotated.shape[0] * img_rotated.shape[1]
            if len(best_text) > 2 and area > best_gemini_candidate_area:
                best_gemini_candidate = img_rotated
                best_gemini_candidate_area = area

            if len(best_text) > 4:
                out_path = f"{path_to_save}_{best_text}_{idx}.jpg"
                cv2.imwrite(out_path, best_gray)
                logger.info("Tesseract plate OCR: %s -> %s", best_text, out_path)
                # If Tesseract got a valid SA plate, accept it — no need for Gemini
                if _validate_sa_plate(best_text):
                    stats = _load_plate_ocr_stats()
                    stats["plates_detected_today"] = stats.get("plates_detected_today", 0) + 1
                    _save_plate_ocr_stats(stats)
                    try:
                        check_plate_registry(best_text, crop_path=path_to_file, plate_img=best_plate_img)
                    except Exception:
                        logger.exception("Plate registry check error for %s", best_text)
                    return  # Tesseract succeeded — done
                else:
                    logger.debug("Tesseract plate rejected (invalid SA format): %s", best_text)

        # === Pass 2: Gemini fallback on the plate contour crop (small image) ===
        # Only called when: contours were found but Tesseract couldn't read a valid plate
        if best_gemini_candidate is None:
            # No plate-like contours found at all — nothing to send to Gemini
            return

        # Check daily Gemini cap
        stats = _load_plate_ocr_stats()
        if stats.get("gemini_calls_today", 0) >= config.PLATE_GEMINI_DAILY_CAP:
            logger.debug("Gemini plate daily cap reached (%d), skipping",
                         config.PLATE_GEMINI_DAILY_CAP)
            return

        # Send the small plate contour crop (not the full car image) to Gemini
        plate_text, confidence = _gemini_read_plate(best_gemini_candidate)
        if confidence >= config.PLATE_GEMINI_CONFIDENCE and _validate_sa_plate(plate_text):
            logger.info("Gemini plate accepted (contour fallback): %s (conf=%.2f)", plate_text, confidence)
            out_path = f"{path_to_save}_{plate_text}_gemini.jpg"
            gray = cv2.cvtColor(best_gemini_candidate, cv2.COLOR_BGR2GRAY)
            cv2.imwrite(out_path, gray)
            stats = _load_plate_ocr_stats()
            stats["plates_detected_today"] = stats.get("plates_detected_today", 0) + 1
            _save_plate_ocr_stats(stats)
            try:
                check_plate_registry(plate_text, crop_path=path_to_file, plate_img=best_gemini_candidate)
            except Exception:
                logger.exception("Plate registry check error for %s", plate_text)
        elif plate_text:
            logger.debug("Gemini plate rejected (contour fallback): '%s' (conf=%.2f, valid=%s)",
                         plate_text, confidence, _validate_sa_plate(plate_text))

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
