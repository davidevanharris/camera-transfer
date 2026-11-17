# Camera Transfer

An iPhone app (Swift + SwiftUI, iOS 17+) that copies photos and videos (JPEG, RAW, video) over Wi-Fi from:

- **Ricoh GR IV**: the app wakes the camera's Wi-Fi over Bluetooth LE, joins that network, then downloads over HTTP.
- **Sony A7CR (ILCE-7CR)**: the camera's built-in *FTP Transfer* feature sends files to a small FTP server that runs inside the app.
- **OM System OM-3**: the app connects to the camera's own Wi-Fi network over HTTP.

The app **never asks for read access to your photo library**. Files go into the app's own Documents folder, which you can see in **Files > On My iPhone > Camera Transfer**. You can also add files to Photos, either one by one or automatically after each download. That uses *add-only* permission, so the app can add photos but can never see the ones already there.

There are no analytics, no accounts and no third-party code. The app makes no network requests except to your camera on the local network. Bluetooth is used only to switch on the Ricoh's Wi-Fi.

Optional **auto-transfer modes** send the full-size JPEG of each new shot straight to Photos (add-only) while both batteries are healthy (see below).

---

## Build and run

1. You need a Mac with **Xcode 16 or later**.
2. Open `CameraTransfer.xcodeproj`.
3. Select the **CameraTransfer** target > **Signing & Capabilities**:
   - Choose your **Team**. A free personal Apple ID works, but apps signed that way stop working after 7 days, so you have to rebuild and reinstall them. A paid developer account lasts a year.
   - The project carries the owner's team and the bundle identifier `com.davidharris.CameraTransfer`. Anyone else building it must choose their own Team and change the **Bundle Identifier** (and the Watch target's, which must start with the iPhone app's).
4. Connect your iPhone, select it as the run destination and press **Run** (Cmd-R).
   The first time, you may need to turn on **Developer Mode** on the iPhone (Settings > Privacy & Security > Developer Mode), and trust the developer certificate (Settings > General > VPN & Device Management).
5. Unit tests: choose an iPhone Simulator and press **Cmd-U**.

### Hotspot Configuration entitlement (automatic Wi-Fi joining)

The app asks iOS to join the Ricoh's Wi-Fi for you with `NEHotspotConfiguration`. That needs the **Hotspot Configuration** capability, which is declared in `CameraTransfer/CameraTransfer.entitlements` and wired up through `CODE_SIGN_ENTITLEMENTS`.

- With a paid developer account, Xcode's automatic signing should add the capability for you.
- With a **free personal team**, this capability may not be available (unverified). If signing fails with an error that mentions `com.apple.developer.networking.HotspotConfiguration`, remove it:
  1. Target **CameraTransfer** > **Signing & Capabilities**: delete the *Hotspot Configuration* capability if it is listed, **or**
  2. Build Settings: clear **Code Signing Entitlements** (`CODE_SIGN_ENTITLEMENTS`). You can also delete the key from `CameraTransfer.entitlements`. If you use XcodeGen, remove the `CODE_SIGN_ENTITLEMENTS` line from `project.yml`.

  The app still works without it. When automatic joining fails for any reason, it shows the network name and a **Copy password** button so you can join in Settings > Wi-Fi, then tap **Continue**.

### If the project does not open (XcodeGen fallback)

The `.xcodeproj` file was written by hand in the Xcode 16 "synchronized folders" format. If Xcode refuses to open it, you can regenerate it from `project.yml`:

```sh
brew install xcodegen
cd CameraTransfer        # the folder that contains project.yml
xcodegen                 # overwrites CameraTransfer.xcodeproj
```

You can also make a new iOS App project called `CameraTransfer` in Xcode (SwiftUI, Swift). Then drag the `CameraTransfer/Core` and `CameraTransfer/UI` folders and `CameraTransferApp.swift` into it, set *Info.plist File* to `CameraTransfer/Info.plist`, and set the deployment target to iOS 17.

---

## Using it

When the app first touches the network, iOS asks whether it may "find and connect to devices on your local network". Tap **Allow**, or nothing will work. You can change this later in Settings > Privacy & Security > Local Network.

### Ricoh GR IV

On stock firmware the GR IV's Wi-Fi cannot be started from the camera menu. A paired phone has to ask for it over Bluetooth LE, and this app does that.

