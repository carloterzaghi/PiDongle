import os
import subprocess
import psutil
import json
from flask import Flask, render_template, jsonify, request, abort

app = Flask(__name__)

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'scripts')

# Mapa de ações permitidas — adicione/remova conforme precisar
ACTIONS = {
    "reboot":        {"label": "Reiniciar",          "icon": "🔄", "confirm": True,  "script": "reboot.sh"},
    "shutdown":      {"label": "Desligar",            "icon": "⏻",  "confirm": True,  "script": "shutdown.sh"},
    "update":        {"label": "Atualizar sistema",   "icon": "⬆️", "confirm": True,  "script": "update.sh"},
    "temp":          {"label": "Temperatura CPU",     "icon": "🌡️", "confirm": False, "script": "temp.sh"},
    "blink":         {"label": "Piscar LED",          "icon": "💡", "confirm": False, "script": "blink.sh"},
    "custom":        {"label": "Meu script",          "icon": "⚙️", "confirm": False, "script": "custom.sh"},
}


def _run_script(script_name: str) -> dict:
    path = os.path.realpath(os.path.join(SCRIPTS_DIR, script_name))
    # Garante que o script está dentro de SCRIPTS_DIR (path traversal)
    if not path.startswith(os.path.realpath(SCRIPTS_DIR) + os.sep):
        return {"ok": False, "output": "Script não permitido."}
    if not os.path.isfile(path):
        return {"ok": False, "output": f"Script não encontrado: {script_name}"}
    try:
        result = subprocess.run(
            ["bash", path],
            capture_output=True, text=True, timeout=30
        )
        output = (result.stdout + result.stderr).strip()
        return {"ok": result.returncode == 0, "output": output or "(sem saída)"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": "Timeout: script demorou mais de 30s"}
    except Exception as e:
        return {"ok": False, "output": str(e)}


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
    result = _run_script(script)
    return jsonify(result)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
