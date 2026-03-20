"""
DetectObjects3.py - Runs YOLOv5 on sampled images from SAMPLE_DIR.
Skips near-duplicate frames (MSE threshold), saves cropped detections to RUNS_DIR.
Processed input images are deleted after detection.
"""

import os
import sys
import logging
import time
import shutil
from datetime import datetime
from logging.handlers import RotatingFileHandler

import cv2
import numpy as np
import requests
import torch
from deep_sort_realtime.deepsort_tracker import DeepSort

import config
import alerts
import gemini_verify

# ============================================================
# Logging setup
# ============================================================
os.makedirs(config.LOG_DIR, exist_ok=True)
logger = logging.getLogger("DetectObjects3")
logger.setLevel(logging.INFO)
handler = RotatingFileHandler(
    os.path.join(config.LOG_DIR, "detect_objects.log"),
    maxBytes=config.LOG_MAX_BYTES,
    backupCount=config.LOG_BACKUP_COUNT,
)
handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(handler)
logger.addHandler(logging.StreamHandler(sys.stdout))


def compute_mse(img1, img2):
    """Compute mean squared error between two images."""
    g1 = cv2.cvtColor(img1, cv2.COLOR_BGR2GRAY)
    g2 = cv2.cvtColor(img2, cv2.COLOR_BGR2GRAY)
    h, w = g1.shape
    diff = cv2.subtract(g1, g2)
    err = np.sum(diff ** 2)
    return err / float(h * w)


def load_model():
    """Load YOLOv5 model from PyTorch Hub."""
    logger.info("Loading YOLOv5 model: %s", config.YOLO_MODEL)
    model = torch.hub.load("ultralytics/yolov5", config.YOLO_MODEL)
    if torch.cuda.is_available():
        model.cuda()
        logger.info("CUDA enabled")
    else:
        logger.info("Running on CPU")
    model.conf = config.CONFIDENCE_THRESHOLD
    logger.info("Confidence threshold: %.2f", model.conf)
    return model


def init_tracker():
    """Initialize Deep SORT tracker for re-identification."""
    logger.info("Initializing Deep SORT tracker")
    tracker = DeepSort(
        max_age=config.DEEPSORT_MAX_AGE,
        n_init=config.DEEPSORT_N_INIT,
        max_iou_distance=config.DEEPSORT_MAX_IOU_DISTANCE,
    )
    logger.info("Deep SORT ready (max_age=%d, n_init=%d)", config.DEEPSORT_MAX_AGE, config.DEEPSORT_N_INIT)
    return tracker


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


def _find_best_crop(track, detection_crops):
    """Find the YOLOv5 crop that best matches a Deep SORT track's position and class."""
    if not detection_crops:
        return None
    # Get the track's class to filter by same object type
    track_class = track.det_class if hasattr(track, "det_class") else None
    ltrb = track.to_ltrb()
    tx, ty = (ltrb[0] + ltrb[2]) / 2, (ltrb[1] + ltrb[3]) / 2
    best, best_dist = None, float("inf")
    for (cx, cy), (crop_img, cls_name) in detection_crops.items():
        # Only match crops of the same class
        if track_class and cls_name != track_class:
            continue
        dist = (tx - cx) ** 2 + (ty - cy) ** 2
        if dist < best_dist:
            best_dist = dist
            best = crop_img
    return best


def _save_loitering_images(first_crop, last_crop, track_id):
    """Save first and last loitering crops to HA www via Samba."""
    samba_dir = config.HA_WWW_SAMBA
    if not os.path.isdir(samba_dir):
        logger.debug("Samba www dir not accessible: %s", samba_dir)
        return None, None

    first_url, last_url = None, None
    try:
        if first_crop is not None:
            dest = os.path.join(samba_dir, config.LOITERING_IMAGE_FIRST)
            cv2.imwrite(dest, first_crop[:, :, ::-1])
            first_url = f"/local/{config.LOITERING_IMAGE_FIRST}"
        if last_crop is not None:
            dest = os.path.join(samba_dir, config.LOITERING_IMAGE_LAST)
            cv2.imwrite(dest, last_crop[:, :, ::-1])
            last_url = f"/local/{config.LOITERING_IMAGE_LAST}"
        logger.info("Loitering images saved (track %s)", track_id)
    except Exception:
        logger.exception("Error saving loitering images")

    return first_url, last_url


# Cached loitering toggle state (avoids per-frame HTTP calls to HA)
_loiter_toggle_cache = True
_loiter_toggle_last_check = 0