**One-time pairing**
1. On the camera: MENU > **Wireless Communication** > **Action Mode** > On, then **Pairing** > **Execute**.
2. In the app, open **Cameras > Ricoh GR IV**, open *Bluetooth pairing*, tap **Find camera** and pick your GR IV. It is remembered.
3. Tap **Connect**. iOS shows a Bluetooth pairing request with a 6-digit code. Check that it matches the camera, then accept on both. The first connection can take about 15 seconds of retries.

**Every time**
1. Tap **Connect**. The app wakes the camera's Wi-Fi over Bluetooth and reads its network name and password. Then it joins the network (iOS asks you to confirm) and waits for the camera to answer. Finally it shows the model, firmware, battery and files, from both internal memory and the SD card.
2. If automatic joining is not possible (no entitlement, or the password came back unreadable/encrypted), the app shows the network name and a **Copy password** button. Join in Settings > Wi-Fi, come back and tap **Continue**.
3. Tap **Import N New** to bring in everything not yet imported, or tap individual photos and then **Import N Selected**. Files are saved to `Camera Transfer/Ricoh GR IV/<storage>/<camera folder>/`.
4. **Disconnect** (in the ... menu) ends the camera's Wi-Fi session (`/v1/device/wlan/finish`) and asks the camera over Bluetooth to switch Wi-Fi off.

**Connect without Bluetooth** skips the Bluetooth step if the phone is already on the camera's Wi-Fi, and is also how you test against the mock server. The debug log under **Details** shows every Bluetooth and network step, including any extra Wi-Fi characteristics the camera exposes.

The default camera address is `http://192.168.0.1`. You can change it in Settings.

### OM System OM-3

1. On the camera, start the smartphone Wi-Fi connection (MENU > Setup > Wi-Fi/Bluetooth settings). The camera shows its SSID and password. Choose the private / Wi-Fi option if it asks.
2. Join that network in **Settings > Wi-Fi** on the iPhone.
3. Open **Cameras > OM System OM-3**, tap **Connect**, then import as for the Ricoh.
4. Files are saved to `Camera Transfer/OM System OM-3/<camera folder>/`.

The default camera address is `http://192.168.0.10`. You can change it in Settings.

### Sony A7CR (FTP)

The A7CR does not serve files over HTTP. Instead, it *sends* files to an FTP server, and the app is that server. **Cameras > Sony A7CR** walks through the setup with the values to type and a checklist that shows how far the camera has got. The menu names below are from Sony's FTP Help Guide for the ILCE-7CR.

1. **Put the camera and iPhone on one network.** Either:
   - **Personal Hotspot:** on the iPhone open Settings > Personal Hotspot, switch on *Allow Others to Join* and stay on that screen until the camera has joined. On the camera: MENU > Network > Wi-Fi > Access Point Set., choose the iPhone and enter the hotspot password. Or
   - **Same Wi-Fi:** join both to the same router. Guest and public networks often block devices from talking to each other.
2. **Tell the camera where to send.** On the camera: MENU > Network > FTP Transfer > FTP Transfer Func. > Server Setting > Server 1:
   - Destination Settings > **Host Name**: the address the app shows. On Personal Hotspot it is usually `172.20.10.1`.
   - Destination Settings > **Secure Protocol**: Off
   - Destination Settings > **Port**: 2121 (or whatever the app shows)
   - User Info Settings > **User** / **Password**: as shown in the app (a random password is created on first launch)
   - **Passive Mode**: On
   - Directory Settings > Specify Directory: leave empty
3. **Switch on FTP.** In the app tap **Start receiving**. On the camera: FTP Transfer Func. > **FTP Function** > On. An FTP icon appears on the camera when it has connected.
4. **Send photos.** On the camera: FTP Transfer Func. > **FTP Transfer**. Choose a Target Group (This Date, This Media ...) and Transfer Status *Only Non-transfer*, then OK. **Auto FTP Transfer** sends each shot as you take it.
5. **Keep the app open in the foreground** while files transfer. iOS suspends background apps, and that stops the server. The screen does not auto-lock while receiving is on.
6. Received files appear in the Library tab and in `Camera Transfer/Sony A7CR/`.

**If it does not work:** the app's checklist ("How far it has got") shows the first step that failed, and *It is not working* has a self-test and the usual causes. On the camera, FTP Transfer Func. > **Display FTP Error Info.** shows the camera's own error.

