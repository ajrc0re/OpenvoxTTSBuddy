# OpenVox TTS Buddy

A small native macOS app (SwiftUI) for pasting text and having an
[OpenVox](https://openvoxai.com) server on your local network read it aloud,
using the [OpenVox local API](https://openvoxai.com/support#local-api).

- Paste text (or press **⇧⌘V** to paste and speak in one go), then **Speak** (**⌘↩**). **⌘.** stops.
- **Server URL**, defaulting to `http://192.168.1.3:18778`. The `/v1` suffix is added for you.
- **Model**, **Language** and **Voice** pickers filled from the server, plus a **Preload model** button that warms the model before your first request.
- **Stream audio?** on: playback starts as soon as the first chunk arrives.
- **Stream audio?** off, with a **When finished** dropdown:
  - **Play**: play/pause, position slider and volume slider.
  - **Save**: writes a `.wav` to a folder you choose (default `~/Music/OpenVox TTS`).
- **Save last clip…** saves whatever you heard last, streamed or not.
- **Text filters**: a list of regular expressions whose matches are stripped
  before speaking. **+** adds one, select and **−** (or Delete) removes, double-click
  edits, and each has an on/off checkbox. **Show filtered text** swaps the editor
  to the filtered version; turning it off brings the original back, unless you
  edited the filtered text in the meantime, in which case your edits stay.
- **Global hotkey** (default **⌃⌥T**, click the shortcut to record a new one):
  grabs whatever is selected in the front app and either **replaces** or
  **appends** to the text, optionally speaking it right away.
- **Clipboard hotkey** (default **⌃⌥V**): same idea, but pastes whatever is on
  the clipboard. It uses the same Replace/Append and "Speak right away"
  settings and doesn't need Accessibility access.

Built for macOS 26 (Tahoe) on Apple Silicon. It also runs on macOS 13 Ventura
and later, and the universal build runs on Intel Macs.

## Install

### Download a build

Every push builds a universal app in GitHub Actions. Open the latest
[Build workflow run](../../actions/workflows/build.yml), download the
**OpenVoxTTSBuddy** artifact, unzip it, and move **OpenVox TTS Buddy.app** to
Applications. The build is ad-hoc signed rather than notarized, so the first
time, clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/OpenVox TTS Buddy.app"
```

### Build it yourself

Needs Xcode 15 or later (Xcode 26 gives you the Tahoe look) or the matching
command line tools.

```sh
Scripts/build-app.sh                # Apple Silicon
UNIVERSAL=1 Scripts/build-app.sh    # Apple Silicon + Intel
open "build/OpenVox TTS Buddy.app"
```

The app icon lives in `Resources/AppIcon.icns`; `python3 Scripts/make-icon.py`
(needs Pillow) redraws it along with `Resources/AppIcon.png`.

To hack on it, `open Package.swift` in Xcode and run the `OpenVoxTTSBuddy` scheme.

On first connect macOS asks for **Local Network** access. Allow it. If you
denied it, turn it back on in System Settings › Privacy & Security › Local Network.

### Accessibility permission for the hotkey

Reading another app's selection needs **Accessibility** access. When you first
turn on the hotkey, macOS shows a prompt that takes you to System Settings ›
Privacy & Security › Accessibility; switch **OpenVox TTS Buddy** on there.

The app is ad-hoc signed, so macOS ties that permission to this exact build.
After installing a new build, remove the old entry with **−** in that list and
switch the new one on, or the hotkey silently won't grab anything.

The hotkey first asks the focused app for its selection through the
Accessibility API; apps that don't expose it (some browsers and Electron apps)
get a simulated ⌘C instead, and your clipboard is put back afterwards.

## Making the Windows OpenVox server reachable from your Mac

The OpenVox app only listens on loopback (`127.0.0.1`), and its Base URL field
is locked. The OpenVox docs say to keep it on loopback unless you need LAN
access, but they don't document a setting, config file, environment variable or
command line flag to change the bind address. The workaround is to forward a
LAN port to the loopback port on the Windows machine.

### Option 1: Windows port proxy (recommended)

Check the port shown in OpenVox's Local API settings (the docs use `8000`;
below assumes `18778`). Then, in **PowerShell as Administrator** on the Windows PC:

```powershell
# Forward 192.168.1.3:18778 (LAN) to 127.0.0.1:18778 (OpenVox)
netsh interface portproxy add v4tov4 listenaddress=192.168.1.3 listenport=18778 connectaddress=127.0.0.1 connectport=18778

# Allow the port through the firewall, only from your local subnet
New-NetFirewallRule -DisplayName "OpenVox TTS (LAN)" -Direction Inbound -Protocol TCP -LocalPort 18778 -RemoteAddress LocalSubnet -Profile Private -Action Allow

# Port proxy depends on the IP Helper service
Set-Service iphlpsvc -StartupType Automatic; Start-Service iphlpsvc

# Check it
netsh interface portproxy show all
```

Notes:

- Use the PC's LAN address as `listenaddress`, not `0.0.0.0`. OpenVox already
  holds `127.0.0.1:18778`, and a wildcard listener on the same port can clash with it.
- The Windows network should be set to **Private**, and the PC needs a fixed
  address (a DHCP reservation for 192.168.1.3 on your router works).
- The rule survives reboots. To remove it:
  `netsh interface portproxy delete v4tov4 listenaddress=192.168.1.3 listenport=18778`
- If OpenVox uses a different port (for example `8000`), keep `listenport=18778`
  and set `connectport=8000`.

Test from the Mac:

```sh
curl http://192.168.1.3:18778/v1/models
```

### Option 2: SSH tunnel

If you'd rather not open a port, enable **OpenSSH Server** on Windows
(Settings › System › Optional features), then on the Mac:

```sh
ssh -N -L 18778:127.0.0.1:18778 youruser@192.168.1.3
```

Keep that running and set the app's server URL to `http://127.0.0.1:18778`.

## How it talks to OpenVox

| Action | Request |
| --- | --- |
| Connect / Refresh | `GET /v1/models` |
| Preload model | `POST /v1/models/{model}/load` |
| Language list | `GET /v1/models/{model}/languages` |
| Voice list | `GET /v1/models/{model}/voices?language={code}` |
| Speak | `POST /v1/audio/speech` with `model`, `input`, `language`, `voice`, `response_format: "wav"`, `stream` |

Streaming responses are server-sent events (`response.created`, `audio.chunk`,
`response.completed`). Each `audio.chunk` carries base64 WAV data, which is
decoded and queued on an `AVAudioEngine` player as it arrives. A `429` means the
server is busy with another generation or preload, and the app tells you to retry.

The docs don't show the shape of the list responses, so the app accepts plain
string arrays, `{ "data": [...] }`-style wrappers, and objects with `id`/`name`
fields. If a list comes back empty, the picker turns into a text field so you
can type a model, language or voice by hand.
