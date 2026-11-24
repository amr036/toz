# NetPulse Router Manager

A Flutter (Material 3, dark-by-default, Arabic RTL / English LTR) Android app for managing a home router.
It focuses on **internet usage tracking (حساب الاستهلاك)** and **Wi-Fi speed control (التحكم في سرعة الواي فاي)**.

* Primary target: **ZYXEL VMG3625-T50B** at `192.168.1.1`.
* **Demo mode is on by default.** A simulated router lets the whole UI run in cloud previews and Flutter Web, where your router can't be reached.
* All router traffic stays on the LAN. Credentials are stored with `flutter_secure_storage` and are only sent to the configured gateway.

---

## Features

| Area | What you get |
|---|---|
| **Login & drivers** | `RouterDriver` interface; `MockRouterDriver` (simulation); `ZyxelVmg3625Driver` (session + CSRF token, cookie jar, auto-detection of the encrypted RSA/AES login on newer firmware, re-login on session loss) |
| **Dashboard** | Internet status, model, gateway IP, WAN IP, line type / DSL sync, uptime, live ↓/↑ rate with sparkline, cycle-usage mini bar, quick actions (**Reboot**, **Router admin page (WebView)**, **Sync now**) |
| **Usage & quota** | Delta-based counting that survives router reboots and 32-bit counter wraps. Includes a glitch filter, per-day ledger, ISP calibration, presets (140 / 250 / 500 GB / 1 TB / custom), renewal day, and an "include upload" switch. A 270° gauge shows used / remaining / %, daily average, projected total at renewal, days until the quota runs out, days until renewal, daily budget, a 7/30-day chart, and warnings at 75 / 90 / 100 % |
| **Wi-Fi control** | Speed presets (Unlimited, 2, 6, 10, 20 Mbps, or a custom 1–100 Mbps slider) with an Apply button and an "active" badge. SSID and password, max clients, transmit power, and DNS presets (ISP default, Cloudflare 1.1.1.1, Cloudflare Family, AdGuard Family, Google, custom) |
| **Devices** | Name, IP, MAC, band (2.4 GHz / 5 GHz / Ethernet), signal strength, online/offline |
| **Background sync** | Android WorkManager reads the router counters about every 15 minutes while the app is closed, so usage keeps counting and reboots aren't missed. It is skipped in demo mode and while the app itself is polling |
| **Per-device usage** | Each device's usage this billing cycle (GB, % of quota, share of all devices, today), from the router's per-device counters (`lanhosts` `X_ZYXEL_BytesSent` = downloaded, `X_ZYXEL_BytesReceived` = uploaded). Counter resets on reconnect or reboot are handled. Devices can be renamed in the app |
| **Cut a device's internet** | A switch per device. On ZYXEL this creates a Parental Control profile (`paren_ctl`) named `NP-<MAC tail>` with that MAC and an all-week 00:00–23:59 block window. Restoring deletes that profile; your own profiles are never touched |
| **Quota alerts** | Android notifications at 75 / 90 / 100 %, each sent once per billing cycle, from the app or the background job |

## Project structure

```
lib/
├── main.dart                     # ProviderScope + SharedPreferences bootstrap
├── app.dart                      # MaterialApp, locale/RTL, theme, setup⇄home gate
├── core/
│   ├── background/background_sync.dart   # WorkManager usage sync (Android)
│   ├── notifications/usage_alerts.dart   # 75/90/100 % notifications
│   ├── config/app_config.dart    # DEMO_MODE default, poll intervals, presets
│   ├── l10n/app_strings.dart     # AR/EN string table → context.tr('key')
│   ├── state/app_state.dart      # settings, router session, live polling (Riverpod)
│   ├── storage/secure_credentials_store.dart
│   ├── theme/app_theme.dart
│   ├── utils/formatters.dart
│   └── widgets/                  # app bar, cards, banners
├── drivers/
│   ├── router_driver.dart        # abstract RouterDriver
│   ├── router_models.dart        # RouterStatus, TrafficCounters, SpeedLimit, …
│   ├── driver_registry.dart      # model list + factory (add ZTE/Huawei here)
│   ├── mock/mock_router_driver.dart
│   └── zyxel/
│       ├── zyxel_vmg3625_driver.dart
│       ├── zyxel_endpoints.dart  # ← every URL / DAL oid, edit to match firmware
│       └── zyxel_crypto.dart     # RSA+AES codec for encrypted firmwares
└── features/
    ├── setup/                    # login / router setup
    ├── shell/                    # bottom navigation
    ├── dashboard/
    ├── usage/{domain,data,presentation}/   # UsageCalculatorService lives in domain/
    ├── wifi_control/
    ├── devices/
    └── admin/                    # WebView fallback to the router's admin page
test/                             # usage math + mock driver unit tests
```

