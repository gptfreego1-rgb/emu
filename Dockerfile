FROM eclipse-temurin:17-jre-jammy

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:99 \
    PORT=8080 \
    DATA_DIR=/data

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 curl unzip imagemagick xvfb x11vnc x11-utils xdotool \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/avatar /data \
    && curl -L --fail --retry 3 -o /opt/avatar/avatar.jar https://files.catbox.moe/sllphh.ja \
    && curl -L --fail --retry 3 -o /tmp/kemulator.zip https://github.com/shinovon/KEmulator/releases/download/v2.21.4/kemnnmod.v2.21.4.nojre.zip \
    && unzip -q /tmp/kemulator.zip -d /tmp/kemulator \
    && cp /tmp/kemulator/kemnnmod/KEmulator.jar /opt/avatar/kemulator.jar \
    && rm -rf /tmp/kemulator.zip /tmp/kemulator

RUN <<'SH'
cat > /opt/avatar/app.py <<'PY'
#!/usr/bin/env python3
import base64
import hashlib
import hmac
import http.server
import os
import subprocess
import threading
import time
from urllib.parse import parse_qs, quote, urlparse

HOST = os.getenv('HOST', '0.0.0.0')
# Panel HTTP Railway memakai 8080; VNC/RFB tetap memakai 5901.
PORT = int(os.getenv('HTTP_PORT', '8080'))
DISPLAY = os.getenv('DISPLAY', ':99')
DATA_DIR = os.getenv('DATA_DIR', '/data')
DEFAULT_PASSWORD = os.getenv('DEFAULT_PASSWORD', '123456')
JAR = '/opt/avatar/avatar.jar'
KEMULATOR = '/opt/avatar/kemulator.jar'
JAD = os.path.join(DATA_DIR, 'avatar.jad')
PASSWORD_FILE = os.path.join(DATA_DIR, 'password.sha256')
SCREENSHOT = os.path.join(DATA_DIR, 'microemulator.png')
SIZE_FILE = os.path.join(DATA_DIR, 'screen.size')
process = None


def hash_password(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def ensure_files():
    os.makedirs(DATA_DIR, exist_ok=True)
    if not os.path.exists(SIZE_FILE):
        with open(SIZE_FILE, 'w') as f:
            f.write('393 326\n')
    if not os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, 'w') as f:
            f.write(hash_password(DEFAULT_PASSWORD))
    if not os.path.exists(JAD):
        with open(JAD, 'w') as f:
            f.write('MIDlet-Jar-URL: file:///opt/avatar/avatar.jar\nMIDlet-Jar-Size: %d\n' % os.path.getsize(JAR))


def check_password(value):
    try:
        with open(PASSWORD_FILE) as f:
            stored = f.read().strip()
        return hmac.compare_digest(stored, hash_password(value))
    except OSError:
        return False


def emulator_running():
    return process is not None and process.poll() is None


def start_emulator():
    global process
    if emulator_running():
        return 'Emulator sudah berjalan'
    ensure_files()
    with open(SIZE_FILE) as f:
        width, height = [int(x) for x in f.read().split()[:2]]
    # Opsi -noverify diletakkan sebelum -jar karena itu sintaks Java launcher yang valid.
    command = [
        'java', '-noverify', '-Djava.awt.headless=false',
        '-jar', KEMULATOR, JAR
    ]
    log = open(os.path.join(DATA_DIR, 'emulator.log'), 'ab', buffering=0)
    process = subprocess.Popen(
        command,
        cwd='/opt/avatar',
        env={**os.environ, 'DISPLAY': DISPLAY},
        stdout=log,
        stderr=subprocess.STDOUT
    )
    subprocess.Popen([
        'sh', '-c',
        "sleep 3; window=$(xdotool search --name 'KEmulator' 2>/dev/null | head -1); "
        "if [ -n \"$window\" ]; then xdotool windowsize \"$window\" %d %d; fi" % (width, height)
    ], env={**os.environ, 'DISPLAY': DISPLAY})
    return 'Emulator berhasil dimulai'


