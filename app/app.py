import os
import subprocess
import psutil
import json
import shutil
import threading
import time
import select
from flask import Flask, render_template, jsonify, request, abort, send_from_directory, Response, stream_with_context

app = Flask(__name__)

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')
STORAGE_DIR = os.path.realpath(os.path.join(os.path.dirname(__file__), '..', 'Storage'))
os.makedirs(STORAGE_DIR, exist_ok=True)

# Map of allowed system commands — add/remove as needed
SYSTEM_ACTIONS = {
    "storage":       {"label": "Storage (20GB)",     "icon": "💾", "confirm": True,  "script": "storage.sh"},
    "runcode":       {"label": "Run Code",           "icon": "💻", "confirm": False, "script": "none"},
    "terminal":      {"label": "Terminal",           "icon": "🖥️", "confirm": False, "script": "none"},
    "blink":         {"label": "Blink LED",          "icon": "💡", "confirm": False, "script": "blink.sh"},
    "reboot":        {"label": "Reboot",             "icon": "🔄", "confirm": True,  "script": "reboot.sh"},
    "shutdown":      {"label": "Shutdown",           "icon": "⏻",  "confirm": True,  "script": "shutdown.sh"},
    "update":        {"label": "Update system",      "icon": "⬆️", "confirm": True,  "script": "update.sh"},
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
    return render_template("index.html", system_actions=SYSTEM_ACTIONS)


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


@app.route("/api/system/<action_id>", methods=["POST"])
def run_action(action_id):
    if action_id not in SYSTEM_ACTIONS:
        abort(404)
    script = SYSTEM_ACTIONS[action_id]["script"]
    
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


@app.route("/api/ia/status")
def ia_status():
    """Returns current 9Router state via pm2."""
    try:
        my_env = os.environ.copy()
        my_env["PATH"] = my_env.get("PATH", "") + ":/usr/bin:/usr/local/bin"
        proc = subprocess.run(["pm2", "jlist"], capture_output=True, text=True, env=my_env)
        data = json.loads(proc.stdout)
        active = False
        for p in data:
            if p.get("name") == "9router" and p.get("pm2_env", {}).get("status") == "online":
                active = True
                break
        return jsonify({"active": active})
    except Exception as e:
        return jsonify({"active": False, "error": str(e)})


@app.route("/api/ia/toggle", methods=["POST"])
def ia_toggle():
    """Toggle 9Router on/off via pm2."""
    try:
        my_env = os.environ.copy()
        my_env["PATH"] = my_env.get("PATH", "") + ":/usr/bin:/usr/local/bin"
        
        # Define a senha do 9Router
        my_env["INITIAL_PASSWORD"] = "passworld123"

        proc = subprocess.run(["pm2", "jlist"], capture_output=True, text=True, env=my_env)
        data = json.loads(proc.stdout)
        active = False
        for p in data:
            if p.get("name") == "9router" and p.get("pm2_env", {}).get("status") == "online":
                active = True
                break
        
        if active:
            res = subprocess.run(["pm2", "stop", "9router"], capture_output=True, text=True, env=my_env)
        else:
            # Use full binary path + headless flags so PM2 can run without a TTY.
            # --no-browser: skip opening a browser window
            # --skip-update: skip the update check for faster startup
            res = subprocess.run(
                ["pm2", "start", "/usr/bin/9router",
                 "--name", "9router",
                 "--", "--no-browser", "--skip-update"],
                capture_output=True, text=True, env=my_env
            )
        subprocess.run(["pm2", "save"], capture_output=True, text=True, env=my_env)
        
        new_active = not active if res.returncode == 0 else active
        return jsonify({"ok": res.returncode == 0, "output": res.stdout + res.stderr, "active": new_active})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})


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


def get_dir_size(path):
    total = 0
    with os.scandir(path) as it:
        for entry in it:
            if entry.is_file():
                total += entry.stat().st_size
            elif entry.is_dir():
                total += get_dir_size(entry.path)
    return total

@app.route("/api/storage/files")
def storage_files():
    try:
        req_path = request.args.get('path', '').strip('/')
        target_dir = os.path.realpath(os.path.join(STORAGE_DIR, req_path))
        
        if not target_dir.startswith(os.path.realpath(STORAGE_DIR)):
            return jsonify({"ok": False, "output": "Invalid path"}), 400
        if not os.path.isdir(target_dir):
            return jsonify({"ok": False, "output": "Directory not found"}), 404

        files = []
        for f in os.listdir(target_dir):
            path = os.path.join(target_dir, f)
            if f.startswith('.'): continue
            is_dir = os.path.isdir(path)
            size = os.path.getsize(path) if not is_dir else 0
            files.append({"name": f, "size": size, "is_dir": is_dir})
            
        # Sort folders first, then files
        files.sort(key=lambda x: (not x["is_dir"], x["name"].lower()))
        
        used_bytes = get_dir_size(STORAGE_DIR)
        
        return jsonify({"ok": True, "files": files, "used_bytes": used_bytes})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})

