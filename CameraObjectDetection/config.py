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
LOITERING_MAX_GAP_SECONDS = 30  # Reset track if unseen for this long (Gemini handles false re-ID)
LOITERING_MIN_HITS = 10  # Minimum detection count before firing alert
DEEPSORT_MAX_AGE = 30  # Keep tracks alive longer on CPU (was 10, too aggressive for ~2s/frame)
DEEPSORT_N_INIT = 3
DEEPSORT_MAX_IOU_DISTANCE = 0.7
LOITERING_IMAGE_FIRST = "street_loitering_first.jpg"
LOITERING_IMAGE_LAST = "street_loitering_last.jpg"

# ============================================================
# Gemini LLM Verification
# ============================================================
GEMINI_API_KEY = ""  # Set via env GEMINI_API_KEY, or patched during deploy
GEMINI_MODEL = "gemini-2.5-flash"
GEMINI_API_URL = "https://generativelanguage.googleapis.com/v1beta/models"
GEMINI_TIMEOUT = 15

_env_gemini = os.environ.get("GEMINI_API_KEY", "")
if _env_gemini:
    GEMINI_API_KEY = _env_gemini

GEMINI_LOITERING_PROMPT = """Analyze these two security camera crops. Image 1 is "first seen", Image 2 is "last seen".
Are both images of the SAME object (person/car/truck/bus)?
Respond JSON only: {"same_object": true/false, "description": "brief visual description", "reason": "explanation"}"""

GEMINI_PLATE_PROMPT = """Read the license plate text from this image of a vehicle. This is a South African license plate.
SA plate format: 2-3 letters, 2-3 digits, then a 2-letter province code (GP, WP, NW, MP, LP, FS, KZN, EC, NC).
Examples: KH78WWGP, MR80BWGP, JHS001MP, DC39SHGP
Return JSON only: {"plate": "ABC123GP", "confidence": 0.95}
If no plate is readable, return: {"plate": "", "confidence": 0}"""

PLATE_GEMINI_CONFIDENCE = 0.4  # minimum confidence to accept Gemini result
PLATE_OCR_STATS_PATH = os.path.join(SCRIPT_DIR, ".plate_ocr_stats.json")

# ============================================================
# Logging
# ============================================================
LOG_DIR = os.path.join(SCRIPT_DIR, "logs")
LOG_MAX_BYTES = 5 * 1024 * 1024  # 5 MB per log file
LOG_BACKUP_COUNT = 3
