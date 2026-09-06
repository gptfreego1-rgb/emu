FROM eclipse-temurin:17-jre-jammy

ENV DISPLAY=:99 \
    PORT=8080 \
    DATA_DIR=/data \
    MALLOC_ARENA_MAX=2 \
    JAVA_TOOL_OPTIONS="-Djava.awt.headless=false"

RUN apt-get update && apt-get install -y --no-install-recommends \
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

# Avatar
RUN curl -L --fail --retry 3 \
    -o /opt/avatar/avatar.jar \
    https://files.catbox.moe/sllphh.ja

# MicroEmulator
RUN curl -L --fail --retry 3 \
    -o /tmp/microemulator.zip \
    'https://sourceforge.net/projects/microemulator/files/microemulator/2.0.4/microemulator-2.0.4.zip/download' \
    && unzip -q /tmp/microemulator.zip -d /tmp \
    && cp /tmp/microemulator-2.0.4/microemulator.jar \
       /opt/avatar/microemulator.jar \
    && cp /tmp/microemulator-2.0.4/devices/microemu-device-resizable.jar \
       /opt/avatar/microemu-device-resizable.jar \
    && rm -rf /tmp/microemulator.zip \
              /tmp/microemulator-2.0.4

WORKDIR /opt/avatar

CMD ["sh", "-c", "\
set -eu; \
mkdir -p /data; \
echo '================================'; \
echo ' Avatar FreeJ2ME'; \
echo '================================'; \
echo 'Starting Xvfb...'; \
Xvfb :99 \
    -screen 0 393x700x24 \
    -ac \
    +extension GLX \
    >/data/xvfb.log 2>&1 & \
for i in $(seq 1 20); do \
    xdpyinfo -display :99 >/dev/null 2>&1 && break; \
    sleep 1; \
done; \
if ! xdpyinfo -display :99 >/dev/null 2>&1; then \
    echo 'Xvfb gagal'; \
    cat /data/xvfb.log; \
    exit 1; \
fi; \
echo 'Xvfb OK'; \
if [ ! -s /data/vnc.pass ]; then \
    x11vnc -storepasswd \
        \"${VNC_PASSWORD:-123456}\" \
        /data/vnc.pass \
        >/dev/null 2>&1 || true; \
fi; \
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
echo 'VNC started'; \
echo 'Starting Web Panel...'; \
exec python3 /opt/avatar/app.py \
"]