---

## Running the app

Requirements: Flutter **stable 3.47 or newer** (the project uses the `material_ui` package, which replaced `package:flutter/material.dart`). Check with `flutter --version`.

> If you must use an older Flutter, replace `package:material_ui/material_ui.dart` with `package:flutter/material.dart` in `lib/` and remove `material_ui` from `pubspec.yaml`.

```bash
flutter pub get
flutter test                    # 44 tests (usage math, alerts, mock driver, ZYXEL driver vs. fake router, diagnostics)
```

### 1. Cloud IDE / web preview (demo mode)

```bash
flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0 --no-web-resources-cdn
```

`--no-web-resources-cdn` serves CanvasKit from the app instead of `www.gstatic.com`. Some cloud sandboxes block that CDN, which leaves a blank page.
The app starts connected to the simulated router: the live rate moves, applying **2 Mbps** visibly caps it, and **Reboot** resets the counters, which the usage tracker handles.
The demo login is `admin` / `demo`.

### 2. Android phone on your home Wi-Fi (real router)

1. On the phone, enable **Developer options → USB debugging** and connect it by USB (or use `adb pair` for wireless debugging).
2. Make sure the phone is on the **router's Wi-Fi**, not mobile data.
3. Run:
   ```bash
   flutter devices
   flutter run --release --dart-define=DEMO_MODE=false
   ```
   You can also run normally and turn off **Demo mode** on the setup screen (⚙ in the app bar).
4. Pick **ZYXEL VMG3625-T50B**, enter `192.168.1.1` and the admin username and password from the sticker on the router (often `admin` plus a unique password). Then tap **Connect**.
5. If it doesn't connect, tap **Test connection** on the same screen (see below).
6. Build an APK to install: `flutter build apk --release --dart-define=DEMO_MODE=false`. The file is at `build/app/outputs/flutter-apk/app-release.apk`.

Android notes:
* `AndroidManifest.xml` declares `INTERNET` and `POST_NOTIFICATIONS`. On Android 13+ the app asks for notification permission after the first connection.
* Core library desugaring is enabled in `android/app/build.gradle.kts`, as `flutter_local_notifications` requires.
* Background sync runs at most every 15 minutes (the Android minimum), and only when a network is available. Battery savers on some phones (Xiaomi, Huawei, Oppo) delay it; allow the app to run in the background in battery settings for the most accurate tracking.
* `res/xml/network_security_config.xml` allows cleartext HTTP. The router serves `http://192.168.1.1`, and the IP is user-configurable, so a per-domain rule isn't possible.
* Flutter Web can't talk to the real router because the browser blocks it with CORS. Use Android for real hardware.

---

## Verifying the ZYXEL VMG3625-T50B endpoints

The ZYXEL web UI is a JavaScript app that calls a JSON API, the "DAL". The driver uses the same calls.
Firmware builds name a few objects differently. All names live in `lib/drivers/zyxel/zyxel_endpoints.dart`, so you only edit that file.

### Step 1: Watch the router's own UI in DevTools