def make_screenshot():
    ensure_files()
    result = subprocess.run(
        ['import', '-display', DISPLAY, '-window', 'root', '-crop', '393x326+0+0', SCREENSHOT],
        capture_output=True
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors='replace') or 'Gagal mengambil screenshot')


def resize_emulator(width, height):
    width = max(120, min(1200, int(width)))
    height = max(120, min(1200, int(height)))
    with open(SIZE_FILE, 'w') as f:
        f.write('%d %d\n' % (width, height))
    if emulator_running():
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    start_emulator()
    return width, height


def page(message=''):
    running = emulator_running()
    notice = '<div class="notice">%s</div>' % message if message else ''
    state_class = '' if running else ' stopped'
    state_text = 'running' if running else 'stopped'
    return '''<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Avatar FreeJ2ME</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#0b1020;color:#eef2ff;font:15px system-ui,-apple-system,Segoe UI,sans-serif}main{max-width:980px;margin:auto;padding:32px 20px}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}.brand{font-size:25px;font-weight:800}.muted,.small{color:#97a3bf}.small{font-size:13px}.grid{display:grid;grid-template-columns:1.1fr .9fr;gap:18px}.card{background:#121a2e;border:1px solid #263453;border-radius:18px;padding:22px;box-shadow:0 14px 40px #0003}h2{margin:0 0 8px}.status{padding:6px 11px;border-radius:99px;background:#163d32;color:#70e1b4}.status.stopped{background:#442333;color:#ff9db2}button{border:0;border-radius:10px;padding:11px 15px;background:#6d5dfc;color:white;font-weight:700;cursor:pointer;margin:5px 5px 5px 0}button.alt{background:#263453}input{width:100%%;padding:12px;border:1px solid #334367;border-radius:10px;background:#0c1426;color:white;margin:7px 0 12px}.notice{background:#1d2b4a;padding:12px;border-radius:10px;margin-bottom:18px}.shot{width:100%%;min-height:260px;object-fit:contain;background:#080b13;border-radius:12px;margin-top:14px;border:1px solid #263453}@media(max-width:720px){.grid{grid-template-columns:1fr}}
</style></head><body><main>
<div class="top"><div><div class="brand">Avatar FreeJ2ME</div><div class="muted">J2ME game control panel</div></div><div class="status%s">● %s</div></div>%s
<div class="grid"><section class="card"><h2>Emulator</h2><p class="muted">FreeJ2ME AWT · avatar.jar · Display virtual: %s</p>
<form method="post" action="/resize"><label>Lebar (px)</label><input type="number" name="width" value="393" min="120" max="1200" required><label>Tinggi (px)</label><input type="number" name="height" value="326" min="120" max="1200" required><button class="alt">Terapkan ukuran dari web</button></form>
<form method="post" action="/start"><button>Start emulator</button></form>
<form method="post" action="/screenshot"><button class="alt">Ambil screenshot</button><a href="/screenshot.png" target="_blank"><button type="button" class="alt">Buka gambar</button></a></form>
<p class="small">Screenshot diambil dari framebuffer Xvfb MicroEmulator.</p><img class="shot" src="/screenshot.png?%s" alt="Screenshot emulator" onerror="this.style.display='none'"></section>
<section class="card"><h2>Change password</h2><p class="muted">Hanya password login panel yang berubah. Emulator tetap berjalan.</p>
<form method="post" action="/change-password"><label>Password saat ini</label><input type="password" name="current" required><label>Password baru</label><input type="password" name="new" minlength="6" required><label>Ulangi password baru</label><input type="password" name="confirm" minlength="6" required><button>Simpan password</button></form>
<p class="small">Password default awal: <b>123456</b>. Data login disimpan di volume /data.</p></section></div></main></body></html>''' % (state_class, state_text, notice, DISPLAY, int(time.time()))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print('%s - %s' % (self.address_string(), fmt % args), flush=True)

    def authorized(self):
        value = self.headers.get('Authorization', '')
        if not value.startswith('Basic '):
            return False
        try:
            username, password = base64.b64decode(value[6:]).decode().split(':', 1)
            return username == 'admin' and check_password(password)
        except Exception:
            return False

    def require_auth(self):
        if self.authorized():
            return True
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Avatar MicroEmulator"')
        self.end_headers()
        self.wfile.write(b'Login required')
        return False

    def send_html(self, body):
        encoded = body.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if not self.require_auth():
            return
        path = urlparse(self.path).path
        if path in ('/', '/index.html'):
            message = parse_qs(urlparse(self.path).query).get('message', [''])[0]
            self.send_html(page(message))
        elif path == '/screenshot.png':
            try:
                make_screenshot()
                with open(SCREENSHOT, 'rb') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'image/png')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as exc:
                self.send_error(404, str(exc))
        else:
            self.send_error(404)

    def do_POST(self):
        if not self.require_auth():
            return
        length = int(self.headers.get('Content-Length', 0))
        fields = parse_qs(self.rfile.read(length).decode())
        path = urlparse(self.path).path
        try:
            if path == '/start':
                message = start_emulator()
            elif path == '/screenshot':
                make_screenshot()
                message = 'Screenshot berhasil diperbarui'
            elif path == '/resize':
                width = fields.get('width', ['393'])[0]
                height = fields.get('height', ['326'])[0]
                width, height = resize_emulator(width, height)
                message = 'Ukuran MicroEmulator diubah menjadi %dx%d dari panel web' % (width, height)
            elif path == '/change-password':
                current = fields.get('current', [''])[0]
                new = fields.get('new', [''])[0]
                confirm = fields.get('confirm', [''])[0]
                if not check_password(current):
                    message = 'Password saat ini salah'
                elif len(new) < 6:
                    message = 'Password baru minimal 6 karakter'
                elif new != confirm:
                    message = 'Konfirmasi password tidak cocok'
                else:
                    with open(PASSWORD_FILE, 'w') as f:
                        f.write(hash_password(new))
                    message = 'Password login berhasil diubah tanpa mematikan emulator'
            else:
                self.send_error(404)
                return
        except Exception as exc:
            message = 'Gagal: ' + str(exc)
        self.send_response(303)
        self.send_header('Location', '/?message=' + quote(message))
        self.end_headers()


