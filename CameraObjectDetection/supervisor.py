"""
supervisor.py - Process monitor for CameraObjectDetection pipeline.
Launches SampleImages.py, DetectObjects3.py, and ProcessCropFiles.py as subprocesses.
Monitors every 30 seconds and auto-restarts any crashed processes.
Handles graceful shutdown on Ctrl+C / SIGTERM.
"""

import os
import sys
import signal
import subprocess
import time
import logging
from logging.handlers import RotatingFileHandler

# ============================================================
# Configuration
# ============================================================
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PYTHON = sys.executable

SCRIPTS = [
    {"name": "SampleImages", "file": "SampleImages.py"},
    {"name": "DetectObjects3", "file": "DetectObjects3.py"},
    {"name": "ProcessCropFiles", "file": "ProcessCropFiles.py"},
    {"name": "HAMetrics", "file": "ha_metrics.py"},
]

CHECK_INTERVAL = 30  # seconds between health checks

# ============================================================
# Logging setup
# ============================================================
LOG_DIR = os.path.join(SCRIPT_DIR, "logs")
os.makedirs(LOG_DIR, exist_ok=True)

logger = logging.getLogger("Supervisor")
logger.setLevel(logging.INFO)
handler = RotatingFileHandler(
    os.path.join(LOG_DIR, "supervisor.log"),
    maxBytes=5 * 1024 * 1024,
    backupCount=3,
)
handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
logger.addHandler(handler)
logger.addHandler(logging.StreamHandler(sys.stdout))

# ============================================================
# Process management
# ============================================================
processes = {}  # name -> subprocess.Popen
shutting_down = False


def start_process(script_info):
    """Launch a script as a subprocess."""
    name = script_info["name"]
    script_path = os.path.join(SCRIPT_DIR, script_info["file"])

    if not os.path.exists(script_path):
        logger.error("Script not found: %s", script_path)
        return None

    logger.info("Starting %s ...", name)
    stderr_log = os.path.join(LOG_DIR, f"{name.lower()}_stderr.log")
    stderr_fh = open(stderr_log, "a")
    proc = subprocess.Popen(
        [PYTHON, "-u", script_path],
        cwd=SCRIPT_DIR,
        stdout=subprocess.DEVNULL,
        stderr=stderr_fh,
    )
    processes[name] = proc
    logger.info("Started %s (PID %d)", name, proc.pid)
    return proc


def stop_all():
    """Gracefully terminate all child processes."""
    global shutting_down
    shutting_down = True
    logger.info("Stopping all processes...")

    for name, proc in processes.items():
        if proc.poll() is None:
            logger.info("Terminating %s (PID %d)", name, proc.pid)
            proc.terminate()

    # Wait up to 10 seconds for graceful exit
    deadline = time.time() + 10
    for name, proc in processes.items():
        remaining = max(0, deadline - time.time())
        try:
            proc.wait(timeout=remaining)
            logger.info("%s exited (code %d)", name, proc.returncode)
        except subprocess.TimeoutExpired:
            logger.warning("Force killing %s (PID %d)", name, proc.pid)
            proc.kill()
            proc.wait()


def signal_handler(signum, frame):
    """Handle shutdown signals."""
    sig_name = signal.Signals(signum).name if hasattr(signal, "Signals") else str(signum)
    logger.info("Received %s — shutting down", sig_name)
    stop_all()
    sys.exit(0)


def monitor_loop():
    """Main monitoring loop — check processes and restart any that died."""
    logger.info("=" * 60)
    logger.info("CameraObjectDetection Supervisor starting")
    logger.info("Python: %s", PYTHON)
    logger.info("Scripts: %s", ", ".join(s["name"] for s in SCRIPTS))
    logger.info("Check interval: %ds", CHECK_INTERVAL)
    logger.info("=" * 60)

    # Initial launch
    for script_info in SCRIPTS:
        start_process(script_info)

    # Stagger startup slightly
    time.sleep(2)

    while not shutting_down:
        for script_info in SCRIPTS:
            name = script_info["name"]
            proc = processes.get(name)

            if proc is None or proc.poll() is not None:
                exit_code = proc.returncode if proc else "never started"
                logger.warning("%s is not running (exit code: %s) — restarting", name, exit_code)
                start_process(script_info)

        time.sleep(CHECK_INTERVAL)


def main():
    # Register signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, signal_handler)

    try:
        monitor_loop()
    except Exception:
        logger.exception("Fatal error in supervisor")
        stop_all()
        sys.exit(1)


if __name__ == "__main__":
    main()