### Live view and remote shutter (all three cameras, experimental)

**Cameras > Live view and remote shutter** shows what the camera sees and a shutter button. The same screen serves all three cameras; **How to set up the camera** on that screen lists the steps for each, and **Troubleshooting log** records every step (with a Copy button). None of this has been confirmed on the real cameras yet.

| Camera | Picture | Shutter | What the camera needs |
|---|---|---|---|
| Sony A7CR | PTP/IP "PC Remote" over Wi-Fi (port 15740), live-view object `0xFFFFC002` | `ControlDevice` half-press `0xD2C1`, full press `0xD2C2` | Same network as the iPhone; **Access Authen. Off**; **PC Remote On**; **Still Img. Save Dest. = Camera Only**; **Pairing** once |
| Ricoh GR IV | `GET /v1/liveview` (Motion JPEG) over the camera's Wi-Fi | Bluetooth: `0x00` to Shooting Flavor, then `01 01` to Operation Request; falls back to `POST /v1/camera/shoot` | Connected in the app first (Bluetooth + its Wi-Fi), shooting mode |
| OM System OM-3 | `switch_cammode rec`, `exec_takemisc startliveview` (RTP over UDP 40000) | `exec_takemotion newstarttake` | iPhone joined to the camera's Wi-Fi |

Notes:

- **Sony:** with Access Authen. on, the camera expects an encrypted (SSH) session, which this app does not implement. Sony's own note is that with it off, remote control on that network is not password-protected or encrypted, so use your own hotspot or home Wi-Fi. The app finds the camera by the address it last sent photos from, then by searching the network; you can type the address under Settings > Advanced. The protocol details come from open-source projects tested on other Alpha bodies (A7C), not the A7CR. Sending photos by FTP while PC Remote is on is untested.
- **Ricoh:** the Bluetooth shutter and `/v1/liveview` are reported working on the GR IV by a community project; the app's own implementation is untested.
- Live view runs only while the app is on screen. iOS stops the camera connection soon after the app goes to the background.

### Apple Watch remote

The **CameraTransferWatch** target is a small Watch app: pick a camera, see its live picture (about 4 pictures a second), press **Shutter**. The Watch does not talk to the camera. It sends commands to the iPhone app over WatchConnectivity and the iPhone app talks to the camera, so **Camera Transfer must be open on the iPhone**.

To install it: in Xcode choose the **CameraTransferWatch** scheme, pick your Apple Watch as the destination and press Run. The Watch needs **Developer Mode** (Watch: Settings > Privacy & Security > Developer Mode) and must be paired with an iPhone that Xcode can see. The Watch app is deliberately **not embedded** in the iPhone app, so a missing or unregistered Watch can never stop the iPhone app from building. With a free Apple ID it expires after 7 days, like the iPhone app. It has not been run on a Watch yet.

### Auto-transfer modes

Pick a mode in Settings, or under **Details** on a camera's screen:

| Mode | Auto-transfer runs while |
| --- | --- |
| Off (the default) | never (auto-transfer off) |
| Default | phone **and** camera battery are both above 75% |
| Battery saver | both above 90% |
| Gonna charge soon | both above 25% |

Thresholds are strictly "above": at exactly 75% Default pauses. A phone that is charging always passes the phone check. In the Simulator the phone battery is unknown, which is allowed. The app always shows why it is running or paused, e.g. "Paused: phone at 62%, Default mode needs above 75%."

- **What is sent:** only the full-size JPEG of each new shot (no RAW, no video). It goes straight into Photos with add-only access, which the app asks for when you first pick an auto mode.
- **Keep a copy in the app folder** (Settings, off by default): when off, the app's own copy is deleted once it is safely in Photos. If adding to Photos fails, the file is kept and the error is shown.
- **Only new shots:** when you switch an auto mode on, the next listing records what is already on the card. Those files are never auto-imported.
- **Ricoh:** when the camera is switched on (Bluetooth notification) or the app comes to the foreground, the app wakes Wi-Fi, joins, then checks for new JPEGs every 3 seconds. Camera battery comes from `/v1/props` or the Bluetooth battery service.
- **OM-3:** join the camera's Wi-Fi manually. The app then polls the same way. The OM-3's battery cannot be read, so **Allow when camera battery is unknown** (Settings, on by default) decides.
- **Sony:** with an auto mode on, each JPEG the camera sends over FTP is added to Photos. Only the phone battery is checked. When it is too low, the FTP server stops and restarts by itself when the battery allows again. On the camera, turn on **Auto FTP Transfer** and set the transfer target to **JPEG only**.
- **Background limits:** iOS does not let this run hands-off in the background. A file in progress can finish briefly after you leave the app, but iOS drops the camera Wi-Fi about a minute after the app leaves the foreground, and the FTP server stops too. Keep the app open while transferring.

