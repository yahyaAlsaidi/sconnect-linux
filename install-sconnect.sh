#!/usr/bin/env bash
# Installs the Gemalto SConnect native host required by idp.pki.ita.gov.om (Oman eID login).
# The IdP's own mirror only serves the Windows .exe (Linux .tar.gz is 404), so the page's
# "update SConnect" flow dead-ends on Linux. This pulls the vendor's Linux build instead.
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user (installs into \$HOME); it uses sudo for packages." >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "SConnect host is only built for x86_64." >&2; exit 1; }

# Dependencies: pcscd (daemon), CCID reader driver, libpcsclite.so.1 (linked by the SConnect PC/SC add-on),
# curl + python3 for this script. curl also pulls in libssl/libcrypto, which the host dlopens.
PKGS=""
if command -v apt-get >/dev/null; then
  PKGS="pcscd libccid libpcsclite1 curl python3"
  has() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }
  inst() { sudo apt-get update && sudo apt-get install -y "$@"; }
elif command -v dnf >/dev/null; then
  PKGS="pcsc-lite pcsc-lite-ccid pcsc-lite-libs curl python3"
  has() { rpm -q --whatprovides "$1" >/dev/null 2>&1; }
  inst() { sudo dnf install -y "$@"; }
elif command -v pacman >/dev/null; then
  PKGS="pcsclite ccid curl python"
  has() { pacman -Qi "$1" >/dev/null 2>&1; }
  inst() { sudo pacman -S --needed --noconfirm "$@"; }
elif command -v zypper >/dev/null; then
  PKGS="pcsc-lite pcsc-ccid libpcsclite1 curl python3"
  has() { rpm -q --whatprovides "$1" >/dev/null 2>&1; }
  inst() { sudo zypper --non-interactive install "$@"; }
else
  echo "WARN: unknown package manager; install pcscd, a CCID driver, libpcsclite.so.1, curl and python3 manually." >&2
fi
missing=$(for p in $PKGS; do has "$p" || echo "$p"; done | xargs)
if [ -n "$missing" ]; then
  echo "installing missing packages: $missing"
  inst $missing
fi
systemctl is-active --quiet pcscd.socket || systemctl is-active --quiet pcscd || sudo systemctl enable --now pcscd.socket

VER=2.16.1.0
URL=https://www.sconnect.com/extensions/sconnect-host-v$VER.tar.gz
SHA256=9c711faee11c193a667ff8be01948eb4f70d9a10b043aa61172bc2bbbcddeef6
HOST="$HOME/.sconnect/sconnect_host_linux"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/host.tgz"
echo "$SHA256  $tmp/host.tgz" | sha256sum -c --quiet
tar xzf "$tmp/host.tgz" -C "$tmp"

if cmp -s "$tmp/sconnect_host_linux" "$HOST"; then
  echo "host $VER already installed"
else
  pkill -f "^$HOST" || true
  mkdir -p "${HOST%/*}"
  [ -f "$HOST" ] && cp -p "$HOST" "$HOST.bak"
  install -m755 "$tmp/sconnect_host_linux" "$HOST"
fi

# Vendor script hardcodes /home/$USER and only registers google-chrome; cover every Chromium-family profile present.
for d in google-chrome google-chrome-beta chromium BraveSoftware/Brave-Browser microsoft-edge; do
  [ -d "$HOME/.config/$d" ] || continue
  mkdir -p "$HOME/.config/$d/NativeMessagingHosts"
  sed "s#/home/<<<user>>>/.sconnect/sconnect_host_linux#$HOST#" "$tmp/com.gemalto.sconnect.json" \
    > "$HOME/.config/$d/NativeMessagingHosts/com.gemalto.sconnect.json"
  echo "registered: $d"
done
if [ -d "$HOME/.mozilla" ]; then
  mkdir -p "$HOME/.mozilla/native-messaging-hosts"
  sed "s#/home/<<<user>>>/.sconnect/sconnect_host_linux#$HOST#" "$tmp/com.gemalto.sconnect-ff.json" \
    > "$HOME/.mozilla/native-messaging-hosts/com.gemalto.sconnect.json"
  echo "registered: firefox"
fi

# Self-check: talk to the host the way the extension does; it must report >= 2.16.1.0 or the extension/page reject it.
python3 -I - "$HOST" <<'EOF'
import json, struct, subprocess, sys
p = subprocess.Popen([sys.argv[1], "chrome-extension://mjhbkkaddmmnkghdnnmkjcgpphnopnfk/"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
for m in ({"type": "SConnect-I", "command": "Create", "url": "https://idp.pki.ita.gov.om/", "version": "0x02100102"},
          {"type": "SConnect", "command": "GetVersion", "callbackId": "_chk", "portId": "_chk_"}):
    b = json.dumps(m).encode(); p.stdin.write(struct.pack("<I", len(b)) + b); p.stdin.flush()
while True:
    r = json.loads(p.stdout.read(struct.unpack("<I", p.stdout.read(4))[0]))
    if r.get("callbackId") == "_chk": break
p.kill()
v = int(r["response"][0], 16)
assert v >= 0x02100100, f"host too old: {r['response'][0]}"
print(f"OK: host {r['response'][0]} responds")
EOF