1. On a PC connected to the router, open Chrome at `http://192.168.1.1`.
2. Press **F12**, open the **Network** tab, tick **Preserve log**, and filter by `Fetch/XHR`.
3. Log in. You should see:
   * `GET /getRSAPublickKey`. If it returns `{"RSAPublicKey": "-----BEGIN PUBLIC KEY…"}`, your firmware **encrypts** payloads. The driver detects this automatically.
   * `POST /UserLogin`. The response holds `"result":"ZCFG_SUCCESS"` and `"sessionkey"`. Later requests carry the header `CSRFToken: <sessionkey>` and a `Session` cookie.
4. Open each page below and note the `oid=` in the request URL (`/cgi-bin/DAL?oid=…`):

| Router UI page | Driver method | Default in `ZyxelEndpoints` | Fields parsed (any of) |
|---|---|---|---|
| Home / Connection Status | `getRouterStatus()` | `statusOids: ['cardpage_status','status']` | `DeviceInfo.ModelName/SoftwareVersion/UpTime`, `DslChannelInfo[].DownstreamCurrRate/UpstreamCurrRate`, `WanLanInfo[].Status/IPAddress` |
| System Monitor → **Traffic Status** | `getTrafficCounters()` | `trafficOids: ['Traffic_Status','traffic_status','cardpage_status','status']` | any object with `BytesReceived` + `BytesSent` (WAN/ppp/ptm rows preferred) |
| Network Setting → Home Networking → **LAN Setup** (DNS values) | `getDns()` / `setDns()` | `lanDnsOid: 'lan'` | `DNSType`/`DNS_Type`, `DNSServer1/2` or `DNS_Servers1/2` |
| Network Setting → **Wireless** → General | `getWifiSettings()` / `updateWifiSettings()` | `wlanOid: 'wlan'` | `SSID`, `wpaPsk`/`KeyPassphrase`, `MaxAssociatedDevices`, `TransmitPower` |
| Network Setting → **QoS** → General / **Shaper** | `setWifiSpeedLimit()` | `qosOid: 'qos'`, `qosShaperOid: 'qos_shaper'` | `Enable`, `Interface`, `ShapingRate` (kbps) |
| System Monitor → **ARP / LAN hosts** (or Home → Connected devices) | `getConnectedDevices()` | `lanHostsOid: 'lanhosts'` | `HostName`, `IPAddress`, `PhysAddress`, `X_ZYXEL_ConnectionType`, `Active` |
| Maintenance → **Reboot** | `rebootRouter()` | `reboot: '/cgi-bin/Reboot'` | — |

5. Click a request and open the **Response** tab to see the exact field names.
   If your firmware is encrypted, responses look like `{"content":"…","iv":"…"}`. In that case, read the decoded objects from the **Console**: the page's JS keeps them in variables. You can also set a breakpoint in `util.js` after `AesDecrypt`.
6. When saving settings (Wi-Fi, QoS shaper, DNS), check the request method and **Payload**. The driver uses `PUT` to update existing rows and `POST` to create new ones.
   If yours differs, adjust `_dalWrite` or the field names in `zyxel_vmg3625_driver.dart`.

### Easiest: the in-app connection test

On the setup screen (⚙ in the app bar), turn **Demo mode** off, fill in IP / username / password, and tap **Test connection**.
It checks, in order: reaching the router → login (and whether the firmware uses the encrypted API or HTTPS) → status → traffic counters → devices → Wi-Fi → DNS → speed limit.
Each step shows ✓ / ⚠ / ✗ with the router's actual answer. **Copy report** puts a text report on the clipboard (it never contains the password); send it to the developer to adjust `zyxel_endpoints.dart` for your firmware.

The same protocol is covered by `test/zyxel_driver_test.dart`, which runs the driver against an in-process fake ZYXEL server (`test/fake_zyxel_server.dart`) in both encrypted and plain-JSON modes.

### Step 2: Quick check from a terminal (unencrypted firmware only)