### Library tab

- One grid of everything imported from all three cameras, newest first and grouped by the day it was imported. The filter button (top left) narrows it to one camera or one kind of file.
- Thumbnails come from ImageIO, which uses the JPEG previews embedded in DNG, ARW and ORF files.
- Tap a photo to view it full screen and swipe between photos. Long-press for **Share**, **Add to Photos** and **Delete**.
- Tap **Select** to share, add to Photos or delete several at once. If you add a JPEG and a RAW with the same name together, Photos stores them as a single RAW+JPEG item.

### Settings

- The main screen has the auto-transfer mode and the *Also add imports to Photos* switch.
- **Advanced** has camera addresses, FTP port, user name and password.
- "After download, also add to Photos (add-only)".
- Auto-transfer mode, "Allow when camera battery is unknown" and "Keep a copy in the app folder".
- "Forget download history", so that every file shows as *new* again.
- A Privacy section explaining what the app can and cannot access.

---

## Testing without cameras (Simulator)

`tools/mock_cameras.py` imitates both HTTP cameras. It uses only the Python standard library.

```sh
python3 tools/mock_cameras.py                 # Ricoh on :8001, OM System on :8002
python3 tools/mock_cameras.py --big-mb 20     # big files, served slowly, to watch progress bars
```

In the Simulator, open the app's Settings and set the Ricoh address to `http://localhost:8001` and the OM-3 address to `http://localhost:8002`. Then use **Connect without Bluetooth** on the GR IV tab (the Simulator has no Bluetooth) or **Connect** on the OM-3 tab. The Ricoh mock reports firmware 1.11, a battery level (`--battery 60` to test the policy) and two storages (`in` and `sd1`, with the same filename in both). Use `--add-every 10` to make a new JPEG appear every 10 seconds, to watch auto-transfer. To test from a real iPhone on the same Wi-Fi as your Mac, start the script with `--host 0.0.0.0` and use `http://<your-mac-ip>:8001`.

`tools/ftp_push_test.py` imitates the Sony camera pushing files. Start the FTP server in the app first, then run:

```sh
python3 tools/ftp_push_test.py --host <address shown in app> --port 2121 --password <password>
python3 tools/ftp_push_test.py --host ... --password ... --active   # active (PORT) mode
```

In the Simulator, use `--host 127.0.0.1`. The script uploads a test file and checks SIZE, LIST, rename, delete and that `..` path traversal is refused. It exits non-zero if any check fails. Note that Python's ftplib connects to the control-connection host and ignores the address in the PASV reply. The camera does use that address, so a camera test is still needed.

---

## Status and known unknowns

Please read this before relying on the app.

- **It compiles and its unit tests pass** (GitHub Actions, Xcode 16.4, and Xcode 27.2 on the Mac), and it has been installed on two iPhones. **It has not yet worked against a real camera.** Every camera-facing part is untested on hardware until noted here.
- **Live view, remote shutter and the Watch app are untested** on every camera (see the table above for where each protocol comes from).
- **The GR IV Bluetooth wake-up flow comes from third-party reverse engineering on firmware 1.11.** That covers the service and characteristic UUIDs and the "write 0x01 to start the access point" behaviour. Firmware 1.20 changed wireless behaviour and is **untested**. Pairing behaviour (when iOS shows the code, how many retries it takes) is also unconfirmed.
- **The GR IV Wi-Fi passphrase may not be readable as plain text** over Bluetooth (it may come back encrypted). The app detects this and falls back to manual joining. You then need the password from the camera.
- **The GR IV HTTP API (/v1) is reported to exist on firmware 1.11.** Some details are assumptions and are marked as such in the code: `storages[]` in `/v1/props`, `?storageId=` on file URLs (the app falls back to no parameter on 404), the battery and firmware key names, and `/v1/device/wlan/finish`.
- **The OM-3 endpoints are assumed** from older Olympus bodies and the OM-1 and are unconfirmed on the OM-3. The OM-3 may need its Wi-Fi started from its smartphone-connection menu.
- **Camera battery readings:** not available for the OM-3 or for the Sony over FTP. The Ricoh battery reading (from `/v1/props` or the Bluetooth battery service) is unconfirmed.
- **Sony FTP is the documented route**, but the app's FTP server has not been tested with the real camera.
- **Hands-off background operation is limited by iOS:** see "Background limits" above. The Bluetooth background mode only helps notice the Ricoh being switched on, not keep transfers running.
- **Automatic Wi-Fi joining** needs the Hotspot Configuration entitlement, which may not be available with a free Apple ID (see above).
- RAW support in Photos depends on iOS. A very new body's ARW/ORF may not preview in Photos until Apple adds support. The files are still saved in Files.

