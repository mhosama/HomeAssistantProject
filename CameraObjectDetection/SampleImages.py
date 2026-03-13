"""
SampleImages.py - Captures frames from RTSP stream at a configurable sample rate.
Saves JPEG images to SAMPLE_DIR for DetectObjects3.py to process.
Auto-reconnects on stream failure.
"""

import cv2
import os
import sys
import logging
import time
from datetime import datetime
from logging.handlers import RotatingFileHandler

import config

# ============================================================
# Logging setup
# ============================================================
os.makedirs(config.LOG_DIR, exist_ok=True)
logger = logging.getLogger("SampleImages")
logger.setLevel(logging.INFO)
handler = RotatingFileHandler(
    os.path.join(config.LOG_DIR, "sample_images.log"),
    maxBytes=config.LOG_MAX_BYTES,
    backupCount=config.LOG_BACKUP_COUNT,
)
handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(handler)
logger.addHandler(logging.StreamHandler(sys.stdout))


def connect_rtsp():
    """Open RTSP stream. Returns VideoCapture or None."""
    logger.info("Connecting to RTSP: %s", config.RTSP_URL.split("@")[-1])
    cap = cv2.VideoCapture(config.RTSP_URL)
    if cap.isOpened():
        fps = cap.get(cv2.CAP_PROP_FPS)
        logger.info("Connected. Stream FPS: %.1f", fps)
        return cap
    else:
        logger.warning("Failed to open RTSP stream")
        cap.release()
        return None


def run():
    os.makedirs(config.SAMPLE_DIR, exist_ok=True)
    logger.info("Sample dir: %s | Sample rate: every %d frames", config.SAMPLE_DIR, config.SAMPLE_RATE)

    while True:
        cap = connect_rtsp()
        if cap is None:
            logger.info("Retrying in %ds...", config.RECONNECT_DELAY)
            time.sleep(config.RECONNECT_DELAY)
            continue

        frame_count = 0
        try:
            while cap.isOpened():
                ret, frame = cap.read()
                if not ret:
                    logger.warning("Frame read failed — stream may have dropped")
                    break

                frame_count += 1
                if frame_count < config.SAMPLE_RATE:
                    continue
                frame_count = 0

                filename = os.path.join(
                    config.SAMPLE_DIR,
                    "image_" + datetime.now().strftime("%Y-%m-%d_%H-%M-%S_%f")[:-3] + ".jpg",
                )
                cv2.imwrite(filename, frame)
                logger.debug("Saved %s", filename)
        except Exception:
            logger.exception("Error during frame capture")
        finally:
            cap.release()

        logger.info("Stream ended. Reconnecting in %ds...", config.RECONNECT_DELAY)
        time.sleep(config.RECONNECT_DELAY)


if __name__ == "__main__":
    run()