@app.route("/api/storage/mkdir", methods=["POST"])
def storage_mkdir():
    try:
        data = request.get_json(silent=True) or {}
        req_path = data.get('path', '').strip('/')
        folder_name = data.get('name', '').strip()
        
        if not folder_name or '/' in folder_name or '\\' in folder_name:
            return jsonify({"ok": False, "output": "Invalid folder name"}), 400
            
        target_dir = os.path.realpath(os.path.join(STORAGE_DIR, req_path, folder_name))
        if not target_dir.startswith(os.path.realpath(STORAGE_DIR)):
            return jsonify({"ok": False, "output": "Invalid path"}), 400
            
        os.makedirs(target_dir, exist_ok=True)
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})


@app.route("/api/storage/upload", methods=["POST"])
def storage_upload():
    if 'file' not in request.files:
        return jsonify({"ok": False, "output": "No file part"}), 400
    file = request.files['file']
    req_path = request.form.get('path', '').strip('/')
    
    if file.filename == '':
        return jsonify({"ok": False, "output": "No selected file"}), 400
    try:
        filename = os.path.basename(file.filename)
        if not filename:
            return jsonify({"ok": False, "output": "Invalid filename"}), 400
            
        target_dir = os.path.realpath(os.path.join(STORAGE_DIR, req_path))
        if not target_dir.startswith(os.path.realpath(STORAGE_DIR)):
            return jsonify({"ok": False, "output": "Invalid path"}), 400
            
        file.save(os.path.join(target_dir, filename))
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})


@app.route("/api/storage/download/<path:filename>")
def storage_download(filename):
    return send_from_directory(STORAGE_DIR, filename, as_attachment=True)


@app.route("/api/storage/delete/<path:filename>", methods=["POST"])
def storage_delete(filename):
    try:
        path = os.path.realpath(os.path.join(STORAGE_DIR, filename))
        if not path.startswith(os.path.realpath(STORAGE_DIR) + os.sep) and path != os.path.realpath(STORAGE_DIR):
            return jsonify({"ok": False, "output": "Invalid path"}), 400
        if os.path.exists(path):
            if os.path.isdir(path):
                shutil.rmtree(path)
            else:
                os.remove(path)
            return jsonify({"ok": True})
        return jsonify({"ok": False, "output": "File not found"}), 404
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})


@app.route("/api/runcode/read", methods=["POST"])
def runcode_read():
    try:
        data = request.get_json(silent=True) or {}
        req_path = data.get('path', '').strip('/')
        target_path = os.path.realpath(os.path.join(STORAGE_DIR, req_path))
        if not target_path.startswith(os.path.realpath(STORAGE_DIR)):
            return jsonify({"ok": False, "output": "Invalid path"}), 400
        if not os.path.isfile(target_path):
            return jsonify({"ok": False, "output": "File not found"}), 404
            
        with open(target_path, 'r', encoding='utf-8') as f:
            content = f.read()
        return jsonify({"ok": True, "content": content})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})

@app.route("/api/runcode/save", methods=["POST"])
def runcode_save():
    try:
        data = request.get_json(silent=True) or {}
        req_path = data.get('path', '').strip('/')
        content = data.get('content', '')
        target_path = os.path.realpath(os.path.join(STORAGE_DIR, req_path))
        if not target_path.startswith(os.path.realpath(STORAGE_DIR)):
            return jsonify({"ok": False, "output": "Invalid path"}), 400
            
        with open(target_path, 'w', encoding='utf-8') as f:
            f.write(content)
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})

@app.route("/api/runcode/execute", methods=["POST"])
def runcode_execute():
    try:
        data = request.get_json(silent=True) or {}
        req_path = data.get('path', '').strip('/')
        target_path = os.path.realpath(os.path.join(STORAGE_DIR, req_path))
        if not target_path.startswith(os.path.realpath(STORAGE_DIR)):
            return jsonify({"ok": False, "output": "Invalid path"}), 400
        if not os.path.isfile(target_path):
            return jsonify({"ok": False, "output": "File not found"}), 404
            
        proc = subprocess.run(['python3', target_path], capture_output=True, text=True, timeout=10, cwd=os.path.dirname(target_path))
        output = proc.stdout + proc.stderr
        if proc.returncode != 0 and not output:
            output = f"Exited with code {proc.returncode}"
        return jsonify({"ok": True, "output": output})
    except subprocess.TimeoutExpired:
        return jsonify({"ok": False, "output": "Execution timed out after 10 seconds."})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})