```bash
# 1) Log in. The password is base64-encoded, as the web UI does it.
PASS_B64=$(printf '%s' 'YOUR_ROUTER_PASSWORD' | base64)
curl -s -c jar.txt -H 'Content-Type: application/json' \
  -d "{\"Input_Account\":\"admin\",\"Input_Passwd\":\"$PASS_B64\",\"currLang\":\"en\",\"RememberPassword\":0,\"SHA512_password\":false}" \
  http://192.168.1.1/UserLogin
# → {"result":"ZCFG_SUCCESS","sessionkey":"123456789", ...}

# 2) Read a DAL object with the cookie + CSRF token
curl -s -b jar.txt -H 'CSRFToken: 123456789' 'http://192.168.1.1/cgi-bin/DAL?oid=cardpage_status' | python3 -m json.tool | head -60
curl -s -b jar.txt -H 'CSRFToken: 123456789' 'http://192.168.1.1/cgi-bin/DAL?oid=lanhosts'
curl -s -b jar.txt -H 'CSRFToken: 123456789' 'http://192.168.1.1/cgi-bin/DAL?oid=qos_shaper'

# 3) Log out. ZYXEL allows only a few admin sessions at once.
curl -s -b jar.txt -X POST -H 'CSRFToken: 123456789' http://192.168.1.1/cgi-bin/UserLogout
```

If `/getRSAPublickKey` returns a key, plain `curl` won't work. Use DevTools as described above, or just run the app: it handles encryption in `zyxel_crypto.dart`.

### Step 3: Debug from the app

Run with `flutter run` and watch the console. Failures surface as `RouterException(notSupported: oid=… → <first 160 chars of response>)`. They also appear in the dashboard's error banner, so you can see which `oid` needs changing.

### About Wi-Fi speed limiting on the VMG3625-T50B

The firmware has no per-SSID bandwidth cap. The driver uses the **QoS Shaper** instead: it enables global QoS, then sets `ShapingRate` (kbps) on the shaper row whose interface matches `shaperInterfaceHints` (Wi-Fi/LAN side), or the first row.
* A shaper on the **WAN** interface limits **upload**.
* A shaper on the **LAN/WLAN** egress limits **download** to Wi-Fi clients.

Check which interfaces your firmware lists under QoS → Shaper. If the firmware rejects the call, the app reports it with method "Unsupported". You can then set it from **Router admin page** on the dashboard.

---

## Usage-calculation design (`UsageCalculatorService`)

* The router's WAN counters (`BytesReceived` / `BytesSent`) are cumulative **since the router booted**. Every poll stores the raw value and adds only the **delta** to a per-day ledger in SharedPreferences.
* **Router reboot:** when a counter goes backwards, the new raw value is the traffic since boot, and it gets added.
* **32-bit wrap:** if the previous value was near 2³² and the new one is small, the delta is `new + 2³² − old`.
* **Glitch filter:** a delta larger than a 1 Gbps link could carry in the elapsed time is discarded, and the counter is re-baselined.
* **Billing cycle:** the cycle total is the sum of the days inside it. Rollover and renewal-day changes need no special handling. Renewal day 29–31 is clamped in short months.
* **Calibration:** the offset needed to match your ISP portal's figure is stored for the current cycle only. Daily history is never rewritten.
* **App closed:** the background job keeps polling roughly every 15 minutes. Traffic in the gap between the last poll and a router reboot (at most ~15 minutes) can still be lost, so calibrate against the ISP portal occasionally.
* **Hand-over:** the app writes a heartbeat while it polls, the background job skips while that heartbeat is fresh, and the app reloads the ledger when it comes back to the foreground. That way only one side writes the ledger at a time.
* GB means 10⁹ bytes, as most ISPs bill. Change `bytesPerGb` in `usage_models.dart` if yours uses GiB.

## Adding another router (ZTE H188A, Huawei HG633 / DN8245, …)

1. Create `lib/drivers/<vendor>/<model>_driver.dart` that `extends RouterDriver`.
2. Add it to `createDriver()` in `driver_registry.dart` and set `available: true` in `routerModels`.
3. Report what the firmware can do through `capabilities`. The UI hides or adapts controls based on it.

## Security

* Credentials are stored with `flutter_secure_storage` (Android Keystore) and only sent to the configured gateway.
* No analytics, no external servers. The only outbound host is your router.
* Demo-mode usage history is kept separately from real history.
