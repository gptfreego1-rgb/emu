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

# Test MicroEmulator langsung
RUN java -cp /opt/avatar/microemulator.jar org.microemu.app.Main --help || true

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
import json
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
WORKSPACE_FILE = os.path.join(DATA_DIR, 'workspace.active')
processes = {}
workspace_enabled = {1: True, 2: True}


def hash_password(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def workspace_dir(slot):
    return os.path.join(DATA_DIR, 'workspace%d' % slot)


def workspace_jad(slot):
    return os.path.join(workspace_dir(slot), 'avatar.jad')


def workspace_screenshot(slot):
    return os.path.join(DATA_DIR, 'screenshot_workspace%d.png' % slot)


def workspace_log(slot):
    return os.path.join(DATA_DIR, 'workspace%d.log' % slot)


def ensure_files():
    os.makedirs(DATA_DIR, exist_ok=True)
    
    # Buat direktori dan file untuk tiap workspace
    for slot in (1, 2):
        home = workspace_dir(slot)
        os.makedirs(home, exist_ok=True)
        
        # Buat .microemulator directory
        microemu_dir = os.path.join(home, '.microemulator')
        os.makedirs(microemu_dir, exist_ok=True)
        
        # Config untuk workspace
        config_file = os.path.join(microemu_dir, 'config2.xml')
        if not os.path.exists(config_file):
            with open(config_file, 'w') as f:
                f.write('''<?xml version="1.0" encoding="UTF-8"?>
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
</config>''')
        
        # JAD file untuk workspace
        if not os.path.exists(workspace_jad(slot)):
            with open(workspace_jad(slot), 'w') as f:
                f.write('''MIDlet-Name: Avatar
MIDlet-Version: 1.0
MIDlet-Vendor: FreeJ2ME
MIDlet-Jar-URL: file:///opt/avatar/avatar.jar
MIDlet-Jar-Size: %d
MicroEdition-Configuration: CLDC-1.1
MicroEdition-Profile: MIDP-2.1
''' % os.path.getsize(JAR))
    
    if not os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, 'w') as f:
            f.write(hash_password(DEFAULT_PASSWORD))
    
    if not os.path.exists(WORKSPACE_FILE):
        with open(WORKSPACE_FILE, 'w') as f:
            f.write('1,1\n')


def check_password(value):
    try:
        with open(PASSWORD_FILE) as f:
            stored = f.read().strip()
        return hmac.compare_digest(stored, hash_password(value))
    except OSError:
        return False


def emulator_running(slot=None):
    if slot is None:
        return any(p is not None and p.poll() is None for p in processes.values())
    return slot in processes and processes[slot] is not None and processes[slot].poll() is None


def load_workspace_states():
    global workspace_enabled
    try:
        with open(WORKSPACE_FILE) as f:
            values = f.read().strip().split(',')
        workspace_enabled[1] = values[0] == '1'
        workspace_enabled[2] = len(values) > 1 and values[1] == '1'
    except (OSError, IndexError):
        workspace_enabled = {1: True, 2: True}
    return workspace_enabled


def save_workspace_states():
    with open(WORKSPACE_FILE, 'w') as f:
        f.write('%d,%d\n' % (int(workspace_enabled[1]), int(workspace_enabled[2])))


