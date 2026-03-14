"""
gemini_verify.py - Gemini LLM verification for loitering detections.
Compares first/last crop images to confirm they're the same object.
"""

import base64
import json
import logging

import cv2
import numpy as np
import requests

import config

logger = logging.getLogger("GeminiVerify")


def _encode_crop(crop_rgb):
    """Convert RGB numpy array to base64-encoded JPEG string."""
    bgr = cv2.cvtColor(crop_rgb, cv2.COLOR_RGB2BGR)
    success, buf = cv2.imencode(".jpg", bgr)
    if not success:
        return None
    return base64.b64encode(buf).decode("utf-8")


def verify_loitering(first_crop, last_crop):
    """
    Send two crop images to Gemini for same-object verification.

    Args:
        first_crop: RGB numpy array of first sighting
        last_crop: RGB numpy array of last sighting

    Returns:
        dict with {"same_object": bool, "description": str, "reason": str}
        or None on failure.
    """
    if not config.GEMINI_API_KEY:
        logger.debug("No GEMINI_API_KEY — skipping verification")
        return None

    b64_first = _encode_crop(first_crop)
    b64_last = _encode_crop(last_crop)
    if not b64_first or not b64_last:
        logger.warning("Failed to encode crops for Gemini")
        return None

    url = (
        f"{config.GEMINI_API_URL}/{config.GEMINI_MODEL}:generateContent"
        f"?key={config.GEMINI_API_KEY}"
    )

    payload = {
        "contents": [
            {
                "parts": [
                    {"text": config.GEMINI_LOITERING_PROMPT},
                    {
                        "inline_data": {
                            "mime_type": "image/jpeg",
                            "data": b64_first,
                        }
                    },
                    {
                        "inline_data": {
                            "mime_type": "image/jpeg",
                            "data": b64_last,
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

    try:
        resp = requests.post(url, json=payload, timeout=config.GEMINI_TIMEOUT)
        if resp.status_code != 200:
            logger.warning("Gemini API error %d: %s", resp.status_code, resp.text[:200])
            return None

        data = resp.json()
        text = data["candidates"][0]["content"]["parts"][0]["text"]
        result = json.loads(text)

        same = result.get("same_object", True)
        desc = result.get("description", "")
        reason = result.get("reason", "")

        logger.info("Gemini verify: same=%s, desc='%s', reason='%s'", same, desc, reason)
        return {"same_object": same, "description": desc, "reason": reason}

    except (requests.RequestException, KeyError, json.JSONDecodeError) as e:
        logger.warning("Gemini verify failed: %s", e)
        return None
