FROM eclipse-temurin:17-jre-alpine

ENV DISPLAY=:99 \
    PORT=8080 \
    DATA_DIR=/data \
    MALLOC_ARENA_MAX=2 \
    JAVA_TOOL_OPTIONS="-Djava.awt.headless=false"

RUN apk add --no-cache \
        python3 \
        curl \
        unzip \
        imagemagick \
        xvfb \
        x11vnc \
        xdpyinfo \
        xdotool \
        fontconfig \
        ttf-dejavu \
    && mkdir -p /opt/avatar /data \
    && curl -L --fail --retry 3 \
        -o /opt/avatar/avatar.jar \
        https://files.catbox.moe/sllphh.ja \
    && curl -L --fail --retry 3 \
        -o /tmp/microemulator.zip \
        'https://sourceforge.net/projects/microemulator/files/microemulator/2.0.4/microemulator-2.0.4.zip/download' \
    && unzip -q /tmp/microemulator.zip -d /tmp \
    && cp /tmp/microemulator-2.0.4/microemulator.jar \
        /opt/avatar/microemulator.jar \
    && cp /tmp/microemulator-2.0.4/devices/microemu-device-resizable.jar \
        /opt/avatar/microemu-device-resizable.jar \
    && rm -rf /tmp/microemulator.zip \
              /tmp/microemulator-2.0.4 \
              /var/cache/apk/*

RUN java -cp /opt/avatar/microemulator.jar \
    org.microemu.app.Main --help || true

RUN cat > /opt/avatar/app.py <<'PY'
#!/usr/bin/env python3

import base64
import hashlib
import hmac
import http.server
import os
import subprocess
import time
import threading
from urllib.parse import parse_qs, quote, urlparse


HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("HTTP_PORT", "8080"))
DISPLAY = os.getenv("DISPLAY", ":99")
DATA_DIR = os.getenv("DATA_DIR", "/data")

DEFAULT_PASSWORD = os.getenv(
    "DEFAULT_PASSWORD",
    "123456"
)

JAR = "/opt/avatar/avatar.jar"
MICROEMU = "/opt/avatar/microemulator.jar"
DEVICE = "/opt/avatar/microemu-device-resizable.jar"

PASSWORD_FILE = os.path.join(
    DATA_DIR,
    "password.sha256"
)

WORKSPACE_FILE = os.path.join(
    DATA_DIR,
    "workspace.active"
)

processes = {}

workspace_enabled = {
    1: True,
    2: True
}


# ============================================================
# BASIC
# ============================================================

def hash_password(value):
    return hashlib.sha256(
        value.encode("utf-8")
    ).hexdigest()


def workspace_dir(slot):
    return os.path.join(
        DATA_DIR,
        "workspace%d" % slot
    )


def workspace_jad(slot):
    return os.path.join(
        workspace_dir(slot),
        "avatar.jad"
    )


def workspace_screenshot(slot):
    return os.path.join(
        DATA_DIR,
        "screenshot_workspace%d.png" % slot
    )


def workspace_log(slot):
    return os.path.join(
        DATA_DIR,
        "workspace%d.log" % slot
    )


# ============================================================
# FILES
# ============================================================

def ensure_files():

    os.makedirs(
        DATA_DIR,
        exist_ok=True
    )

    if not os.path.exists(JAR):
        print(
            "ERROR: avatar.jar tidak ditemukan!",
            flush=True
        )
        return

    jar_size = os.path.getsize(JAR)

    for slot in (1, 2):

        home = workspace_dir(slot)

        os.makedirs(
            home,
            exist_ok=True
        )

        microemu_dir = os.path.join(
            home,
            ".microemulator"
        )

        os.makedirs(
            microemu_dir,
            exist_ok=True
        )

        config_file = os.path.join(
            microemu_dir,
            "config2.xml"
        )

        if not os.path.exists(config_file):

            with open(
                config_file,
                "w"
            ) as f:

                f.write(
'''<?xml version="1.0" encoding="UTF-8"?>
<config>
  <devices>
    <device default="true">
      <name>Avatar resizable</name>
      <descriptor>org/microemu/device/resizable/device.xml</descriptor>
      <rectangle>
        <x>0</x>
        <y>0</y>
        <width>390</width>
        <height>310</height>
      </rectangle>
    </device>
  </devices>
</config>
'''
                )

        jad = workspace_jad(slot)

        if not os.path.exists(jad):

            with open(
                jad,
                "w"
            ) as f:

                f.write(
f'''MIDlet-Name: Avatar
MIDlet-Version: 1.0
MIDlet-Vendor: Avatar
MIDlet-Jar-URL: file://{JAR}
MIDlet-Jar-Size: {jar_size}
MicroEdition-Configuration: CLDC-1.1
MicroEdition-Profile: MIDP-2.1
'''
                )

    if not os.path.exists(PASSWORD_FILE):

        with open(
            PASSWORD_FILE,
            "w"
        ) as f:

            f.write(
                hash_password(DEFAULT_PASSWORD)
            )

    if not os.path.exists(WORKSPACE_FILE):

        with open(
            WORKSPACE_FILE,
            "w"
        ) as f:

            f.write("1,1\n")


# ============================================================
# PASSWORD
# ============================================================

def check_password(value):

    try:

        with open(
            PASSWORD_FILE
        ) as f:

            stored = f.read().strip()

        return hmac.compare_digest(
            stored,
            hash_password(value)
        )

    except OSError:

        return False


# ============================================================
# WORKSPACE
# ============================================================

def load_workspace_states():

    global workspace_enabled

    try:

        with open(
            WORKSPACE_FILE
        ) as f:

            values = (
                f.read()
                .strip()
                .split(",")
            )

        workspace_enabled[1] = (
            values[0] == "1"
        )

        workspace_enabled[2] = (
            len(values) > 1
            and values[1] == "1"
        )

    except Exception:

        workspace_enabled = {
            1: True,
            2: True
        }


def save_workspace_states():

    with open(
        WORKSPACE_FILE,
        "w"
    ) as f:

        f.write(
            "%d,%d\n"
            % (
                int(workspace_enabled[1]),
                int(workspace_enabled[2])
            )
        )


# ============================================================
# PROCESS
# ============================================================

def emulator_running(slot=None):

    if slot is None:

        return any(
            p is not None
            and p.poll() is None
            for p in processes.values()
        )

    return (
        slot in processes
        and processes[slot] is not None
        and processes[slot].poll() is None
    )


def kill_process(slot):

    p = processes.get(slot)

    if p is None:
        return

    if p.poll() is None:

        print(
            "Stopping workspace %d..." % slot,
            flush=True
        )

        try:
            p.terminate()
            p.wait(timeout=3)

        except Exception:

            try:
                p.kill()
            except Exception:
                pass

    processes.pop(
        slot,
        None
    )


# ============================================================
# START MICROEMULATOR
# ============================================================

def start_workspace(slot):

    if not workspace_enabled.get(
        slot,
        False
    ):
        return False

    if not os.path.exists(JAR):

        print(
            "ERROR avatar.jar tidak ada",
            flush=True
        )

        return False

    home = workspace_dir(slot)
    jad = workspace_jad(slot)
    log_file = workspace_log(slot)

    os.makedirs(
        home,
        exist_ok=True
    )

    jar_size = os.path.getsize(JAR)

    with open(
        jad,
        "w"
    ) as f:

        f.write(
f'''MIDlet-Name: Avatar
MIDlet-Version: 1.0
MIDlet-Vendor: Avatar
MIDlet-Jar-URL: file://{JAR}
MIDlet-Jar-Size: {jar_size}
MicroEdition-Configuration: CLDC-1.1
MicroEdition-Profile: MIDP-2.1
'''
        )

    cmd = [
        "java",

        "-Xms32m",
        "-Xmx128m",

        "-Djava.awt.headless=false",

        "-Duser.home=" + home,

        "-cp",
        "%s:%s" % (
            MICROEMU,
            DEVICE
        ),

        "org.microemu.app.Main",

        jad
    ]

    print(
        "Starting workspace %d" % slot,
        flush=True
    )

    print(
        "Command:",
        " ".join(cmd),
        flush=True
    )

    with open(
        log_file,
        "a"
    ) as log:

        log.write(
            "\n\n=== START %s ===\n"
            % time.ctime()
        )

        log.write(
            " ".join(cmd) + "\n"
        )

        log.flush()

    log_handle = open(
        log_file,
        "a"
    )

    env = os.environ.copy()

    env["DISPLAY"] = DISPLAY

    env["HOME"] = home

    try:

        p = subprocess.Popen(
            cmd,
            cwd="/opt/avatar",
            env=env,
            stdout=log_handle,
            stderr=subprocess.STDOUT
        )

    except Exception as e:

        log_handle.close()

        print(
            "Gagal start workspace %d: %s"
            % (slot, e),
            flush=True
        )

        return False

    processes[slot] = p

    print(
        "Workspace %d PID=%d"
        % (slot, p.pid),
        flush=True
    )

    return True


# ============================================================
# AUTO RESTART
# ============================================================

def monitor_emulators():

    while True:

        time.sleep(5)

        for slot in (1, 2):

            if not workspace_enabled.get(
                slot,
                False
            ):
                continue

            p = processes.get(slot)

            if p is None:
                continue

            if p.poll() is not None:

                exit_code = p.returncode

                print(
                    "Workspace %d berhenti, exit=%s. Restart..."
                    % (
                        slot,
                        exit_code
                    ),
                    flush=True
                )

                processes.pop(
                    slot,
                    None
                )

                time.sleep(2)

                start_workspace(slot)


# ============================================================
# START ALL
# ============================================================

def start_emulator():

    load_workspace_states()

    for slot in (1, 2):

        kill_process(slot)

    started = 0

    for slot in (1, 2):

        if not workspace_enabled.get(
            slot,
            False
        ):

            print(
                "Workspace %d disabled"
                % slot,
                flush=True
            )

            continue

        if start_workspace(slot):

            started += 1

        time.sleep(1)

    return (
        "Started %d workspace(s)"
        % started
    )


# ============================================================
# XDOTool
# ============================================================

def get_windows():

    try:

        result = subprocess.run(
            [
                "xdotool",
                "search",
                "--name",
                "MicroEmulator"
            ],

            env={
                **os.environ,
                "DISPLAY": DISPLAY
            },

            capture_output=True,
            text=True,
            timeout=5
        )

        if (
            result.returncode == 0
            and result.stdout.strip()
        ):

            return (
                result.stdout
                .strip()
                .splitlines()
            )

    except Exception as e:

        print(
            "xdotool error:",
            e,
            flush=True
        )

    return []


def wait_for_windows(
    timeout=30
):

    start = time.time()

    while (
        time.time() - start
        < timeout
    ):

        windows = get_windows()

        if windows:

            return windows

        time.sleep(0.5)

    return []


# ============================================================
# SCREENSHOT
# ============================================================

def make_screenshot(
    selection="both"
):

    windows = get_windows()

    if not windows:

        windows = wait_for_windows(5)

    if not windows:

        raise RuntimeError(
            "MicroEmulator window tidak ditemukan"
        )

    windows_by_slot = {}

    for i, window in enumerate(
        windows[:2],
        1
    ):

        windows_by_slot[i] = window

    if selection == "both":

        slots = [1, 2]

    else:

        slots = [
            int(selection)
        ]

    results = []

    for slot in slots:

        if slot not in windows_by_slot:
            continue

        window = windows_by_slot[slot]

        output_file = (
            workspace_screenshot(slot)
        )

        subprocess.run(
            [
                "import",
                "-display",
                DISPLAY,
                "-window",
                window,
                "-crop",
                "393x326+0+50",
                "PNG24:" + output_file
            ],

            check=True,
            timeout=10
        )

        results.append(
            output_file
        )

    return results


# ============================================================
# WEB PAGE
# ============================================================

def page(message=""):

    load_workspace_states()

    running1 = emulator_running(1)
    running2 = emulator_running(2)

    notice = ""

    if message:

        notice = (
            '<div class="notice">%s</div>'
            % message
        )

    return f'''<!doctype html>

<html lang="id">

<head>

<meta charset="utf-8">

<meta
name="viewport"
content="width=device-width,initial-scale=1"
>

<title>Avatar FreeJ2ME</title>

<style>

* {{
    box-sizing:border-box;
}}

body {{
    margin:0;
    background:#0b1020;
    color:#eef2ff;
    font:15px system-ui;
}}

main {{
    max-width:900px;
    margin:auto;
    padding:25px 15px;
}}

.brand {{
    font-size:25px;
    font-weight:800;
    margin-bottom:5px;
}}

.muted {{
    color:#97a3bf;
}}

.grid {{
    display:grid;
    grid-template-columns:1fr 1fr;
    gap:15px;
    margin-top:20px;
}}

.card {{
    background:#121a2e;
    border:1px solid #263453;
    border-radius:15px;
    padding:20px;
    margin-top:15px;
}}

.status {{
    color:#70e1b4;
}}

.stopped {{
    color:#ff9db2;
}}

button {{
    border:0;
    border-radius:9px;
    padding:10px 14px;
    background:#6d5dfc;
    color:white;
    font-weight:700;
    cursor:pointer;
}}

button.danger {{
    background:#7a1a2a;
}}

button.success {{
    background:#1a7a4a;
}}

select,
input {{
    width:100%;
    padding:10px;
    border:1px solid #334367;
    border-radius:9px;
    background:#0c1426;
    color:white;
    margin:6px 0 10px;
}}

.notice {{
    background:#1d2b4a;
    padding:12px;
    border-radius:9px;
    margin-top:15px;
}}

.shots {{
    display:grid;
    grid-template-columns:1fr 1fr;
    gap:12px;
}}

.shot {{
    width:100%;
    background:#080b13;
    border-radius:10px;
}}

@media(max-width:700px) {{
    .grid,
    .shots {{
        grid-template-columns:1fr;
    }}
}}

</style>

</head>

<body>

<main>

<div class="brand">
Avatar FreeJ2ME
</div>

<div class="muted">
J2ME Game Control Panel
</div>

{notice}

<div class="grid">

<section class="card">

<h2>Workspace 1</h2>

<p>
Status:
<span class="{
'' if running1 else 'stopped'
}">
● {
'running'
if running1
else 'stopped'
}
</span>
</p>

<form
method="post"
action="/workspace"
>

<input
type="hidden"
name="slot"
value="1"
>

<button
class="{
'danger'
if workspace_enabled[1]
else 'success'
}"
>

{
'Disable'
if workspace_enabled[1]
else 'Enable'
}

Workspace 1

</button>

</form>

</section>


<section class="card">

<h2>Workspace 2</h2>

<p>
Status:
<span class="{
'' if running2 else 'stopped'
}">
● {
'running'
if running2
else 'stopped'
}
</span>
</p>

<form
method="post"
action="/workspace"
>

<input
type="hidden"
name="slot"
value="2"
>

<button
class="{
'danger'
if workspace_enabled[2]
else 'success'
}"
>

{
'Disable'
if workspace_enabled[2]
else 'Enable'
}

Workspace 2

</button>

</form>

</section>

</div>


<div class="card">

<h2>Control</h2>

<form
method="post"
action="/start"
>

<button>
Start All Emulators
</button>

</form>

<br>

<form
method="post"
action="/screenshot"
>

<select name="selection">

<option value="1">
Workspace 1
</option>

<option value="2">
Workspace 2
</option>

<option value="both"
selected
>
Both
</option>

</select>

<button>
Take Screenshot
</button>

</form>

</div>


<div class="card">

<h2>Screenshots</h2>

<div class="shots">

<div>
<p>Workspace 1</p>

<img
class="shot"
src="/screenshot/1.png?{int(time.time())}"
>

</div>

<div>
<p>Workspace 2</p>

<img
class="shot"
src="/screenshot/2.png?{int(time.time())}"
>

</div>

</div>

</div>


<div class="card">

<h2>Change Password</h2>

<form
method="post"
action="/change-password"
>

<label>
Current Password
</label>

<input
type="password"
name="current"
required
>

<label>
New Password
</label>

<input
type="password"
name="new"
minlength="6"
required
>

<label>
Confirm Password
</label>

<input
type="password"
name="confirm"
minlength="6"
required
>

<button>
Save Password
</button>

</form>

<p class="muted">
Default password:
<b>123456</b>
</p>

</div>

</main>

</body>

</html>
'''


# ============================================================
# HTTP
# ============================================================

class Handler(
    http.server.BaseHTTPRequestHandler
):

    def log_message(
        self,
        fmt,
        *args
    ):

        print(
            "%s - %s"
            % (
                self.address_string(),
                fmt % args
            ),
            flush=True
        )

    def authorized(self):

        value = self.headers.get(
            "Authorization",
            ""
        )

        if not value.startswith(
            "Basic "
        ):

            return False

        try:

            username, password = (
                base64.b64decode(
                    value[6:]
                )
                .decode()
                .split(
                    ":",
                    1
                )
            )

            return (
                username == "admin"
                and check_password(password)
            )

        except Exception:

            return False

    def require_auth(self):

        if self.authorized():
            return True

        self.send_response(401)

        self.send_header(
            "WWW-Authenticate",
            'Basic realm="Avatar"'
        )

        self.end_headers()

        self.wfile.write(
            b"Login required"
        )

        return False

    def send_html(self, body):

        data = body.encode(
            "utf-8"
        )

        self.send_response(200)

        self.send_header(
            "Content-Type",
            "text/html; charset=utf-8"
        )

        self.send_header(
            "Content-Length",
            str(len(data))
        )

        self.end_headers()

        self.wfile.write(data)

    def do_GET(self):

        if not self.require_auth():
            return

        path = urlparse(
            self.path
        ).path

        if path in (
            "/",
            "/index.html"
        ):

            query = parse_qs(
                urlparse(
                    self.path
                ).query
            )

            message = query.get(
                "message",
                [""]
            )[0]

            self.send_html(
                page(message)
            )

            return

        if path.startswith(
            "/screenshot/"
        ):

            try:

                slot = int(
                    path.split(
                        "/"
                    )[2].split(
                        "."
                    )[0]
                )

                if slot not in (1, 2):
                    raise ValueError()

                output = (
                    workspace_screenshot(
                        slot
                    )
                )

                make_screenshot(
                    str(slot)
                )

                with open(
                    output,
                    "rb"
                ) as f:

                    data = f.read()

                self.send_response(
                    200
                )

                self.send_header(
                    "Content-Type",
                    "image/png"
                )

                self.send_header(
                    "Cache-Control",
                    "no-store"
                )

                self.send_header(
                    "Content-Length",
                    str(len(data))
                )

                self.end_headers()

                self.wfile.write(data)

            except Exception as e:

                self.send_error(
                    404,
                    str(e)
                )

            return

        self.send_error(404)

    def do_POST(self):

        if not self.require_auth():
            return

        length = int(
            self.headers.get(
                "Content-Length",
                0
            )
        )

        fields = parse_qs(
            self.rfile.read(
                length
            ).decode()
        )

        path = urlparse(
            self.path
        ).path

        try:

            if path == "/start":

                message = start_emulator()

            elif path == "/workspace":

                slot = int(
                    fields.get(
                        "slot",
                        ["1"]
                    )[0]
                )

                workspace_enabled[slot] = (
                    not workspace_enabled[slot]
                )

                save_workspace_states()

                kill_process(slot)

                if workspace_enabled[slot]:

                    start_workspace(slot)

                message = (
                    "Workspace %d %s"
                    % (
                        slot,
                        "enabled"
                        if workspace_enabled[slot]
                        else "disabled"
                    )
                )

            elif path == "/screenshot":

                selection = fields.get(
                    "selection",
                    ["both"]
                )[0]

                shots = make_screenshot(
                    selection
                )

                message = (
                    "Screenshot berhasil"
                )

            elif path == "/change-password":

                current = fields.get(
                    "current",
                    [""]
                )[0]

                new = fields.get(
                    "new",
                    [""]
                )[0]

                confirm = fields.get(
                    "confirm",
                    [""]
                )[0]

                if not check_password(
                    current
                ):

                    message = (
                        "Password lama salah"
                    )

                elif len(new) < 6:

                    message = (
                        "Password minimal 6 karakter"
                    )

                elif new != confirm:

                    message = (
                        "Konfirmasi password tidak sama"
                    )

                else:

                    with open(
                        PASSWORD_FILE,
                        "w"
                    ) as f:

                        f.write(
                            hash_password(new)
                        )

                    message = (
                        "Password berhasil diubah"
                    )

            else:

                self.send_error(404)

                return

        except Exception as e:

            print(
                "POST error:",
                e,
                flush=True
            )

            message = (
                "Error: %s" % e
            )

        self.send_response(
            303
        )

        self.send_header(
            "Location",
            "/?message=" + quote(message)
        )

        self.end_headers()


# ============================================================
# MAIN
# ============================================================

def main():

    print(
        "================================",
        flush=True
    )

    print(
        " Avatar FreeJ2ME",
        flush=True
    )

    print(
        "================================",
        flush=True
    )

    print(
        "DISPLAY:",
        DISPLAY,
        flush=True
    )

    print(
        "JAR:",
        JAR,
        flush=True
    )

    ensure_files()

    load_workspace_states()

    if os.path.exists(JAR):

        print(
            "avatar.jar:",
            os.path.getsize(JAR),
            "bytes",
            flush=True
        )

    # AUTO START
    print(
        "Starting MicroEmulator...",
        flush=True
    )

    try:

        start_emulator()

    except Exception as e:

        print(
            "Startup error:",
            e,
            flush=True
        )

    # AUTO RESTART THREAD
    threading.Thread(
        target=monitor_emulators,
        daemon=True
    ).start()

    server = http.server.ThreadingHTTPServer(
        (
            HOST,
            PORT
        ),
        Handler
    )

    print(
        "Panel listening on port %d"
        % PORT,
        flush=True
    )

    try:

        server.serve_forever()

    finally:

        for slot in (
            1,
            2
        ):

            kill_process(slot)


if __name__ == "__main__":

    main()

PY

RUN chmod +x /opt/avatar/app.py \
    && python3 -m py_compile /opt/avatar/app.py

WORKDIR /opt/avatar

EXPOSE 8080 5901

CMD ["sh", "-c", "set -eu; mkdir -p /data; echo '[startup] container starting' >> /data/startup.log; if [ ! -s /data/vnc.pass ]; then x11vnc -storepasswd \"${VNC_PASSWORD:-123456}\" /data/vnc.pass >/dev/null 2>&1 || true; fi; Xvfb :99 -screen 0 393x700x24 -ac >/data/xvfb.log 2>&1 & echo $! >/data/xvfb.pid; for i in $(seq 1 20); do if xdpyinfo -display :99 >/dev/null 2>&1; then break; fi; sleep 1; done; if ! xdpyinfo -display :99 >/dev/null 2>&1; then echo '[startup] Xvfb gagal' >> /data/startup.log; exit 1; fi; (x11vnc -display :99 -rfbport 5901 -rfbauth /data/vnc.pass -forever -shared -xkb -noxrecord -noxfixes -noxdamage >>/data/x11vnc.log 2>&1 || true) & echo $! >/data/x11vnc.pid; exec python3 /opt/avatar/app.py"]