def _is_loitering_enabled():
    """Check HA toggle, cached for 30 seconds."""
    global _loiter_toggle_cache, _loiter_toggle_last_check
    now = time.time()
    if now - _loiter_toggle_last_check < 30:
        return _loiter_toggle_cache
    _loiter_toggle_last_check = now
    if not config.HA_TOKEN:
        return True
    try:
        resp = requests.get(
            f"{config.HA_URL}/api/states/input_boolean.loitering_detection",
            headers={"Authorization": f"Bearer {config.HA_TOKEN}"},
            timeout=3,
        )
        if resp.status_code == 200:
            _loiter_toggle_cache = resp.json().get("state") != "off"
        # 404 = entity doesn't exist yet, treat as enabled
    except Exception:
        logger.debug("Toggle check failed, keeping current state: %s", _loiter_toggle_cache)
    return _loiter_toggle_cache


# Last loitering alert info — preserved when sensor goes to "clear"
_last_loiter_info = {"object_type": None, "detected_at": None, "duration_seconds": 0,
                     "image_first": None, "image_last": None}

# Daily loitering verification counters
_loiter_counters = {"unconfirmed": 0, "confirmed": 0, "false": 0, "date": ""}


def _push_loiter_counter_sensors():
    """Push all 3 loitering counter sensors to HA."""
    for name in ("unconfirmed", "confirmed", "false"):
        icon = {"unconfirmed": "mdi:account-question",
                "confirmed": "mdi:account-check",
                "false": "mdi:account-cancel"}[name]
        _push_sensor(f"sensor.street_cam_{name}_loitering_today", str(_loiter_counters[name]), {
            "friendly_name": f"Street Cam {name.title()} Loitering Today",
            "icon": icon,
            "unit_of_measurement": "detections",
        })


def _increment_loiter_counter(name):
    """Increment a loitering counter, resetting all if the date changed."""
    today = datetime.now().strftime("%Y-%m-%d")
    if _loiter_counters["date"] != today:
        _loiter_counters["unconfirmed"] = 0
        _loiter_counters["confirmed"] = 0
        _loiter_counters["false"] = 0
        _loiter_counters["date"] = today
    _loiter_counters[name] += 1
    _push_loiter_counter_sensors()


