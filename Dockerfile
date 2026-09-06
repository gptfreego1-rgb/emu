FROM eclipse-temurin:17-jre-jammy

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    PORT=8080 \
    DATA_DIR=/data \
    MALLOC_ARENA_MAX=2 \
    JAVA_TOOL_OPTIONS="-Djava.awt.headless=false"

# =========================================================
# PACKAGES
# =========================================================

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        curl \
        unzip \
        imagemagick \
        xvfb \
        x11vnc \
        x11-utils \
        xdotool \
        fontconfig \
        fonts-dejavu \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxtst6 \
        libxi6 \
        libxrandr2 \
        libxfixes3 \
        libxcursor1 \
        libfreetype6 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/avatar /data

# =========================================================
# AVATAR
# =========================================================

RUN curl -L --fail --retry 3 \
    -o /opt/avatar/avatar.jar \
    https://files.catbox.moe/sllphh.ja

# =========================================================
# MICROEMULATOR 2.0.4
# =========================================================

RUN curl -L --fail --retry 3 \
    -o /tmp/microemulator.zip \
    'https://sourceforge.net/projects/microemulator/files/microemulator/2.0.4/microemulator-2.0.4.zip/download' \
    && unzip -q /tmp/microemulator.zip -d /tmp \
    && cp /tmp/microemulator-2.0.4/microemulator.jar \
        /opt/avatar/microemulator.jar \
    && cp /tmp/microemulator-2.0.4/devices/microemu-device-resizable.jar \
        /opt/avatar/microemu-device-resizable.jar \
    && rm -rf \
        /tmp/microemulator.zip \
        /tmp/microemulator-2.0.4

# =========================================================
# APP.PY
# =========================================================

RUN cat > /opt/avatar/app.py <<'PY'
#!/usr/bin/env python3

import base64
import hashlib
import hmac
import http.server
import os
import subprocess
import time
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

SCREENSHOT = os.path.join(
    DATA_DIR,
    "microemulator.png"
)

SIZE_FILE = os.path.join(
    DATA_DIR,
    "screen.size"
)

workspace_processes = []


# =========================================================
# WORKSPACE PATH
# =========================================================

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


def workspace_config(slot):
    return os.path.join(
        workspace_dir(slot),
        ".microemulator",
        "config2.xml"
    )


# =========================================================
# PASSWORD
# =========================================================

def hash_password(value):
    return hashlib.sha256(
        value.encode("utf-8")
    ).hexdigest()


def check_password(value):
    try:
        with open(PASSWORD_FILE) as f:
            stored = f.read().strip()

        return hmac.compare_digest(
            stored,
            hash_password(value)
        )

    except OSError:
        return False


# =========================================================
# INITIAL FILES
# =========================================================

def ensure_files():

    os.makedirs(
        DATA_DIR,
        exist_ok=True
    )

    # Screen size
    if not os.path.exists(SIZE_FILE):
        with open(SIZE_FILE, "w") as f:
            f.write("390 310\n")

    # Workspace states
    if not os.path.exists(WORKSPACE_FILE):
        with open(WORKSPACE_FILE, "w") as f:
            f.write("1,1\n")

    # Password
    if not os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, "w") as f:
            f.write(
                hash_password(DEFAULT_PASSWORD)
            )

    # Separate workspace directories
    for slot in (1, 2):

        ws = workspace_dir(slot)

        config_dir = os.path.join(
            ws,
            ".microemulator"
        )

        os.makedirs(
            config_dir,
            exist_ok=True
        )

        jad = workspace_jad(slot)

        if not os.path.exists(jad):

            with open(jad, "w") as f:

                f.write(
                    "MIDlet-Jar-URL: "
                    "file:///opt/avatar/avatar.jar\n"
                )

                f.write(
                    "MIDlet-Jar-Size: %d\n"
                    % os.path.getsize(JAR)
                )

        config = workspace_config(slot)

        if not os.path.exists(config):

            with open(config, "w") as f:

                f.write(
                    "<config>"
                    "<devices>"
                    "<device default=\"true\">"
                    "<name>Avatar resizable</name>"
                    "<descriptor>"
                    "org/microemu/device/resizable/device.xml"
                    "</descriptor>"
                    "<rectangle>"
                    "<x>0</x>"
                    "<y>0</y>"
                    "<width>390</width>"
                    "<height>310</height>"
                    "</rectangle>"
                    "</device>"
                    "</devices>"
                    "</config>\n"
                )