def main():
    ensure_files()
    try:
        start_emulator()
    except Exception as exc:
        print('Peringatan emulator: %s' % exc, flush=True)
    # Port $PORT untuk panel HTTP; port 5901 dipakai khusus oleh x11vnc.
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    print('Avatar panel listening on port %s' % PORT, flush=True)
    try:
        server.serve_forever()
    finally:
        if emulator_running():
            process.terminate()


if __name__ == '__main__':
    main()
PY
chmod +x /opt/avatar/app.py
python3 -m py_compile /opt/avatar/app.py
SH

WORKDIR /opt/avatar
EXPOSE 5901 8080

CMD ["sh", "-c", "mkdir -p /data; if [ ! -s /data/vnc.pass ]; then x11vnc -storepasswd \"${VNC_PASSWORD:-123456}\" /data/vnc.pass >/dev/null 2>&1 || true; fi; Xvfb :99 -screen 0 393x326x24 -ac +extension GLX >/data/xvfb.log 2>&1 & sleep 2; if xdpyinfo -display :99 >/dev/null 2>&1; then (while true; do x11vnc -display :99 -rfbport 5901 -rfbauth /data/vnc.pass -forever -shared -xkb -noxrecord -noxfixes -noxdamage >>/data/x11vnc.log 2>&1 || true; sleep 2; done) & else echo 'Xvfb failed; HTTP panel will still start' >>/data/xvfb.log; fi; exec python3 /opt/avatar/app.py"]