@app.route("/api/terminal/run", methods=["POST"])
def terminal_run():
    try:
        data = request.get_json(silent=True) or {}
        cmd = data.get('cmd', '').strip()
        cwd = data.get('cwd', '/opt/PiDongle')

        if not cmd:
            return jsonify({"ok": True, "output": "", "cwd": cwd})

        if cmd.startswith('cd ') or cmd == 'cd':
            parts = cmd.split(' ', 1)
            target = parts[1].strip() if len(parts) > 1 else os.path.expanduser('~')
            
            new_cwd = os.path.abspath(os.path.join(cwd, target))
            if os.path.isdir(new_cwd):
                return jsonify({"ok": True, "output": "", "cwd": new_cwd})
            else:
                return jsonify({"ok": False, "output": f"bash: cd: {target}: No such file or directory\n", "cwd": cwd})

        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
        output = proc.stdout + proc.stderr
        
        return jsonify({"ok": True, "output": output, "cwd": cwd})

    except Exception as e:
        return jsonify({"ok": False, "output": str(e) + "\n", "cwd": cwd})

# ---------------------------------------------------------------------------
# Claude Code PTY terminal
# ---------------------------------------------------------------------------
_claude_proc = None
_claude_lock = threading.Lock()
_claude_buf = []
_claude_buf_lock = threading.Lock()


def _claude_reader():
    """Background thread: drain PTY output into _claude_buf."""
    global _claude_proc
    while True:
        with _claude_lock:
            proc = _claude_proc
        if proc is None or not proc.isalive():
            break
        try:
            r, _, _ = select.select([proc.fd], [], [], 0.1)
            if r:
                data = os.read(proc.fd, 4096)
                if data:
                    with _claude_buf_lock:
                        _claude_buf.append(data.decode('utf-8', errors='replace'))
        except Exception:
            break
    with _claude_buf_lock:
        _claude_buf.append(None)  # EOF marker for SSE generator


@app.route("/api/claude/status")
def claude_status_route():
    """Returns whether Claude PTY process is alive."""
    with _claude_lock:
        alive = _claude_proc is not None and _claude_proc.isalive()
    return jsonify({"active": alive})


@app.route("/api/claude/start", methods=["POST"])
def claude_start():
    """Spawn a Claude Code PTY process inside Storage dir."""
    global _claude_proc, _claude_buf
    with _claude_lock:
        if _claude_proc is not None and _claude_proc.isalive():
            return jsonify({"ok": True, "msg": "already running"})
        try:
            import ptyprocess # type: ignore
            with _claude_buf_lock:
                _claude_buf.clear()
            claude_bin = shutil.which('claude') or '/usr/local/bin/claude'
            _claude_proc = ptyprocess.PtyProcess.spawn(
                [claude_bin],
                cwd=STORAGE_DIR,
                dimensions=(40, 200)
            )
            threading.Thread(target=_claude_reader, daemon=True).start()
            return jsonify({"ok": True})
        except Exception as e:
            return jsonify({"ok": False, "output": str(e)})


@app.route("/api/claude/stop", methods=["POST"])
def claude_stop():
    """Terminate the Claude PTY process."""
    global _claude_proc
    with _claude_lock:
        if _claude_proc is not None:
            try:
                _claude_proc.terminate(force=True)
            except Exception:
                pass
            _claude_proc = None
    return jsonify({"ok": True})


@app.route("/api/claude/input", methods=["POST"])
def claude_input_route():
    """Write user text into the Claude PTY stdin."""
    data = request.get_json(silent=True) or {}
    text = data.get("text", "")
    with _claude_lock:
        proc = _claude_proc
    if proc is None or not proc.isalive():
        return jsonify({"ok": False, "output": "Claude is not running"})
    try:
        proc.write(text.encode('utf-8'))
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "output": str(e)})


@app.route("/api/claude/output")
def claude_output_route():
    """SSE stream: push PTY output chunks to the browser."""
    def generate():
        idx = 0
        while True:
            with _claude_buf_lock:
                new_chunks = _claude_buf[idx:]
            if new_chunks:
                for chunk in new_chunks:
                    if chunk is None:  # EOF
                        yield f"data: {json.dumps({'__done__': True})}\n\n"
                        return
                    yield f"data: {json.dumps(chunk)}\n\n"
                idx += len(new_chunks)
            else:
                yield ": ping\n\n"  # keep-alive
            time.sleep(0.05)

    return Response(
        stream_with_context(generate()),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no',
            'Connection': 'keep-alive',
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)