# =========================================================
# WORKSPACE STATE
# =========================================================

def workspace_states():

    try:

        with open(WORKSPACE_FILE) as f:
            values = f.read().strip().split(",")

        return [
            values[0] == "1",
            len(values) > 1 and values[1] == "1"
        ]

    except OSError:

        return [True, True]


# =========================================================
# PROCESS STATE
# =========================================================

def emulator_running():

    return any(
        p is not None and p.poll() is None
        for p in workspace_processes
    )


# =========================================================
# START MICROEMULATOR
# =========================================================

def start_emulator():

    global workspace_processes

    if emulator_running():

        return "Workspace aktif sudah berjalan"

    ensure_files()

    states = workspace_states()

    workspace_processes = []

    for slot in (1, 2):

        if not states[slot - 1]:

            workspace_processes.append(None)
            continue

        ws = workspace_dir(slot)
        jad = workspace_jad(slot)

        log_path = os.path.join(
            DATA_DIR,
            "workspace%d.log" % slot
        )

        log = open(
            log_path,
            "ab",
            buffering=0
        )

        # =================================================
        # MAX 200 MB HEAP PER MICROEMULATOR
        # =================================================

        command = [
            "java",

            "-Xms32m",
            "-Xmx200m",

            "-XX:MaxMetaspaceSize=64m",

            "-noverify",

            "-Djava.awt.headless=false",

            "-Dawt.useSystemAAFontSettings=on",

            "-Dswing.aatext=true",

            # =================================================
            # CACHE / USER HOME TERPISAH
            # =================================================

            "-Duser.home=" + ws,

            "-cp",

            MICROEMU + ":" + DEVICE,

            "org.microemu.app.Main",

            jad
        ]

        env = {
            **os.environ,
            "DISPLAY": DISPLAY,
            "HOME": ws
        }

        print(
            "Starting workspace %d" % slot,
            flush=True
        )

        print(
            "HOME: %s" % ws,
            flush=True
        )

        print(
            "MAX RAM HEAP: 200MB",
            flush=True
        )

        p = subprocess.Popen(
            command,
            cwd=ws,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT
        )

        workspace_processes.append(p)

        print(
            "Workspace %d PID=%s"
            % (slot, p.pid),
            flush=True
        )

    # Resize window setelah MicroEmulator muncul
    with open(SIZE_FILE) as f:
        width, height = [
            int(x)
            for x in f.read().split()[:2]
        ]

    subprocess.Popen(
        [
            "sh",
            "-c",
            (
                "sleep 3; "
                "window=$(xdotool search "
                "--name 'MicroEmulator' "
                "2>/dev/null | head -1); "
                "if [ -n \"$window\" ]; then "
                "xdotool windowsize "
                "\"$window\" %d %d; "
                "fi"
            )
            % (width, height)
        ],
        env={
            **os.environ,
            "DISPLAY": DISPLAY
        }
    )

    return "Workspace berhasil dimulai"


# =========================================================
# SCREENSHOT
# =========================================================

