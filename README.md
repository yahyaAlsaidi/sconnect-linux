# SConnect for Linux: Oman eID (PKI smart card) login

Installs the Gemalto/Thales SConnect native host that `idp.pki.ita.gov.om` needs for Oman national ID card login on Linux. The IdP's "update SConnect" flow is broken on Linux, and this script works around it.

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/yahyaAlsaidi/sconnect-linux/main/install-sconnect.sh
chmod +x install-sconnect.sh
./install-sconnect.sh
```

Then:

1. Install the **SConnect** browser extension, if the login page has not already asked you to:
   - Chrome, Brave, Chromium or Edge: Chrome Web Store ID `mjhbkkaddmmnkghdnnmkjcgpphnopnfk`.
   - Firefox: `https://www.sconnect.com/extensions/sconnect-ff-v2.16.1.0.xpi`.
2. **Fully restart the browser.** The extension caches the old host version per tab.
3. Plug in the card reader, insert the ID card and open the login page.

Run it as your normal user, not root. It installs into `$HOME` and uses `sudo` only for system packages. The script is safe to re-run.

## How the page works

```
Web page (sconnect.js, pcsc.js)
  -> SConnect browser extension
    -> native messaging host  ~/.sconnect/sconnect_host_linux   (com.gemalto.sconnect)
      -> PC/SC add-on (downloaded from the IdP on first use)
        -> pcscd -> card reader -> ID card
```

## Why login fails on Linux

1. **The host version is too old.** The page requires host `2.16.1.0` (`SConnect._expVersion = 0x02100100`). `sconnect.js` uses `min(extension, host)`. The current extension (`2.16.1.2`) also rejects older hosts with error `-99`, so an older host triggers the "update SConnect" flow.
2. **The update flow dead-ends.** The page downloads from the IdP's own mirror (`/sconnectrepo/extensions/`), which only has the Windows build:

   | File | IdP mirror | Vendor (`www.sconnect.com/extensions/`) |
   |---|---|---|
   | `sconnect-host-v2.16.1.0.exe` (Windows) | 200 | |
   | `sconnect-host-v2.16.1.0.pkg` (macOS) | **404** | |
   | `sconnect-host-v2.16.1.0.tar.gz` (Linux) | **404** | 200 |
   | `sconnect-ff-v2.16.1.0.xpi` (Firefox) | 200 | 200 |

3. **The vendor's install script is limited.** It hardcodes `/home/$USER` and only registers Google Chrome, so Brave, Chromium and Edge never find the host.

## What the script does

1. Refuses to run as root, or on anything other than x86_64. The vendor only ships an x86_64 host.
2. Installs any missing system packages, and does nothing if they are already present:

   | Distro | Packages |
   |---|---|
   | Debian / Ubuntu / Zorin / Mint (apt) | `pcscd libccid libpcsclite1 curl python3` |
   | Fedora / RHEL (dnf) | `pcsc-lite pcsc-lite-ccid pcsc-lite-libs curl python3` |
   | Arch (pacman) | `pcsclite ccid curl python` |
   | openSUSE (zypper) | `pcsc-lite pcsc-ccid libpcsclite1 curl python3` |

   Why each package is needed:
   - `pcscd` is the smart-card daemon, and the CCID package is the USB reader driver.
   - `libpcsclite.so.1` is linked by the SConnect PC/SC add-on.
   - `curl` and `python3` are used by the script. `curl` also pulls in OpenSSL, which the host loads at runtime (`libssl`/`libcrypto` 1.0, 1.1 or 3).
   - The host's remaining dependencies (`libstdc++`, `libgcc_s`, `libc`) are present on every distro above.
3. Enables `pcscd.socket` if neither the socket nor the service is active.
4. Downloads `sconnect-host-v2.16.1.0.tar.gz` from the vendor and verifies its SHA-256 (`9c711faee11c193a667ff8be01948eb4f70d9a10b043aa61172bc2bbbcddeef6`).
5. Installs the host to `~/.sconnect/sconnect_host_linux`, and backs up any different existing binary to `sconnect_host_linux.bak`.
6. Registers the native-messaging manifest for every browser profile it finds: Google Chrome, Chrome Beta, Chromium, Brave, Edge and Firefox.
7. Runs a self-check. It sends the host the same `Create` and `GetVersion` handshake the extension uses, and asserts the reported version is at least `0x02100100`.

Expected output:

```
registered: google-chrome
registered: firefox
OK: host 0x02100100 responds
```

A browser is only registered if its profile directory already exists. If you install a browser later, re-run the script.

## Tested

The script was tested in clean containers for Ubuntu 24.04, Debian 12, Fedora 41, Arch and openSUSE Tumbleweed. On each one, the first run installed all packages and passed the self-check, `ldd` reported no missing libraries, and the second run was a no-op.

On a real machine (Zorin OS 18.1, Chrome, Alcor Link AK9563 reader), the self-check passes, and the card ATR `3B7A9700008065B08520040272D641` matches the page's `iasv5oman` profile.

## Rollback

```bash
mv ~/.sconnect/sconnect_host_linux.bak ~/.sconnect/sconnect_host_linux
```

Uninstall:

```bash
rm -rf ~/.sconnect ~/.config/*/NativeMessagingHosts/com.gemalto.sconnect.json \
  ~/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.gemalto.sconnect.json \
  ~/.mozilla/native-messaging-hosts/com.gemalto.sconnect.json
```

## Proper fix (ITA / MTCIT PKI team)

Host `sconnect-host-v2.16.1.0.tar.gz` (Linux) and `.pkg` (macOS) under `idp.pki.ita.gov.om/sconnectrepo/extensions/`, or stop overriding the SConnect download path to the mirror.
