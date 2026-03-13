"""
CameraObjectDetection - Central Configuration
All paths, URLs, and tuning parameters in one place.
"""

import os

# ============================================================
# Paths
# ============================================================
# Hardcoded to mhokl user — getpass.getuser() returns "DESKTOP-HG724B5$" when running as SYSTEM
SAMPLE_DIR = "C:/Users/mhokl/Documents/test"

# Where DetectObjects3.py writes YOLOv5 crop results
RUNS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "runs")

# Where ProcessCropFiles.py moves sorted detections
OUTPUT_DIR = "E:/CameraObjects/processed"

# ============================================================
# RTSP Camera
# ============================================================
RTSP_URL = "rtsp://admin:T3rrabyte@192.168.0.2:5105/stream1"
CAMERA_NAME = "cam2"

# ============================================================
# Detection Tuning
# ============================================================
# SampleImages: keep every Nth frame (skip frames between samples)
SAMPLE_RATE = 10

# SampleImages: seconds to wait before reconnecting on RTSP failure
RECONNECT_DELAY = 5

# DetectObjects3: YOLOv5 model variant (yolov5s, yolov5m, yolov5l, yolov5x)
YOLO_MODEL = "yolov5x"

# DetectObjects3: minimum confidence threshold for detections
CONFIDENCE_THRESHOLD = 0.5

# DetectObjects3: MSE threshold - frames below this are considered duplicates
MSE_THRESHOLD = 20

# ProcessCropFiles: seconds between directory scan cycles
PROCESS_INTERVAL = 10

# ============================================================
# Home Assistant Integration
# ============================================================
HA_URL = "http://homeassistant.local:8123"
HA_TOKEN = ""  # Set via environment variable HA_TOKEN, or fill in here

# Override token from environment if available
_env_token = os.environ.get("HA_TOKEN", "")
if _env_token:
    HA_TOKEN = _env_token

# Metrics push interval in seconds
METRICS_INTERVAL = 60

# ============================================================
# Plate Registry
# ============================================================
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLATE_REGISTRY_PATH = os.path.join(SCRIPT_DIR, "plate_registry.json")
PLATE_STATE_PATH = os.path.join(SCRIPT_DIR, ".plate_state.json")
PLATE_ALERT_COOLDOWN = 300  # 5 min

# ============================================================
# Alerts
# ============================================================
TTS_ENGINE = "tts.google_translate_en_com"
KITCHEN_SPEAKER = "media_player.kitchen_speaker"
MOBILE_NOTIFY_SERVICE = ""  # Auto-discovered from HA API, or set via env HA_NOTIFY_SERVICE

_env_notify = os.environ.get("HA_NOTIFY_SERVICE", "")
if _env_notify:
    MOBILE_NOTIFY_SERVICE = _env_notify

# ============================================================
# Image Sliding Window
# ============================================================
HA_WWW_SAMBA = r"\\192.168.0.239\config\www"
IMAGE_SLOTS = 5
IMAGE_STATE_PATH = os.path.join(SCRIPT_DIR, ".image_slots.json")

# ============================================================
# Loitering Detection
# ============================================================
LOITERING_THRESHOLD_SECONDS = 60
LOITERING_ALERT_COOLDOWN = 300  # 5 min
LOITERING_CLASSES = {"person", "car", "truck", "bus"}
LOITERING_MIN_CONFIDENCE = 0.7  # Only track high-confidence detections for loitering
DEEPSORT_MAX_AGE = 30
DEEPSORT_N_INIT = 3
DEEPSORT_MAX_IOU_DISTANCE = 0.7
LOITERING_IMAGE_FIRST = "street_loitering_first.jpg"
LOITERING_IMAGE_LAST = "street_loitering_last.jpg"

# ============================================================
# Logging
# ============================================================
LOG_DIR = os.path.join(SCRIPT_DIR, "logs")
LOG_MAX_BYTES = 5 * 1024 * 1024  # 5 MB per log file
LOG_BACKUP_COUNT = 3