def check_loitering(tracker, frame, detections_xyxy, class_names, crop_images,
                     track_first_seen, loiter_cooldowns, track_first_crops,
                     track_last_seen, track_hit_count, track_latest_crops):
    """
    Feed detections to Deep SORT and check for loitering.
    crop_images: list of numpy arrays from results.crop() matching detections_xyxy order.
    track_first_crops: dict[track_id] -> numpy crop of the object when first seen.
    track_latest_crops: dict[track_id] -> most recent numpy crop (updated every frame).
    track_last_seen: dict[track_id] -> timestamp of last detection (gap detection).
    track_hit_count: dict[track_id] -> number of frames this track was detected in.
    Returns True if a new loitering alert was fired.
    """
    global _last_loiter_info
    now = time.time()

    # Check cached toggle — skip entirely when disabled (don't touch tracker)
    if not _is_loitering_enabled():
        return False

    # Build detection list for deep-sort-realtime: ([x1, y1, w, h], conf, class_name)
    # Also build a center->crop lookup from YOLOv5's actual crops
    raw_detections = []
    detection_crops = {}  # (center_x, center_y) -> (crop numpy array, class_name)
    for i, (det, cls_name) in enumerate(zip(detections_xyxy, class_names)):
        if cls_name not in config.LOITERING_CLASSES:
            continue
        conf = det[4].item()
        if conf < config.LOITERING_MIN_CONFIDENCE:
            continue
        x1, y1, x2, y2 = det[:4].tolist()
        w, h = x2 - x1, y2 - y1
        raw_detections.append(([x1, y1, w, h], conf, cls_name))
        # Store the YOLOv5 crop + class keyed by bbox center
        if i < len(crop_images) and crop_images[i] is not None:
            cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
            detection_crops[(cx, cy)] = (crop_images[i], cls_name)

    # Update tracker
    tracks = tracker.update_tracks(raw_detections, frame=frame)

    active_track_ids = set()
    alert_fired = False

    for track in tracks:
        if not track.is_confirmed():
            continue

        track_id = track.track_id
        active_track_ids.add(track_id)

        # Gap detection: if track reappears after a long gap, it's likely a different object
        if track_id in track_last_seen:
            gap = now - track_last_seen[track_id]
            if gap > config.LOITERING_MAX_GAP_SECONDS:
                logger.info("Track %s gap %.1fs > %ds — resetting first_seen",
                            track_id, gap, config.LOITERING_MAX_GAP_SECONDS)
                track_first_seen.pop(track_id, None)
                track_hit_count[track_id] = 0
                track_first_crops.pop(track_id, None)
                track_latest_crops.pop(track_id, None)

        # Always update last_seen
        track_last_seen[track_id] = now

        # Record first seen time + save first crop from YOLOv5
        if track_id not in track_first_seen:
            track_first_seen[track_id] = now
            track_hit_count[track_id] = 1
            first_crop = _find_best_crop(track, detection_crops)
            if first_crop is not None:
                track_first_crops[track_id] = first_crop
                track_latest_crops[track_id] = first_crop
            continue

        # Increment hit count
        track_hit_count[track_id] = track_hit_count.get(track_id, 0) + 1
        hits = track_hit_count[track_id]

        # Keep the latest crop updated every frame (for loitering verification)
        current_crop = _find_best_crop(track, detection_crops)
        if current_crop is not None:
            track_latest_crops[track_id] = current_crop

        duration = now - track_first_seen[track_id]

        if duration >= config.LOITERING_THRESHOLD_SECONDS and hits >= config.LOITERING_MIN_HITS:
            # Check cooldown
            last_alert = loiter_cooldowns.get(track_id, 0)
            if (now - last_alert) >= config.LOITERING_ALERT_COOLDOWN:
                det_class = track.det_class if hasattr(track, "det_class") else "object"

                # Always count as unconfirmed first
                _increment_loiter_counter("unconfirmed")

                # Use YOLOv5 crops: first from when track started, last from most recent frame
                first_crop = track_first_crops.get(track_id)
                last_crop = track_latest_crops.get(track_id)
                first_url, last_url = _save_loitering_images(first_crop, last_crop, track_id)

                # Gemini verification: only fire alert if Gemini explicitly confirms
                verified = None
                gemini_desc = ""
                gemini_reason = ""
                alert_time = datetime.now().isoformat()

                if first_crop is None or last_crop is None:
                    # Missing crop — cannot verify, suppress alert
                    logger.warning("LOITERING SUPPRESSED (missing crop): track %s, %s, %ds — "
                                   "first_crop=%s, last_crop=%s",
                                   track_id, det_class, int(duration),
                                   "present" if first_crop is not None else "missing",
                                   "present" if last_crop is not None else "missing")
                    loiter_cooldowns[track_id] = now
                    continue

                result = gemini_verify.verify_loitering(first_crop, last_crop)
                if result is None:
                    # Gemini unavailable — suppress alert
                    logger.warning("LOITERING SUPPRESSED (Gemini unavailable): track %s, %s, %ds",
                                   track_id, det_class, int(duration))
                    loiter_cooldowns[track_id] = now
                    continue

                verified = result.get("same_object", False)
                gemini_desc = result.get("description", "")
                gemini_reason = result.get("reason", "")

                if not verified:
                    _increment_loiter_counter("false")
                    # Rejected — update sensor but skip alert
                    _last_loiter_info = {
                        "object_type": det_class,
                        "detected_at": alert_time,
                        "duration_seconds": int(duration),
                        "detection_hits": hits,
                        "image_first": first_url,
                        "image_last": last_url,
                    }
                    _push_sensor("sensor.street_cam_loitering", "rejected", {
                        "friendly_name": "Street Cam Loitering",
                        "icon": "mdi:account-clock",
                        "object_type": det_class,
                        "track_id": str(track_id),
                        "duration_seconds": int(duration),
                        "detection_hits": hits,
                        "detected_at": alert_time,
                        "entity_picture": last_url,
                        "image_first": first_url,
                        "image_last": last_url,
                        "verified": False,
                        "gemini_reason": gemini_reason,
                    })
                    loiter_cooldowns[track_id] = now
                    logger.info("LOITERING REJECTED by Gemini: track %s, %s — %s",
                                track_id, det_class, gemini_reason)
                    continue

                # Gemini confirmed — fire alert
                _increment_loiter_counter("confirmed")
                tts_desc = gemini_desc if gemini_desc else det_class
                _last_loiter_info = {
                    "object_type": det_class,
                    "detected_at": alert_time,
                    "duration_seconds": int(duration),
                    "detection_hits": hits,
                    "image_first": first_url,
                    "image_last": last_url,
                }

                _push_sensor("sensor.street_cam_loitering", "alert", {
                    "friendly_name": "Street Cam Loitering",
                    "icon": "mdi:account-clock",
                    "object_type": det_class,
                    "track_id": str(track_id),
                    "duration_seconds": int(duration),
                    "detection_hits": hits,
                    "detected_at": alert_time,
                    "entity_picture": last_url,
                    "image_first": first_url,
                    "image_last": last_url,
                    "verified": True,
                    "gemini_description": gemini_desc or None,
                })

                msg = f"Loitering detected: {tts_desc} visible for {int(duration)} seconds"
                alerts.send_alert(msg, title="Loitering Alert")
                loiter_cooldowns[track_id] = now
                alert_fired = True
                logger.warning("LOITERING ALERT: track %s, %s, %ds, %d hits (Gemini confirmed)",
                               track_id, det_class, int(duration), hits)

    # Clear state for gone tracks (stale > 120s)
    stale_ids = [tid for tid in list(track_first_seen.keys()) if tid not in active_track_ids]
    for tid in stale_ids:
        if (now - track_first_seen.get(tid, now)) > 120:
            del track_first_seen[tid]
            loiter_cooldowns.pop(tid, None)
            track_first_crops.pop(tid, None)
            track_latest_crops.pop(tid, None)
            track_last_seen.pop(tid, None)
            track_hit_count.pop(tid, None)

    # Set sensor to clear if no active loitering
    if not alert_fired:
        has_active_loitering = any(
            (now - track_first_seen.get(t, now)) >= config.LOITERING_THRESHOLD_SECONDS
            and track_hit_count.get(t, 0) >= config.LOITERING_MIN_HITS
            for t in active_track_ids if t in track_first_seen
        )
        if not has_active_loitering:
            _push_sensor("sensor.street_cam_loitering", "clear", {
                "friendly_name": "Street Cam Loitering",
                "icon": "mdi:account-clock",
                "object_type": _last_loiter_info.get("object_type"),
                "track_id": None,
                "duration_seconds": _last_loiter_info.get("duration_seconds", 0),
                "detection_hits": _last_loiter_info.get("detection_hits", 0),
                "detected_at": _last_loiter_info.get("detected_at"),
                "entity_picture": _last_loiter_info.get("image_last"),
                "image_first": _last_loiter_info.get("image_first"),
                "image_last": _last_loiter_info.get("image_last"),
            })

    return alert_fired


