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
PLATE_GEMINI_DAILY_CAP = 100  # max Gemini plate OCR calls per day (safety net)
PLATE_OCR_STATS_PATH = os.path.join(SCRIPT_DIR, ".plate_ocr_stats.json")

# ============================================================
# Gemini Token Usage Tracking
# ============================================================
# Hardcoded to match PS scripts' $scriptDir on server — both callers must use the same file
GEMINI_STATS_PATH = r"C:\Work\HomeAssistantProject\deploy\.gemini_token_stats.json"

# Gemini 2.5 Flash pricing (USD per 1M tokens)
GEMINI_INPUT_PRICE_PER_M = 0.30
GEMINI_OUTPUT_PRICE_PER_M = 2.50


def update_gemini_token_stats(source, calls=1, prompt_tokens=0, completion_tokens=0, total_tokens=0):
    """Update shared Gemini token stats file with cross-process file locking (Windows).

    Args:
        source: Caller identifier (e.g. "plate_ocr", "loitering_verify")
        calls: Number of API calls made
        prompt_tokens: Input tokens from usageMetadata.promptTokenCount
        completion_tokens: Output tokens from usageMetadata.candidatesTokenCount
        total_tokens: Total tokens from usageMetadata.totalTokenCount
    """
    import msvcrt
    from datetime import datetime as _dt

    stats_path = GEMINI_STATS_PATH
    today = _dt.now().strftime("%Y-%m-%d")

    try:
        os.makedirs(os.path.dirname(stats_path), exist_ok=True)

        # Open or create the file
        if not os.path.exists(stats_path):
            with open(stats_path, "w") as f:
                import json as _json
                _json.dump({"daily_date": today, "sources": {}, "daily_history": []}, f)

        import json as _json

        with open(stats_path, "r+") as f:
            # Lock first byte (blocking, up to ~1s) — acts as advisory lock
            msvcrt.locking(f.fileno(), msvcrt.LK_LOCK, 1)
            try:
                content = f.read()
                stats = _json.loads(content) if content.strip() else {"daily_date": today, "sources": {}, "daily_history": []}

                # Daily rollover — archive yesterday's totals
                if stats.get("daily_date") != today:
                    old_date = stats.get("daily_date", "")
                    if old_date and stats.get("sources"):
                        # Sum all sources for yesterday's total (per-source pricing)
                        # Gemini 2.5 Pro sources use higher pricing ($1.25/$10.00 per M tokens)
                        _PRO_SOURCES = {"ezviz_vision_pro"}
                        _PRO_INPUT_PM, _PRO_OUTPUT_PM = 1.25, 10.00
                        day_calls = sum(s.get("calls", 0) for s in stats["sources"].values())
                        day_prompt = sum(s.get("prompt_tokens", 0) for s in stats["sources"].values())
                        day_completion = sum(s.get("completion_tokens", 0) for s in stats["sources"].values())
                        day_total = sum(s.get("total_tokens", 0) for s in stats["sources"].values())
                        day_cost = 0
                        for sname, sdata in stats["sources"].items():
                            sp, sc = sdata.get("prompt_tokens", 0), sdata.get("completion_tokens", 0)
                            if sname in _PRO_SOURCES:
                                day_cost += (sp * _PRO_INPUT_PM + sc * _PRO_OUTPUT_PM) / 1_000_000
                            else:
                                day_cost += (sp * GEMINI_INPUT_PRICE_PER_M + sc * GEMINI_OUTPUT_PRICE_PER_M) / 1_000_000

                        history = stats.get("daily_history", [])
                        history.append({
                            "date": old_date,
                            "calls": day_calls,
                            "prompt_tokens": day_prompt,
                            "completion_tokens": day_completion,
                            "total_tokens": day_total,
                            "estimated_cost_usd": round(day_cost, 4),
                        })
                        # Keep last 30 days
                        stats["daily_history"] = history[-30:]

                    stats["daily_date"] = today
                    stats["sources"] = {}

                # Update source counters
                sources = stats.setdefault("sources", {})
                src = sources.setdefault(source, {"calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0})
                src["calls"] += calls
                src["prompt_tokens"] += prompt_tokens
                src["completion_tokens"] += completion_tokens
                src["total_tokens"] += total_tokens

                # Write back
                f.seek(0)
                f.truncate()
                _json.dump(stats, f, indent=2)
            finally:
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
    except Exception:
        pass  # Non-critical — don't break callers


# ============================================================
# Logging
# ============================================================
LOG_DIR = os.path.join(SCRIPT_DIR, "logs")
LOG_MAX_BYTES = 5 * 1024 * 1024  # 5 MB per log file
LOG_BACKUP_COUNT = 3