def get_windows():
    """Get MicroEmulator windows using xdotool"""
    try:
        result = subprocess.run(
            ['xdotool', 'search', '--name', 'MicroEmulator'],
            env={**os.environ, 'DISPLAY': DISPLAY},
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().splitlines()
    except Exception as e:
        print(f'Error getting windows: {e}')
    return []


def wait_for_windows(timeout=30):
    """Wait for MicroEmulator windows to appear"""
    start_time = time.time()
    while time.time() - start_time < timeout:
        windows = get_windows()
        if windows:
            print(f'Found {len(windows)} MicroEmulator windows')
            return windows
        time.sleep(0.5)
    return []


def start_emulator():
    """Start emulator for enabled workspaces"""
    load_workspace_states()
    
    # Kill existing processes
    for slot, p in list(processes.items()):
        if p is not None and p.poll() is None:
            print(f'Terminating workspace {slot}')
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    processes.clear()
    
    # Pastikan file avatar.jar ada dan bisa dibaca
    if not os.path.exists(JAR):
        print(f'ERROR: {JAR} not found!')
        return 'Error: avatar.jar not found'
    
    jar_size = os.path.getsize(JAR)
    print(f'avatar.jar size: {jar_size} bytes')
    
    # Start untuk tiap workspace
    started = 0
    for slot in (1, 2):
        if not workspace_enabled[slot]:
            print(f'Workspace {slot} disabled')
            continue
            
        print(f'Starting workspace {slot}...')
        home = workspace_dir(slot)
        jad_file = workspace_jad(slot)
        
        # Pastikan file ada
        if not os.path.exists(jad_file):
            print(f'JAD file not found: {jad_file}')
            continue
        
        # Update JAD dengan size yang benar
        with open(jad_file, 'w') as f:
            f.write(f'''MIDlet-Name: Avatar
MIDlet-Version: 1.0
MIDlet-Vendor: FreeJ2ME
MIDlet-Jar-URL: file://{JAR}
MIDlet-Jar-Size: {jar_size}
MicroEdition-Configuration: CLDC-1.1
MicroEdition-Profile: MIDP-2.1
''')
        
        # Command untuk menjalankan MicroEmulator
        cmd = [
            'java',
            '-cp', f'{MICROEMU}:{DEVICE}',
            '-Duser.home=' + home,
            'org.microemu.app.Main',
            jad_file
        ]
        
        print(f'Running: {" ".join(cmd)}')
        
        log_file = workspace_log(slot)
        with open(log_file, 'a') as log:
            log.write(f'\n=== Starting workspace {slot} at {time.ctime()} ===\n')
            log.write(f'Command: {" ".join(cmd)}\n')
            log.flush()
        
        # Jalankan proses
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
        time.sleep(2)  # Beri waktu untuk startup
    
    # Tunggu dan resize windows
    if started > 0:
        def resize_windows():
            print('Waiting for MicroEmulator windows...')
            windows = wait_for_windows(timeout=30)
            if windows:
                print(f'Found {len(windows)} windows, resizing...')
                for i, window in enumerate(windows, 1):
                    try:
                        # Resize window
                        subprocess.run(
                            ['xdotool', 'windowsize', window, '390', '310'],
                            env={**os.environ, 'DISPLAY': DISPLAY},
                            capture_output=True, timeout=5
                        )
                        print(f'Resized window {window}')
                    except Exception as e:
                        print(f'Error resizing window {window}: {e}')
            else:
                print('WARNING: No MicroEmulator windows found!')
                # Tampilkan log untuk debug
                for slot in (1, 2):
                    log_file = workspace_log(slot)
                    if os.path.exists(log_file):
                        with open(log_file, 'r') as f:
                            content = f.read()
                            if content:
                                print(f'=== Workspace {slot} log ===')
                                print(content[-1000:])  # Last 1000 chars
        
        threading.Thread(target=resize_windows, daemon=True).start()
    
    return f'Started {started} workspace(s)'


def make_screenshot(selection='both'):
    """Take screenshot for workspace(s)"""
    windows = get_windows()
    if not windows:
        # Coba tunggu sebentar
        windows = wait_for_windows(timeout=3)
        if not windows:
            raise RuntimeError('No MicroEmulator windows found. Make sure emulator is running.')
    
    # Map windows to slots
    windows_by_slot = {}
    for i, window in enumerate(windows[:2], 1):
        windows_by_slot[i] = window
    
    slots = [1, 2] if selection == 'both' else [int(selection)]
    results = []
    
    for slot in slots:
        if slot not in windows_by_slot:
            continue
            
        window = windows_by_slot[slot]
        output_file = workspace_screenshot(slot)
        
        try:
            # Screenshot dengan import
            subprocess.run([
                'import', '-display', DISPLAY, 
                '-window', window,
                '-crop', '393x326+0+50',
                'PNG24:' + output_file
            ], capture_output=True, check=True, timeout=10)
            
            # Optimasi gambar
            subprocess.run([
                'convert', output_file,
                '-trim', '+repage',
                '-resize', '393x326^',
                '-gravity', 'center',
                '-extent', '393x326',
                '-quality', '90',
                output_file
            ], capture_output=True, check=True, timeout=10)
            
            results.append(output_file)
            print(f'Screenshot saved for workspace {slot}')
        except Exception as e:
            print(f'Error screenshot workspace {slot}: {e}')
            raise RuntimeError(f'Failed to screenshot workspace {slot}: {e}')
    
    return results


def set_workspace(slot, enabled):
    """Enable or disable a workspace"""
    global workspace_enabled
    slot = int(slot)
    workspace_enabled[slot] = enabled
    save_workspace_states()
    
    # Restart emulator
    start_emulator()
    return workspace_enabled


def page(message=''):
    load_workspace_states()
    running1 = emulator_running(1)
    running2 = emulator_running(2)
    
    notice = f'<div class="notice">{message}</div>' if message else ''
    
    return f'''<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Avatar FreeJ2ME</title>
<style>
:root{{color-scheme:dark}}*{{box-sizing:border-box}}body{{margin:0;background:#0b1020;color:#eef2ff;font:15px system-ui,-apple-system,Segoe UI,sans-serif}}main{{max-width:1080px;margin:auto;padding:32px 20px}}.top{{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}}.brand{{font-size:25px;font-weight:800}}.muted,.small{{color:#97a3bf}}.small{{font-size:13px}}.grid{{display:grid;grid-template-columns:1fr 1fr;gap:18px}}.card{{background:#121a2e;border:1px solid #263453;border-radius:18px;padding:22px;box-shadow:0 14px 40px #0003}}h2{{margin:0 0 8px}}.status{{padding:6px 11px;border-radius:99px;background:#163d32;color:#70e1b4}}.status.stopped{{background:#442333;color:#ff9db2}}button{{border:0;border-radius:10px;padding:11px 15px;background:#6d5dfc;color:white;font-weight:700;cursor:pointer;margin:5px 5px 5px 0}}button.alt{{background:#263453}}button.success{{background:#1a7a4a}}button.danger{{background:#7a1a2a}}input{{width:100%;padding:12px;border:1px solid #334367;border-radius:10px;background:#0c1426;color:white;margin:7px 0 12px}}select{{padding:10px;border:1px solid #334367;border-radius:10px;background:#0c1426;color:white;margin:5px 5px 12px 0}}.notice{{background:#1d2b4a;padding:12px;border-radius:10px;margin-bottom:18px}}.shot-grid{{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:14px}}.shot{{width:100%;min-height:200px;object-fit:contain;background:#080b13;border-radius:12px;border:1px solid #263453}}.shot-label{{font-size:13px;color:#97a3bf;text-align:center;margin-bottom:4px}}
</style></head><body><main>
<div class="top"><div><div class="brand">Avatar FreeJ2ME</div><div class="muted">J2ME game control panel</div></div></div>{notice}
<div class="grid">
<section class="card"><h2>Workspace 1</h2>
<p class="muted">Status: <span class="status{'' if running1 else ' stopped'}">● {'running' if running1 else 'stopped'}</span></p>
<form method="post" action="/workspace"><input type="hidden" name="slot" value="1">
<button type="submit" class="{'danger' if workspace_enabled[1] else 'success'}">{'Disable' if workspace_enabled[1] else 'Enable'} Workspace 1</button></form>
</section>
<section class="card"><h2>Workspace 2</h2>
<p class="muted">Status: <span class="status{'' if running2 else ' stopped'}">● {'running' if running2 else 'stopped'}</span></p>
<form method="post" action="/workspace"><input type="hidden" name="slot" value="2">
<button type="submit" class="{'danger' if workspace_enabled[2] else 'success'}">{'Disable' if workspace_enabled[2] else 'Enable'} Workspace 2</button></form>
</section>
</div>

<div class="card" style="margin-top:18px"><h2>Control</h2>
<form method="post" action="/start" style="display:inline"><button>Start All Emulators</button></form>
<form method="post" action="/screenshot" style="display:inline">
<select name="selection"><option value="1">Workspace 1</option><option value="2">Workspace 2</option><option value="both" selected>Both Workspaces</option></select>
<button>Take Screenshot</button></form>
</div>

<div class="card" style="margin-top:18px">
<h2>Screenshots</h2>
<div class="shot-grid">
<div><div class="shot-label">Workspace 1</div>
<img class="shot" src="/screenshot/1.png?{int(time.time())}" alt="Workspace 1" onerror="this.style.display='none'"></div>
<div><div class="shot-label">Workspace 2</div>
<img class="shot" src="/screenshot/2.png?{int(time.time())+1}" alt="Workspace 2" onerror="this.style.display='none'"></div>
</div>
</div>

<div class="card" style="margin-top:18px"><h2>Change Password</h2>
<form method="post" action="/change-password"><label>Current Password</label><input type="password" name="current" required>
<label>New Password</label><input type="password" name="new" minlength="6" required>
<label>Confirm Password</label><input type="password" name="confirm" minlength="6" required>
<button>Save Password</button></form>
<p class="small">Default password: <b>123456</b></p></div>
</main></body></html>'''


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
        elif path.startswith('/screenshot/'):
            try:
                slot = int(path.split('/')[2].split('.')[0])
                if slot not in (1, 2):
                    raise ValueError('Invalid workspace')
                output_file = workspace_screenshot(slot)
                
                # Take fresh screenshot
                make_screenshot(str(slot))
                
                with open(output_file, 'rb') as f:
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
            elif path == '/workspace':
                slot = int(fields.get('slot', ['1'])[0])
                current_state = workspace_enabled[slot]
                set_workspace(slot, not current_state)
                message = f'Workspace {slot} {"enabled" if not current_state else "disabled"}'
            elif path == '/screenshot':
                selection = fields.get('selection', ['both'])[0]
                shots = make_screenshot(selection)
                if len(shots) == 1:
                    message = f'Screenshot taken for workspace {selection}'
                else:
                    message = 'Screenshots taken for both workspaces'
            elif path == '/change-password':
                current = fields.get('current', [''])[0]
                new = fields.get('new', [''])[0]
                confirm = fields.get('confirm', [''])[0]
                if not check_password(current):
                    message = 'Current password is incorrect'
                elif len(new) < 6:
                    message = 'New password must be at least 6 characters'
                elif new != confirm:
                    message = 'Passwords do not match'
                else:
                    with open(PASSWORD_FILE, 'w') as f:
                        f.write(hash_password(new))
                    message = 'Password changed successfully'
            else:
                self.send_error(404)
                return
        except Exception as exc:
            message = f'Error: {str(exc)}'
            print(f'POST error: {exc}')
        
        self.send_response(303)
        self.send_header('Location', '/?message=' + quote(message))
        self.end_headers()


def main():
    ensure_files()
    load_workspace_states()
    
    # Verifikasi file
    print(f'Checking {JAR}: {os.path.exists(JAR)}')
    if os.path.exists(JAR):
        print(f'Size: {os.path.getsize(JAR)} bytes')
    
    try:
        start_emulator()
    except Exception as exc:
        print(f'Warning starting emulator: {exc}', flush=True)
    
    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    print(f'Avatar panel listening on port {PORT}', flush=True)
    try:
        server.serve_forever()
    finally:
        for p in processes.values():
            if p is not None and p.poll() is None:
                p.terminate()

if __name__ == '__main__':
    main()
PY
chmod +x /opt/avatar/app.py
python3 -m py_compile /opt/avatar/app.py
SH

WORKDIR /opt/avatar
EXPOSE 5901 8080

CMD ["sh", "-c", "set -eu; mkdir -p /data; echo '[startup] container starting' >>/data/startup.log; if [ ! -s /data/vnc.pass ]; then x11vnc -storepasswd \"${VNC_PASSWORD:-123456}\" /data/vnc.pass >/dev/null 2>&1 || true; fi; Xvfb :99 -screen 0 393x900x24 -ac +extension GLX >/data/xvfb.log 2>&1 & echo $! >/data/xvfb.pid; for i in $(seq 1 20); do if xdpyinfo -display :99 >/dev/null 2>&1; then break; fi; sleep 1; done; xdpyinfo -display :99 >>/data/startup.log 2>&1 || true; (while true; do x11vnc -display :99 -rfbport 5901 -rfbauth /data/vnc.pass -forever -shared -xkb -noxrecord -noxfixes -noxdamage >>/data/x11vnc.log 2>&1 || true; sleep 2; done) & echo $! >/data/x11vnc.pid; exec python3 /opt/avatar/app.py"]