def run():
    os.makedirs(config.SAMPLE_DIR, exist_ok=True)
    save_dir = os.path.join(config.RUNS_DIR, config.CAMERA_NAME, "detect", "exp")
    os.makedirs(save_dir, exist_ok=True)

    model = load_model()
    tracker = init_tracker()
    old_frame = np.zeros((1, 1, 3), dtype=np.uint8)

    # Loitering state
    track_first_seen = {}  # track_id -> first_seen_timestamp
    loiter_cooldowns = {}  # track_id -> last_alert_timestamp
    track_first_crops = {}   # track_id -> numpy crop of first sighting
    track_latest_crops = {}  # track_id -> most recent numpy crop (updated every frame)
    track_last_seen = {}     # track_id -> last detection timestamp (gap detection)
    track_hit_count = {}     # track_id -> number of frames detected in

    logger.info("Watching: %s", config.SAMPLE_DIR)

    while True:
        try:
            files = sorted(os.listdir(config.SAMPLE_DIR))
            image_files = [f for f in files if f.lower().endswith((".jpg", ".jpeg", ".png"))]

            # Keep a few recent files as buffer (don't process the very latest)
            if len(image_files) <= 4:
                time.sleep(1)
                continue

            to_process = image_files[:-4]

            for fname in to_process:
                fpath = os.path.join(config.SAMPLE_DIR, fname)
                try:
                    frame = cv2.imread(fpath, cv2.IMREAD_COLOR)
                    if frame is None:
                        logger.warning("Failed to read image: %s", fname)
                        os.remove(fpath)
                        continue

                    # Initialize reference frame
                    if old_frame.shape[0] == 1:
                        old_frame = frame

                    mse = compute_mse(frame, old_frame)
                    if mse < config.MSE_THRESHOLD:
                        logger.debug("Skipped (MSE=%.1f < %d): %s", mse, config.MSE_THRESHOLD, fname)
                        old_frame = frame
                        os.remove(fpath)
                        continue

                    logger.info("Processing (MSE=%.1f): %s", mse, fname)
                    old_frame = frame

                    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                    results = model(rgb)
                    crops = results.crop(save_dir=save_dir)

                    # Deep SORT loitering detection
                    try:
                        detections = results.xyxy[0]  # tensor: [x1, y1, x2, y2, conf, cls]
                        if len(detections) > 0:
                            # Get class names and YOLOv5 crop images for each detection
                            cls_names = [results.names[int(d[5].item())] for d in detections]
                            crop_images = [c.get("im") for c in crops] if crops else []
                            check_loitering(
                                tracker, frame, detections, cls_names, crop_images,
                                track_first_seen, loiter_cooldowns, track_first_crops,
                                track_last_seen, track_hit_count, track_latest_crops,
                            )
                        else:
                            # No detections — still update tracker with empty list
                            tracker.update_tracks([], frame=frame)
                    except Exception:
                        logger.exception("Loitering check error")

                    os.remove(fpath)

                except Exception:
                    logger.exception("Error processing %s", fname)
                    try:
                        os.remove(fpath)
                    except OSError:
                        pass

        except Exception:
            logger.exception("Error in detection loop")
            time.sleep(5)

        time.sleep(0.5)


if __name__ == "__main__":
    run()