def make_screenshot():

    ensure_files()

    raw = SCREENSHOT + ".raw.png"

    try:

        windows = subprocess.check_output(
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
            text=True
        ).splitlines()

        if not windows:
            raise IndexError

        window = windows[0]

        command = [
            "import",
            "-display",
            DISPLAY,
            "-window",
            window,
            "-crop",
            "393x326+0+50",
            "-type",
            "TrueColor",
            "-depth",
            "8",
            "PNG24:" + raw
        ]

    except (
        subprocess.CalledProcessError,
        IndexError
    ):

        command = [
            "import",
            "-display",
            DISPLAY,
            "-window",
            "root",
            "-crop",
            "393x326+0+0",
            "-type",
            "TrueColor",
            "-depth",
            "8",
            "PNG24:" + raw
        ]

    result = subprocess.run(
        command,
        capture_output=True
    )

    if result.returncode != 0:

        raise RuntimeError(
            result.stderr.decode(
                errors="replace"
            )
            or "Gagal screenshot"
        )

    enhanced = subprocess.run(
        [
            "convert",
            raw,
            "-trim",
            "+repage",
            "-filter",
            "Lanczos",
            "-resize",
            "393x326^",
            "-gravity",
            "center",
            "-extent",
            "393x326",
            "-type",
            "TrueColor",
            "-depth",
            "8",
            "-quality",
            "100",
            "PNG24:" + SCREENSHOT
        ],
        capture_output=True
    )

    if enhanced.returncode != 0:

        raise RuntimeError(
            enhanced.stderr.decode(
                errors="replace"
            )
            or "Gagal meningkatkan screenshot"
        )


# =========================================================
# RESIZE
# =========================================================

def resize_emulator(width, height):

    width = max(
        120,
        min(1200, int(width))
    )

    height = max(
        120,
        min(1200, int(height))
    )

    with open(SIZE_FILE, "w") as f:
        f.write(
            "%d %d\n" %
            (width, height)
        )

    # Config dipisah untuk masing-masing workspace
    for slot in (1, 2):

        config = workspace_config(slot)

        os.makedirs(
            os.path.dirname(config),
            exist_ok=True
        )

        with open(config, "w") as f:

            f.write(
                "<config>"
                "<devices>"
                "<device default=\"true\">"
                "<name>Avatar resizable</name>"
                "<descriptor>"
                "org/microemu/device/resizable/device.xml"
                "</descriptor>"
                "<rectangle>"
                "<x>0</x>"
                "<y>0</y>"
                "<width>%d</width>"
                "<height>%d</height>"
                "</rectangle>"
                "</device>"
                "</devices>"
                "</config>\n"
                % (width, height)
            )

    # Restart supaya ukuran diterapkan
    for p in workspace_processes:

        if p is not None and p.poll() is None:

            p.terminate()

    time.sleep(1)

    start_emulator()

    return width, height


# =========================================================
# HTML PANEL
# =========================================================

