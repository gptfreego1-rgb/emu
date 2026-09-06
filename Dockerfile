FROM eclipse-temurin:17-jre-alpine

ENV \
    DISPLAY=:99 \
    PORT=8080 \
    DATA_DIR=/data \
    MALLOC_ARENA_MAX=2

RUN apk add --no-cache \
        python3 curl unzip imagemagick xvfb x11vnc xdpyinfo xdotool \
        fontconfig ttf-dejavu \
    && mkdir -p /opt/avatar /data \
    && curl -L --fail --retry 3 -o /opt/avatar/avatar.jar https://files.catbox.moe/sllphh.ja \
    && curl -L --fail --retry 3 -o /tmp/microemulator.zip 'https://sourceforge.net/projects/microemulator/files/microemulator/2.0.4/microemulator-2.0.4.zip/download' \
    && unzip -q /tmp/microemulator.zip -d /tmp \
    && cp /tmp/microemulator-2.0.4/microemulator.jar /opt/avatar/microemulator.jar \
    && cp /tmp/microemulator-2.0.4/devices/microemu-device-resizable.jar /opt/avatar/microemu-device-resizable.jar \
    && rm -rf /tmp/microemulator.zip /tmp/microemulator-2.0.4 /var/cache/apk/*

RUN <<'SH'
cat > /opt/avatar/app.py <<'PY'
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

HOST = os.getenv('HOST', '0.0.0.0')
PORT = int(os.getenv('HTTP_PORT', '8080'))
DISPLAY = os.getenv('DISPLAY', ':99')
DATA_DIR = os.getenv('DATA_DIR', '/data')
DEFAULT_PASSWORD = os.getenv('DEFAULT_PASSWORD', '123456')
JAR = '/opt/avatar/avatar.jar'
MICROEMU = '/opt/avatar/microemulator.jar'
DEVICE = '/opt/avatar/microemu-device-resizable.jar'
PASSWORD_FILE = os.path.join(DATA_DIR, 'password.sha256')
processes = {}


def hash_password(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def workspace_dir(slot):
    return os.path.join(DATA_DIR, 'workspace%d' % slot)


def workspace_log(slot):
    return os.path.join(DATA_DIR, 'workspace%d.log' % slot)


def ensure_files():
    os.makedirs(DATA_DIR, exist_ok=True)
    
    # Buat direktori untuk tiap workspace
    for slot in (1, 2):
        home = workspace_dir(slot)
        os.makedirs(home, exist_ok=True)
        os.makedirs(os.path.join(home, '.microemulator'), exist_ok=True)
    
    if not os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, 'w') as f:
            f.write(hash_password(DEFAULT_PASSWORD))


def check_password(value):
    try:
        with open(PASSWORD_FILE) as f:
            stored = f.read().strip()
        return hmac.compare_digest(stored, hash_password(value))
    except OSError:
        return False


def get_windows():
    """Get MicroEmulator windows"""
    try:
        result = subprocess.run(
            ['xdotool', 'search', '--name', 'MicroEmulator'],
            env={**os.environ, 'DISPLAY': DISPLAY},
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().splitlines()
    except:
        pass
    return []


def start_emulator():
    """Start emulator dengan cara sederhana"""
    # Kill existing processes
    for p in processes.values():
        if p and p.poll() is None:
            p.terminate()
            time.sleep(1)
            if p.poll() is None:
                p.kill()
    processes.clear()
    
    started = 0
    for slot in (1, 2):
        home = workspace_dir(slot)
        
        # Buat JAD file sederhana
        jad_file = os.path.join(home, 'avatar.jad')
        with open(jad_file, 'w') as f:
            f.write(f'''MIDlet-Name: Avatar
MIDlet-Version: 1.0
MIDlet-Vendor: FreeJ2ME
MIDlet-Jar-URL: file://{JAR}
MIDlet-Jar-Size: {os.path.getsize(JAR)}
MicroEdition-Configuration: CLDC-1.1
MicroEdition-Profile: MIDP-2.1
''')
        
        # Command untuk MicroEmulator
        cmd = [
            'java',
            '-cp', f'{MICROEMU}:{DEVICE}',
            '-Duser.home=' + home,
            'org.microemu.app.Main',
            jad_file
        ]
        
        print(f'Starting workspace {slot}: {" ".join(cmd)}')
        
        log_file = workspace_log(slot)
        with open(log_file, 'w') as log:
            log.write(f'=== Starting workspace {slot} at {time.ctime()} ===\n')
            log.write(f'Command: {" ".join(cmd)}\n')
            log.flush()
        
        # Jalankan process
        p = subprocess.Popen(
            cmd,
            cwd='/opt/avatar',
            env={**os.environ, 'DISPLAY': DISPLAY},
            stdout=open(log_file, 'a'),
            stderr=subprocess.STDOUT
        )
        processes[slot] = p
        started += 1
        print(f'Started workspace {slot} with PID {p.pid}')
        time.sleep(2)
    
    # Resize windows di background
    def resize_windows():
        print('Waiting for windows...')
        time.sleep(5)
        windows = get_windows()
        if windows:
            print(f'Found {len(windows)} windows')
            for window in windows:
                try:
                    subprocess.run(['xdotool', 'windowsize', window, '390', '310'], 
                                 env={**os.environ, 'DISPLAY': DISPLAY}, timeout=5)
                    print(f'Resized window {window}')
                except Exception as e:
                    print(f'Error resizing: {e}')
        else:
            print('No windows found!')
            # Cek log untuk debug
            for slot in (1, 2):
                log_file = workspace_log(slot)
                if os.path.exists(log_file):
                    with open(log_file) as f:
                        content = f.read()
                        if content:
                            print(f'=== Workspace {slot} log ===')
                            print(content[-500:])
    
    threading.Thread(target=resize_windows, daemon=True).start()
    return f'Started {started} workspace(s)'


def make_screenshot(selection='both'):
    """Ambil screenshot"""
    windows = get_windows()
    if not windows:
        raise RuntimeError('No MicroEmulator window found')
    
    slots = [1, 2] if selection == 'both' else [int(selection)]
    results = []
    
    for i, slot in enumerate(slots):
        if i >= len(windows):
            break
        window = windows[i]
        output = os.path.join(DATA_DIR, f'screenshot_{slot}.png')
        
        try:
            subprocess.run([
                'import', '-display', DISPLAY,
                '-window', window,
                '-crop', '393x326+0+50',
                'PNG24:' + output
            ], capture_output=True, check=True, timeout=10)
            results.append(output)
        except Exception as e:
            raise RuntimeError(f'Failed to screenshot workspace {slot}: {e}')
    
    return results


def page(message=''):
    running = any(p and p.poll() is None for p in processes.values())
    notice = f'<div class="notice">{message}</div>' if message else ''
    
    return f'''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Avatar FreeJ2ME</title>
<style>
*{{box-sizing:border-box}}body{{margin:0;background:#0b1020;color:#eef2ff;font:system-ui,sans-serif}}
main{{max-width:1000px;margin:auto;padding:20px}}
.card{{background:#121a2e;border:1px solid #263453;border-radius:16px;padding:20px;margin-bottom:20px}}
button{{border:0;border-radius:10px;padding:10px 20px;background:#6d5dfc;color:white;font-weight:bold;cursor:pointer;margin:5px}}
button.alt{{background:#263453}}
.status{{display:inline-block;padding:4px 12px;border-radius:99px;background:#163d32;color:#70e1b4}}
.status.stopped{{background:#442333;color:#ff9db2}}
.shot{{width:100%;max-width:400px;border-radius:8px;border:1px solid #263453}}
.notice{{background:#1d2b4a;padding:12px;border-radius:10px;margin-bottom:18px}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:20px}}
@media(max-width:700px){{.grid{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<main>
<div style="display:flex;justify-content:space-between;align-items:center">
<h1>Avatar FreeJ2ME</h1>
<span class="status{'' if running else ' stopped'}">● {'RUNNING' if running else 'STOPPED'}</span>
</div>
{notice}

<div class="grid">
<div class="card">
<h2>Workspace 1</h2>
<p>Status: {'Running' if running else 'Stopped'}</p>
<img class="shot" src="/screenshot/1.png?{int(time.time())}" alt="Workspace 1" onerror="this.style.display='none'">
</div>
<div class="card">
<h2>Workspace 2</h2>
<p>Status: {'Running' if running else 'Stopped'}</p>
<img class="shot" src="/screenshot/2.png?{int(time.time())+1}" alt="Workspace 2" onerror="this.style.display='none'">
</div>
</div>

<div class="card">
<h2>Control</h2>
<form method="post" action="/start" style="display:inline">
<button>Start Emulator</button>
</form>
<form method="post" action="/screenshot" style="display:inline">
<select name="selection">
<option value="1">Workspace 1</option>
<option value="2">Workspace 2</option>
<option value="both" selected>Both</option>
</select>
<button class="alt">Take Screenshot</button>
</form>
</div>

<div class="card">
<h2>Change Password</h2>
<form method="post" action="/change-password">
<input type="password" name="current" placeholder="Current password" required>
<input type="password" name="new" placeholder="New password" minlength="6" required>
<input type="password" name="confirm" placeholder="Confirm password" minlength="6" required>
<button>Save</button>
</form>
<p style="color:#97a3bf;font-size:13px">Default: 123456</p>
</div>
</main>
</body>
</html>'''


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f'{self.address_string()} - {fmt % args}', flush=True)

    def authorized(self):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Basic '):
            return False
        try:
            _, creds = auth.split(' ', 1)
            username, password = base64.b64decode(creds).decode().split(':', 1)
            return username == 'admin' and check_password(password)
        except:
            return False

    def require_auth(self):
        if self.authorized():
            return True
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Avatar"')
        self.end_headers()
        self.wfile.write(b'Login required')
        return False

    def do_GET(self):
        if not self.require_auth():
            return
        path = urlparse(self.path).path
        
        if path in ('/', '/index.html'):
            self.send_html(page())
        elif path.startswith('/screenshot/'):
            try:
                slot = int(path.split('/')[2].split('.')[0])
                output = os.path.join(DATA_DIR, f'screenshot_{slot}.png')
                if os.path.exists(output):
                    with open(output, 'rb') as f:
                        data = f.read()
                    self.send_response(200)
                    self.send_header('Content-Type', 'image/png')
                    self.send_header('Cache-Control', 'no-store')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                else:
                    self.send_error(404, 'Screenshot not found')
            except:
                self.send_error(404)
        else:
            self.send_error(404)

    def send_html(self, body):
        encoded = body.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

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
                selection = fields.get('selection', ['both'])[0]
                make_screenshot(selection)
                message = f'Screenshot taken for {selection}'
            elif path == '/change-password':
                current = fields.get('current', [''])[0]
                new = fields.get('new', [''])[0]
                confirm = fields.get('confirm', [''])[0]
                if not check_password(current):
                    message = 'Wrong password'
                elif len(new) < 6:
                    message = 'Password too short'
                elif new != confirm:
                    message = 'Passwords do not match'
                else:
                    with open(PASSWORD_FILE, 'w') as f:
                        f.write(hash_password(new))
                    message = 'Password changed'
            else:
                self.send_error(404)
                return
        except Exception as e:
            message = f'Error: {str(e)}'
            print(f'POST error: {e}')
        
        self.send_response(303)
        self.send_header('Location', '/?message=' + quote(message))
        self.end_headers()


def main():
    ensure_files()
    print('Starting emulator...')
    try:
        start_emulator()
    except Exception as e:
        print(f'Error starting emulator: {e}')
    
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    print(f'Server running on port {PORT}')
    try:
        server.serve_forever()
    finally:
        for p in processes.values():
            if p and p.poll() is None:
                p.terminate()

if __name__ == '__main__':
    main()
PY
chmod +x /opt/avatar/app.py
python3 -m py_compile /opt/avatar/app.py
SH

WORKDIR /opt/avatar
EXPOSE 5901 8080

CMD ["sh", "-c", "set -eu; mkdir -p /data; echo '[startup] Starting...' >>/data/startup.log; if [ ! -s /data/vnc.pass ]; then x11vnc -storepasswd \"${VNC_PASSWORD:-123456}\" /data/vnc.pass >/dev/null 2>&1 || true; fi; Xvfb :99 -screen 0 393x900x24 -ac +extension GLX >/data/xvfb.log 2>&1 & echo $! >/data/xvfb.pid; for i in $(seq 1 20); do if xdpyinfo -display :99 >/dev/null 2>&1; then break; fi; sleep 1; done; xdpyinfo -display :99 >>/data/startup.log 2>&1 || true; (while true; do x11vnc -display :99 -rfbport 5901 -rfbauth /data/vnc.pass -forever -shared -xkb -noxrecord -noxfixes -noxdamage >>/data/x11vnc.log 2>&1 || true; sleep 2; done) & echo $! >/data/x11vnc.pid; exec python3 /opt/avatar/app.py"]
