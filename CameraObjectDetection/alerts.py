"""
alerts.py - Shared alert module for CameraObjectDetection.
Sends TTS and mobile notifications via Home Assistant REST API.
Used by ProcessCropFiles (plate alerts) and DetectObjects3 (loitering alerts).
"""

import logging
import requests

import config

logger = logging.getLogger("Alerts")

_mobile_service_cache = None


def _headers():
    return {
        "Authorization": f"Bearer {config.HA_TOKEN}",
        "Content-Type": "application/json",
    }


def send_tts(message):
    """Send TTS announcement via Google Translate TTS to kitchen speaker."""
    if not config.HA_TOKEN:
        logger.debug("No HA_TOKEN — skipping TTS")
        return False

    url = f"{config.HA_URL}/api/services/tts/speak"
    payload = {
        "entity_id": config.TTS_ENGINE,
        "media_player_entity_id": config.KITCHEN_SPEAKER,
        "message": message,
    }

    try:
        resp = requests.post(url, json=payload, headers=_headers(), timeout=10)
        if resp.status_code == 200:
            logger.info("TTS sent: %s", message[:80])
            return True
        else:
            logger.warning("TTS failed %d: %s", resp.status_code, resp.text[:200])
            return False
    except Exception:
        logger.exception("TTS error")
        return False


def discover_mobile_service():
    """Discover notify.mobile_app_* service from HA API. Caches result."""
    global _mobile_service_cache
    if _mobile_service_cache:
        return _mobile_service_cache

    if not config.HA_TOKEN:
        return None

    try:
        resp = requests.get(
            f"{config.HA_URL}/api/services",
            headers=_headers(),
            timeout=10,
        )
        if resp.status_code != 200:
            logger.warning("Failed to list services: %d", resp.status_code)
            return None

        for svc in resp.json():
            if svc.get("domain") == "notify":
                for service_name in svc.get("services", {}):
                    if service_name.startswith("mobile_app_"):
                        _mobile_service_cache = f"notify.{service_name}"
                        logger.info("Discovered mobile service: %s", _mobile_service_cache)
                        return _mobile_service_cache
    except Exception:
        logger.exception("Error discovering mobile service")

    return None


def send_mobile(title, message):
    """Send mobile push notification via HA notify service."""
    service = config.MOBILE_NOTIFY_SERVICE or discover_mobile_service()
    if not service:
        logger.debug("No mobile notify service available")
        return False

    if not config.HA_TOKEN:
        return False

    # Extract domain and service name (e.g., "notify.mobile_app_phone" -> "notify", "mobile_app_phone")
    parts = service.split(".", 1)
    if len(parts) != 2:
        logger.warning("Invalid notify service format: %s", service)
        return False

    url = f"{config.HA_URL}/api/services/{parts[0]}/{parts[1]}"
    payload = {
        "title": title,
        "message": message,
    }

    try:
        resp = requests.post(url, json=payload, headers=_headers(), timeout=10)
        if resp.status_code == 200:
            logger.info("Mobile notification sent: %s", title)
            return True
        else:
            logger.warning("Mobile notify failed %d: %s", resp.status_code, resp.text[:200])
            return False
    except Exception:
        logger.exception("Mobile notify error")
        return False


def send_alert(message, title="Street Camera Alert", speaker=True, mobile=True):
    """Convenience wrapper — send TTS and/or mobile alert."""
    results = {}
    if speaker:
        results["tts"] = send_tts(message)
    if mobile:
        results["mobile"] = send_mobile(title, message)
    return results