def page(message=""):

    running = emulator_running()
    states = workspace_states()

    notice = (
        '<div class="notice">%s</div>'
        % message
        if message
        else ""
    )

    state_class = "" if running else " stopped"

    state_text = (
        "running"
        if running
        else "stopped"
    )

    return """<!doctype html>
<html lang="id">

<head>

<meta charset="utf-8">

<meta name="viewport"
content="width=device-width,initial-scale=1">

<title>Avatar FreeJ2ME</title>

<style>

:root {
    color-scheme: dark;
}

* {
    box-sizing: border-box;
}

body {
    margin: 0;
    background: #0b1020;
    color: #eef2ff;
    font: 15px system-ui,
    -apple-system,
    Segoe UI,
    sans-serif;
}

main {
    max-width: 980px;
    margin: auto;
    padding: 32px 20px;
}

.top {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 24px;
}

.brand {
    font-size: 25px;
    font-weight: 800;
}

.muted,
.small {
    color: #97a3bf;
}

.small {
    font-size: 13px;
}

.grid {
    display: grid;
    grid-template-columns: 1.1fr .9fr;
    gap: 18px;
}

.card {
    background: #121a2e;
    border: 1px solid #263453;
    border-radius: 18px;
    padding: 22px;
    box-shadow: 0 14px 40px #0003;
}

h2 {
    margin: 0 0 8px;
}

.status {
    padding: 6px 11px;
    border-radius: 99px;
    background: #163d32;
    color: #70e1b4;
}

.status.stopped {
    background: #442333;
    color: #ff9db2;
}

button {
    border: 0;
    border-radius: 10px;
    padding: 11px 15px;
    background: #6d5dfc;
    color: white;
    font-weight: 700;
    cursor: pointer;
    margin: 5px 5px 5px 0;
}

button.alt {
    background: #263453;
}

input {
    width: 100%;
    padding: 12px;
    border: 1px solid #334367;
    border-radius: 10px;
    background: #0c1426;
    color: white;
    margin: 7px 0 12px;
}

.notice {
    background: #1d2b4a;
    padding: 12px;
    border-radius: 10px;
    margin-bottom: 18px;
}

.shot {
    width: 100%;
    min-height: 260px;
    object-fit: contain;
    background: #080b13;
    border-radius: 12px;
    margin-top: 14px;
    border: 1px solid #263453;
}

@media(max-width:720px) {

    .grid {
        grid-template-columns: 1fr;
    }

}

</style>

</head>

<body>

<main>

<div class="top">

<div>

<div class="brand">
Avatar FreeJ2ME
</div>

<div class="muted">
J2ME game control panel
</div>

</div>

<div class="status%s">
● %s
</div>

</div>

%s

<div class="grid">

<section class="card">

<h2>Emulator</h2>

<p class="muted">
MicroEmulator · avatar.jar · Display virtual: %s
</p>

<form method="post"
action="/workspace">

<button name="slot"
value="1"
class="alt">

Workspace 1: %s

</button>

<button name="slot"
value="2"
class="alt">

Workspace 2: %s

</button>

</form>

<form method="post"
action="/start">

<button>
Start emulator
</button>

</form>

<form method="post"
action="/screenshot">

<button class="alt">
Ambil screenshot
</button>

<a href="/screenshot.png"
target="_blank">

<button type="button"
class="alt">

Buka gambar

</button>

</a>

</form>

<p class="small">
Workspace 1 dan 2 mempunyai
cache/user.home terpisah.
<br>
RAM Java maksimal:
200 MB per workspace.
</p>

<img
class="shot"
src="/screenshot.png?%s"
alt="Screenshot emulator">

</section>

<section class="card">

<h2>Change password</h2>

<p class="muted">
Hanya password login panel yang berubah.
Emulator tetap berjalan.
</p>

<form method="post"
action="/change-password">

<label>
Password saat ini
</label>

<input
type="password"
name="current"
required>

<label>
Password baru
</label>

<input
type="password"
name="new"
minlength="6"
required>

<label>
Ulangi password baru
</label>

<input
type="password"
name="confirm"
minlength="6"
required>

<button>
Simpan password
</button>

</form>

<p class="small">
Password default awal:
<b>123456</b>
</p>

</section>

</div>

</main>

</body>

</html>
""" % (
        state_class,
        state_text,
        notice,
        DISPLAY,
        "aktif" if states[0] else "nonaktif",
        "aktif" if states[1] else "nonaktif",
        int(time.time())
    )


# =========================================================
# HTTP HANDLER
# =========================================================

