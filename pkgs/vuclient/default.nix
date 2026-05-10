{
  lib,
  python3Packages,
  writeText,
  makeWrapper,
}: let
  script = writeText "vuclient.py" ''
    import glob
    import os
    import shutil
    import subprocess
    import sys
    import time

    import psutil
    import requests

    VUSERVER_URL = os.environ.get("VUSERVER_URL", "http://localhost:5340")
    INTERVAL = int(os.environ.get("VUCLIENT_INTERVAL", "1"))

    dial_map = {}
    for env_var, label in [
        ("CPUDIAL", "cpu"),
        ("GPUDIAL", "gpu"),
        ("MEMDIAL", "mem"),
        ("DSKDIAL", "disk"),
    ]:
        uid = os.environ.get(env_var, "")
        if uid:
            dial_map[label] = uid

    api_key = os.environ.get("VU_API_KEY", "")
    KEY_FILE = os.environ.get("VU_KEY_FILE", "")

    def get_key():
        if api_key:
            return api_key
        if KEY_FILE:
            try:
                with open(KEY_FILE) as f:
                    key = f.read().strip()
                    if key:
                        return key
            except Exception:
                pass
        return ""

    def set_dial_value(uid, value):
        url = f"{VUSERVER_URL}/api/v0/dial/{uid}/set"
        key = get_key()
        params = {"value": int(value)}
        if key:
            params["key"] = key
        try:
            requests.get(url, params=params, timeout=5)
        except Exception:
            pass

    def set_backlight(uid, red, green, blue):
        url = f"{VUSERVER_URL}/api/v0/dial/{uid}/backlight"
        key = get_key()
        params = {"red": str(red), "green": str(green), "blue": str(blue)}
        if key:
            params["key"] = key
        try:
            requests.get(url, params=params, timeout=5)
        except Exception:
            pass

    def apply_threshold(uid, value, thresholds):
        if value >= thresholds["critical"]:
            set_backlight(uid, 100, 0, 0)
        elif value >= thresholds["warning"]:
            set_backlight(uid, 100, 100, 0)
        else:
            set_backlight(uid, 0, 100, 0)

    def display_is_asleep():
        if sys.platform == "darwin":
            import ctypes

            try:
                cg = ctypes.CDLL(
                    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
                )
                cg.CGDisplayIsAsleep.restype = ctypes.c_bool
                cg.CGDisplayIsAsleep.argtypes = [ctypes.c_int]
                return cg.CGDisplayIsAsleep(cg.CGMainDisplayID())
            except Exception:
                pass
        else:
            try:
                for card in sorted(glob.glob("/sys/class/drm/card*-*/dpms")):
                    with open(card) as f:
                        if f.read().strip() == "Off":
                            return True
            except Exception:
                pass
        return False

    def all_backlights_off():
        for uid in dial_map.values():
            set_backlight(uid, 0, 0, 0)

    def get_cpu():
        return psutil.cpu_percent(interval=0)

    def get_memory():
        if sys.platform == "darwin":
            try:
                output = subprocess.run(
                    ["memory_pressure"],
                    capture_output=True, text=True, timeout=5,
                )
                for line in output.stdout.splitlines():
                    if "free percentage" in line:
                        free_pct = int("".join(c for c in line if c.isdigit()))
                        return max(0, 100 - free_pct)
            except Exception:
                pass
        return psutil.virtual_memory().percent

    def get_memory_level():
        if sys.platform == "darwin":
            try:
                result = subprocess.run(
                    ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                    capture_output=True, text=True, timeout=5,
                )
                return int(result.stdout.strip())
            except Exception:
                return 1
        mem_pct = get_memory()
        if mem_pct >= 95:
            return 4
        elif mem_pct >= 80:
            return 2
        else:
            return 1

    def get_disk():
        d = shutil.disk_usage("/")
        return (d.used / d.total) * 100

    def get_gpu():
        if sys.platform == "darwin":
            try:
                result = subprocess.run(
                    ["ioreg", "-r", "-c", "AGXAccelerator", "-w", "0", "-l"],
                    capture_output=True, text=True, timeout=5,
                )
                for line in result.stdout.splitlines():
                    if "Device Utilization %" in line:
                        idx = line.index('Device Utilization %"=') + len('Device Utilization %"=')
                        digits = ""
                        for c in line[idx:]:
                            if c.isdigit():
                                digits += c
                            else:
                                break
                        if digits:
                            return int(digits)
            except Exception:
                pass
        else:
            for card in sorted(glob.glob("/sys/class/drm/card*/device/gpu_busy_percent")):
                try:
                    with open(card) as f:
                        val = f.read().strip()
                        if val:
                            return int(val)
                except Exception:
                    pass
            try:
                result = subprocess.run(
                    ["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
                    capture_output=True, text=True, timeout=5,
                )
                val = result.stdout.strip()
                if val:
                    return int(val)
            except Exception:
                pass
        return 0

    thresholds = {
        "cpu": {"warning": 50, "critical": 80},
        "gpu": {"warning": 30, "critical": 75},
        "disk": {"warning": 75, "critical": 90},
    }

    time.sleep(3)
    for uid in dial_map.values():
        set_dial_value(uid, 0)
        try:
            key = get_key()
            if key:
                requests.get(
                    f"{VUSERVER_URL}/api/v0/dial/{uid}/easing/dial",
                    params={"key": key, "period": "100", "step": "1"},
                    timeout=5,
                )
                requests.get(
                    f"{VUSERVER_URL}/api/v0/dial/{uid}/easing/backlight",
                    params={"key": key, "period": "100", "step": "1"},
                    timeout=5,
                )
        except Exception:
            pass

    display_was_asleep = False

    while True:
        display_sleeping = display_is_asleep()
        if display_sleeping and not display_was_asleep:
            all_backlights_off()
        display_was_asleep = display_sleeping
        if display_sleeping:
            time.sleep(1)
            continue

        if "cpu" in dial_map:
            val = get_cpu()
            set_dial_value(dial_map["cpu"], val)
            apply_threshold(dial_map["cpu"], val, thresholds["cpu"])
        if "gpu" in dial_map:
            val = get_gpu()
            set_dial_value(dial_map["gpu"], val)
            apply_threshold(dial_map["gpu"], val, thresholds["gpu"])
        if "mem" in dial_map:
            val = get_memory()
            set_dial_value(dial_map["mem"], val)
            level = get_memory_level()
            if level == 4:
                set_backlight(dial_map["mem"], 100, 0, 0)
            elif level == 2:
                set_backlight(dial_map["mem"], 100, 100, 0)
            else:
                set_backlight(dial_map["mem"], 0, 100, 0)
        if "disk" in dial_map:
            val = get_disk()
            set_dial_value(dial_map["disk"], val)
            apply_threshold(dial_map["disk"], val, thresholds["disk"])
        time.sleep(INTERVAL)
  '';
in
  python3Packages.buildPythonApplication {
    pname = "vuclient";
    version = "1.1.0";

    propagatedBuildInputs = with python3Packages; [
      psutil
      requests
    ];

    format = "other";

    nativeBuildInputs = [makeWrapper];

    dontUnpack = true;

    installPhase = ''
      makeWrapper \
        ${python3Packages.python.interpreter} \
        $out/bin/vuclient \
        --add-flags "${script}" \
        --set PYTHONPATH "$PYTHONPATH" \
    '';

    doCheck = false;

    meta = with lib; {
      description = "VU dials system monitor (cross-platform)";
      homepage = "https://github.com/bonds/vuclient";
      license = licenses.mit;
      platforms = platforms.unix;
    };
  }
