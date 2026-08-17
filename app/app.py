import os
import subprocess
import psutil
import json
from flask import Flask, render_template, jsonify, request, abort

app = Flask(__name__)

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')

# Map of allowed actions — add/remove as needed
ACTIONS = {
    "reboot":        {"label": "Reboot",             "icon": "🔄", "confirm": True,  "script": "reboot.sh"},
    "shutdown":      {"label": "Shutdown",           "icon": "⏻",  "confirm": True,  "script": "shutdown.sh"},
    "update":        {"label": "Update system",      "icon": "⬆️", "confirm": True,  "script": "update.sh"},
    "temp":          {"label": "CPU Temperature",    "icon": "🌡️", "confirm": False, "script": "temp.sh"},
    "blink":         {"label": "Blink LED",          "icon": "💡", "confirm": False, "script": "blink.sh"},
    "custom":        {"label": "My script",          "icon": "⚙️", "confirm": False, "script": "custom.sh"},
}

SHARE_SCRIPT = "share_wifi.sh"
WIFI_SCRIPT = "wifi.sh"


def _run_script(script_name: str, args: list = None, timeout: int = 30) -> dict:
    path = os.path.realpath(os.path.join(SCRIPTS_DIR, script_name))
    # Ensures the script is inside SCRIPTS_DIR (path traversal)
    if not path.startswith(os.path.realpath(SCRIPTS_DIR) + os.sep):
        return {"ok": False, "output": "Script not allowed."}
    if not os.path.isfile(path):
        return {"ok": False, "output": f"Script not found: {script_name}"}
    try:
        cmd = ["bash", path] + (args or [])
        result = subprocess.run(
            cmd,
            capture_output=True, text=True, timeout=timeout
        )
        output = (result.stdout + result.stderr).strip()
        return {"ok": result.returncode == 0, "output": output or "(no output)"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": f"Timeout: script took more than {timeout}s"}
    except Exception as e:
        return {"ok": False, "output": str(e)}


@app.after_request
def no_cache(response):
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response


@app.route("/")
def index():
    return render_template("index.html", actions=ACTIONS)


@app.route("/api/status")
def status():
    try:
        temp_raw = open("/sys/class/thermal/thermal_zone0/temp").read().strip()
        temp_c = round(int(temp_raw) / 1000, 1)
    except Exception:
        temp_c = None

    mem = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    return jsonify({
        "cpu_percent": psutil.cpu_percent(interval=0.5),
        "mem_percent": mem.percent,
        "mem_used_mb": round(mem.used / 1024 / 1024),
        "mem_total_mb": round(mem.total / 1024 / 1024),
        "disk_percent": disk.percent,
        "disk_used_gb": round(disk.used / 1024**3, 1),
        "disk_total_gb": round(disk.total / 1024**3, 1),
        "temp_c": temp_c,
    })


@app.route("/api/action/<action_id>", methods=["POST"])
def run_action(action_id):
    if action_id not in ACTIONS:
        abort(404)
    script = ACTIONS[action_id]["script"]
    
    # System updates take longer on a Raspberry Pi Zero, so we increase the timeout to 10 minutes
    timeout = 600 if action_id == "update" else 30
    result = _run_script(script, timeout=timeout)
    
    return jsonify(result)


@app.route("/api/share_wifi/status")
def share_wifi_status():
    """Returns current internet sharing state."""
    result = _run_script(SHARE_SCRIPT, ["status"])
    active = result["ok"] and result["output"].strip() == "active"
    return jsonify({"active": active})


@app.route("/api/share_wifi/toggle", methods=["POST"])
def share_wifi_toggle():
    """Toggle internet sharing on/off."""
    # Check current state first
    check = _run_script(SHARE_SCRIPT, ["status"])
    currently_active = check["ok"] and check["output"].strip() == "active"
    # Toggle
    action = "off" if currently_active else "on"
    result = _run_script(SHARE_SCRIPT, [action])
    new_active = not currently_active if result["ok"] else currently_active
    return jsonify({"ok": result["ok"], "output": result["output"], "active": new_active})


@app.route("/api/wifi/scan")
def wifi_scan():
    """Returns list of nearby Wi-Fi networks."""
    result = _run_script(WIFI_SCRIPT, ["scan"], timeout=45)
    networks = []
    if result["ok"]:
        for line in result["output"].splitlines():
            parts = line.split(":")
            if len(parts) < 3 or not parts[0]:
                continue
            ssid, signal, security = parts[0], parts[1], parts[2]
            active = len(parts) > 3 and parts[3] == "yes"
            networks.append({
                "ssid": ssid,
                "signal": int(signal) if signal.isdigit() else 0,
                "security": security or "open",
                "active": active,
            })
    return jsonify({"ok": result["ok"], "networks": networks})


@app.route("/api/wifi/current")
def wifi_current():
    """Returns the currently connected SSID, if any."""
    result = _run_script(WIFI_SCRIPT, ["current"])
    ssid = result["output"].strip() if result["ok"] else ""
    return jsonify({"ok": result["ok"], "ssid": ssid or None})


@app.route("/api/wifi/connect", methods=["POST"])
def wifi_connect():
    """Connects to the given SSID with an optional password."""
    data = request.get_json(silent=True) or {}
    ssid = (data.get("ssid") or "").strip()
    password = data.get("password") or ""
    if not ssid:
        return jsonify({"ok": False, "output": "SSID is required"}), 400
    args = ["connect", ssid] + ([password] if password else [])
    result = _run_script(WIFI_SCRIPT, args)
    return jsonify(result)


@app.route("/api/ping", methods=["POST"])
def ping():
    """Pings the given target."""
    data = request.get_json(silent=True) or {}
    target = (data.get("target") or "").strip()
    if not target:
        return jsonify({"ok": False, "output": "Target is required"}), 400
    result = _run_script("ping.sh", [target])
    return jsonify(result)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)