## Troubleshooting

| Symptom | Things to try |
| --- | --- |
| "Could not reach the camera" | Check the iPhone is still on the camera's Wi-Fi. iOS sometimes switches back to a known network with internet, so turn off Auto-Join for your home network while transferring. Check **Settings > Privacy & Security > Local Network > Camera Transfer** is on. Check the camera address in the app's Settings. |
| Connect works but the list is empty | The Ricoh/OM API may be different on this body (see above). Make sure the camera is in playback / transfer mode and a card is inserted. |
| Thumbnails missing for videos or RAW | Some cameras only make thumbnails for JPEGs. Downloads still work. |
| Sony: camera says it cannot connect to the server | Check the host IP the app shows (on Personal Hotspot, use the `172.20.10.x` address). Check the port, user and password. Passive Mode must be **On** and Secure Protocol **Off**. Keep the app open with the server on. Tap "Refresh addresses" after changing networks. |
| Sony: connects but transfer fails | Make sure the iPhone has free storage. Stop and restart the server. Try the `ftp_push_test.py` script from a Mac to check the server. |
| No "Allow local network" prompt appeared | Delete and reinstall the app, or check Settings > Privacy & Security > Local Network. |
| App stopped launching after a week | It was signed with a free Apple ID. Rebuild from Xcode. |
| Xcode will not open the project | Use the XcodeGen fallback above. |
| Signing error about HotspotConfiguration | Remove the entitlement (see "Hotspot Configuration entitlement" above); join the camera Wi-Fi manually. |
| GR IV: "No Ricoh camera was found" | Make sure Action Mode is On, pairing was executed on the camera, Bluetooth is on and allowed for the app (Settings > Privacy & Security > Bluetooth). Tap Find camera and pick it from the list. |
| GR IV: stuck at "Waiting for pairing" | Accept the iOS pairing prompt and confirm on the camera. If it was paired before, remove the camera in iOS Settings > Bluetooth, tap Forget in the app, and pair again. |
| GR IV: Wi-Fi name/password unreadable | Firmware may encrypt them. Join manually using the camera's Wi-Fi information. Send the debug log to the developer. |
| Auto-transfer never starts | Check the reason shown under the mode picker (battery thresholds). Keep the app in the foreground. Ricoh: a camera must be selected in Bluetooth pairing. OM-3: join its Wi-Fi first. |

## Project layout

```
CameraTransfer.xcodeproj/     Hand-written Xcode 16 project (synchronized folders)
project.yml                   XcodeGen fallback
CameraTransfer/
  CameraTransferApp.swift
  Info.plist
  CameraTransfer.entitlements Hotspot Configuration (automatic Wi-Fi joining)
  Core/                       Models, camera clients, parsers, Ricoh Bluetooth, Wi-Fi joining,
                              transfer policy + auto-transfer, FTP server, storage, Photos export,
                              remote control (PTP/IP for Sony, MJPEG for Ricoh, RTP for OM-3), Watch link
  UI/                         SwiftUI views and view models
CameraTransferTests/          XCTest: parsers, FTP session, transfer policy, BLE decoding, file kinds, storage,
                              PTP/IP packets, live-view frame assembly
CameraTransferWatch/          Apple Watch app (own scheme, not embedded in the iPhone app)
tools/mock_cameras.py         Fake Ricoh + OM System HTTP cameras
tools/ftp_push_test.py        Fake Sony FTP client
```