class Handler(
    http.server.BaseHTTPRequestHandler
):

    def log_message(self, fmt, *args):

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

        if not value.startswith("Basic "):
            return False

        try:

            username, password = (
                base64.b64decode(
                    value[6:]
                )
                .decode()
                .split(":", 1)
            )

            return (
                username == "admin"
                and
                check_password(password)
            )

        except Exception:

            return False

    def require_auth(self):

        if self.authorized():
            return True

        self.send_response(401)

        self.send_header(
            "WWW-Authenticate",
            'Basic realm="Avatar MicroEmulator"'
        )

        self.end_headers()

        self.wfile.write(
            b"Login required"
        )

        return False

    def send_html(self, body):

        encoded = body.encode(
            "utf-8"
        )

        self.send_response(200)

        self.send_header(
            "Content-Type",
            "text/html; charset=utf-8"
        )

        self.send_header(
            "Content-Length",
            str(len(encoded))
        )

        self.end_headers()

        self.wfile.write(encoded)

    def do_GET(self):

        if not self.require_auth():
            return

        path = urlparse(
            self.path
        ).path

        if path in ("/", "/index.html"):

            message = parse_qs(
                urlparse(
                    self.path
                ).query
            ).get(
                "message",
                [""]
            )[0]

            self.send_html(
                page(message)
            )

        elif path == "/screenshot.png":

            try:

                make_screenshot()

                with open(
                    SCREENSHOT,
                    "rb"
                ) as f:

                    data = f.read()

                self.send_response(200)

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

            except Exception as exc:

                self.send_error(
                    404,
                    str(exc)
                )

        else:

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

                slot = fields.get(
                    "slot",
                    ["1"]
                )[0]

                states = workspace_states()

                index = (
                    0
                    if slot == "1"
                    else 1
                )

                states[index] = not states[index]

                with open(
                    WORKSPACE_FILE,
                    "w"
                ) as f:

                    f.write(
                        "%d,%d\n"
                        % (
                            int(states[0]),
                            int(states[1])
                        )
                    )

                for p in workspace_processes:

                    if (
                        p is not None
                        and
                        p.poll() is None
                    ):

                        p.terminate()

                time.sleep(1)

                start_emulator()

                message = (
                    "Workspace %s %s"
                    % (
                        slot,
                        (
                            "diaktifkan"
                            if states[index]
                            else "dinonaktifkan"
                        )
                    )
                )

            elif path == "/screenshot":

                make_screenshot()

                message = (
                    "Screenshot berhasil diperbarui"
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

                if not check_password(current):

                    message = (
                        "Password saat ini salah"
                    )

                elif len(new) < 6:

                    message = (
                        "Password baru minimal 6 karakter"
                    )

                elif new != confirm:

                    message = (
                        "Konfirmasi password tidak cocok"
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
                        "Password login berhasil diubah"
                    )

            else:

                self.send_error(404)
                return

        except Exception as exc:

            message = (
                "Gagal: " + str(exc)
            )

        self.send_response(303)

        self.send_header(
            "Location",
            "/?message=" + quote(message)
        )

        self.end_headers()


# =========================================================
# MAIN
# =========================================================

def main():

    ensure_files()

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

    print(
        "Workspace cache:",
        DATA_DIR + "/workspace1",
        flush=True
    )

    print(
        "Workspace cache:",
        DATA_DIR + "/workspace2",
        flush=True
    )

    print(
        "Java heap:",
        "200MB per workspace",
        flush=True
    )

    try:

        start_emulator()

    except Exception as exc:

        print(
            "Peringatan emulator:",
            exc,
            flush=True
        )

    server = (
        http.server.ThreadingHTTPServer(
            (HOST, PORT),
            Handler
        )
    )

    print(
        "Avatar panel listening on port %s"
        % PORT,
        flush=True
    )

    try:

        server.serve_forever()

    finally:

        for p in workspace_processes:

            if (
                p is not None
                and
                p.poll() is None
            ):

                p.terminate()


if __name__ == "__main__":
    main()

PY

RUN chmod +x /opt/avatar/app.py \
    && python3 -m py_compile /opt/avatar/app.py

# =========================================================
# PORT
# =========================================================

WORKDIR /opt/avatar

EXPOSE 8080 5901

# =========================================================
# START
# =========================================================

CMD ["sh", "-c", "\
set -eu; \
mkdir -p /data; \
if [ ! -s /data/vnc.pass ]; then \
    x11vnc -storepasswd \"${VNC_PASSWORD:-123456}\" /data/vnc.pass >/dev/null 2>&1 || true; \
fi; \
echo 'Starting Xvfb...'; \
Xvfb :99 \
    -screen 0 393x700x24 \
    -ac \
    +extension GLX \
    >/data/xvfb.log 2>&1 & \
for i in $(seq 1 20); do \
    if xdpyinfo -display :99 >/dev/null 2>&1; then \
        break; \
    fi; \
    sleep 1; \
done; \
if ! xdpyinfo -display :99 >/dev/null 2>&1; then \
    echo 'Xvfb failed'; \
    cat /data/xvfb.log; \
    exit 1; \
fi; \
echo 'Xvfb OK'; \
( \
while true; do \
    x11vnc \
        -display :99 \
        -rfbport 5901 \
        -rfbauth /data/vnc.pass \
        -forever \
        -shared \
        -xkb \
        -noxrecord \
        -noxfixes \
        -noxdamage \
        >>/data/x11vnc.log 2>&1 || true; \
    sleep 2; \
done \
) & \
echo 'VNC started on 5901'; \
echo 'Starting Web Panel on 8080...'; \
exec python3 /opt/avatar/app.py \
"]
