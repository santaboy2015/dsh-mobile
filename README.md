# DSH Mobile

Reach a [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) workspace from an
Android phone — same sessions, same files, same running agent, from anywhere your
tailnet reaches.

Bring your own machine, your own tailnet, your own token. Nothing here talks to
a server operated by anyone else.

| Piece | What it is |
|---|---|
| `android/` + `build.ps1` | A WebView client that does the token exchange, persists the session cookie, and adds the native bits a bare browser lacks |
| `dsh-tailnet.patch.yml` | A DSH profile patch overlay that binds the web server to every interface, which puts your Tailscale address into the connection plugin's trust fence |

No VPS. No port forwarding. No public exposure. Tailscale is the transport.

---

## Why a patch and not a flag

`dsh web --host 0.0.0.0` is refused upstream on purpose:

```
error: --host 0.0.0.0 is intentionally not supported yet for safety:
it would expose remote code execution to the network; use 127.0.0.1 instead
```

That guard is correct. **DSH runs shell commands; a bound DSH is a shell.** The
patch overlay is a deliberate override of that guard, and it is only defensible
because of the firewall rule in Step 1 — which pins the port to the Tailscale
interface and leaves it dark on Wi-Fi, Ethernet, and every other adapter.

If you take one thing from this README: **the firewall rule is not optional.**
Applying the overlay without it does not give you a phone client, it gives your
local network a shell.

> **Prefer not to depend on a firewall rule at all?** See
> [TAILSCALE-BINDINGS.md](TAILSCALE-BINDINGS.md) for the loopback + MagicDNS
> variant. It keeps DSH on `127.0.0.1` so the server itself enforces the
> boundary, and connects by a stable hostname instead of a tailnet IP that can
> change. It is the stricter of the two.

---

## Step 1 — Desktop: the firewall rule first

Before starting anything, scope the port to Tailscale. On Windows, in an
**administrator** PowerShell:

```powershell
New-NetFirewallRule -DisplayName "DSH Web (Tailscale only)" `
  -Direction Inbound -Protocol TCP -LocalPort 3080 -Action Allow `
  -InterfaceAlias "Tailscale" -Profile Any
```

Check what you got:

```powershell
Get-NetFirewallRule -DisplayName "DSH Web (Tailscale only)" |
  Get-NetFirewallPortFilter | Select-Object Protocol, LocalPort
```

Expected: `TCP`, `3080`. Windows Firewall blocks inbound by default, so with
`InterfaceAlias` pinned, no other adapter has a path in.

On Linux, the equivalent is an `nftables`/`ufw` rule bound to the `tailscale0`
interface. The shape is the same: allow the port **on that interface only**.

To undo it later:

```powershell
Remove-NetFirewallRule -DisplayName "DSH Web (Tailscale only)"
```

## Step 2 — Desktop: start DSH with the overlay

```powershell
dsh web --patch .\dsh-tailnet.patch.yml --no-open
```

Wait for the URL line:

```
dsh web: http://127.0.0.1:3080/?token=XXXXXXXX (LAN: http://100.x.y.z:3080/?token=XXXXXXXX)
```

**Copy the `LAN:` URL.** That is the one the phone needs. It carries the
process-lifetime auth token, which changes on every restart.

<details>
<summary>Already running the desktop app? Use port 3081 instead.</summary>

The DeepSeek Harness desktop app holds 3080 on `127.0.0.1` and cannot be
patched — its profile is managed exclusively by the Electron shell — so a second
instance on 3080 will fail to bind. `dsh-tailnet-3081.patch.yml` runs alongside
it:

```
3080  desktop app    -> your PC's browser, 127.0.0.1 only
3081  this instance  -> your phone, over Tailscale
```

Whichever instance loses the race for the `dsh-stream-market` port (18899) logs
a repeating "port occupied, retrying" warning. The web UI boots and works
normally in both; only that plugin degrades. Harmless, just noisy.

> **⚠ Before you start the 3081 instance: the firewall rule has to cover 3081.**
> The Step 1 rule allows **3080 only**. A patched instance bound to `0.0.0.0` on
> 3081, behind a rule that only names 3080, is exactly the misconfiguration this
> design exists to prevent — the port is bound and nothing is filtering it.
> Add a second rule for 3081, keeping the Tailscale interface scope:
>
> ```powershell
> New-NetFirewallRule -DisplayName "DSH Web 3081 (Tailscale only)" `
>   -Direction Inbound -Protocol TCP -LocalPort 3081 -Action Allow `
>   -InterfaceAlias "Tailscale" -Profile Any
> ```
>
> Run this **before** the 3081 instance, not after. Two rules, two ports, both
> scoped to Tailscale — that is the correct end state.

</details>

## Step 3 — Phone: Tailscale, then the app

**Tailscale on Android**, logged into the same tailnet as the desktop. Confirm
the phone can ping the desktop's tailnet address (`tailscale ip -4` on the
desktop tells you what it is).

**Install the APK.** Build it (Step 4), or download `DSH-Mobile.apk` from this
repository's **Releases** page — the APK is a build artifact and deliberately
not tracked in the tree.

```powershell
adb install -r .\DSH-Mobile.apk
```

Or copy `DSH-Mobile.apk` to the phone and open it. Android will ask you to allow
installs from that source — expected for any self-signed APK. See
[Releases are debug-signed](#releases-are-debug-signed) before you install from
anywhere but your own build.

**Pair:** paste the `LAN:` URL into the setup screen, tap **Test** — it should
report `Reachable — HTTP 401`, which is correct, because the port answers and
rejects unauthenticated index requests — then **Save & Connect**.

**Pinning your host (optional, and not a security boundary).** Android's
network security config cannot express "private ranges only" — it matches
literal hosts with no CIDR or wildcard support — so cleartext stays permitted
to any host and the firewall rule is the real boundary. You can still pin your
own host into a `<domain-config>` so the built config documents your intended
endpoint:

```powershell
.\build.ps1 -CleartextHosts 100.x.y.z,dsh-desktop.tailXXXX.ts.net
```

To be plain about the limits: the base stays permissive in both modes, so this
does not stop the app reaching other hosts. It is a record of intent, not a
fence. See [SECURITY.md](SECURITY.md).

---

## What the app does

- **Token re-presentation on every cold start.** The server only mints the
  session cookie for a `GET /` carrying exactly one valid `token` parameter,
  and that cookie expires. Re-sending the token each launch is self-healing:
  surviving cookie, nothing changes; lapsed cookie, a fresh one is issued.
- **Cookie persistence.** 30 days by default, matching the server's
  `cookieMaxAgeDays`.
- **File chooser wiring.** `onShowFileChooser` → system picker, multi-select
  supported, so attachments from the phone upload normally.
- **Back button walks SPA history** before it ever offers to leave the app.
- **Offline panel** that fires only on main-document failure — subresource
  noise on a flaky link won't wall you off.
- **Immersive mode** and **keep-awake** toggles in the overflow menu.
  Keep-awake holds a partial wake lock so a long agent run keeps streaming
  with the screen off. Off by default; it costs battery.
- **External links** open in the system browser. Camera and mic permission
  requests are denied outright — this client has no use for them and a prompt
  there would only be a phishing surface.

---

## Security posture

Stated plainly, because the stakes are code execution. Full version in
[SECURITY.md](SECURITY.md).

- **The token is the only application-layer gate.** Anyone holding it can run
  commands on your machine. Treat the `LAN:` URL like a password and don't
  paste it into chats, screenshots, or issue trackers.
- **Transport confidentiality is WireGuard's**, not TLS's. Packets between
  phone and desktop are encrypted by Tailscale. The app permits cleartext HTTP
  because adding a self-signed certificate would only add a warning the WebView
  refuses.
- **The firewall rule is the real boundary** in the default setup. Tailscale-
  scoped, one port. If you remove it while the patched instance is bound to
  `0.0.0.0`, you have put a shell on your LAN. The loopback variant below
  removes this dependency entirely, which is why it is the safer choice.
- **The `-CleartextHosts` allowlist is documentation, not enforcement.** The
  base config stays permissive; the flag records which host you meant to use.
- **Tailscale ACLs are your second boundary.** To restrict which tailnet
  devices reach the port, do it in the tailnet policy file rather than in this
  app.
- **Revoking access:** stop the patched DSH, or re-pair. There is no per-device
  session to kill — the token is process-wide.

---

## Step 4 — Building the APK

```powershell
.\build.ps1
```

```sh
./build.sh          # Linux / macOS
```

No Gradle, no Android Studio project, no network. The scripts drive `aapt2`,
`javac`, `d8`, `zipalign`, and `apksigner` directly, discover the SDK and JDK
automatically, and report any missing tool by name.

Requirements:

- **Android SDK** with `build-tools` and the `android-34` platform. Found via
  `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or the default per-OS location.
- **JDK 17 or newer.** Found via `JAVA_HOME` or the usual install roots.

Overrides:

```powershell
.\build.ps1 -Sdk "D:\Android\Sdk" -Jdk "C:\Program Files\Java\jdk-17" -MinSdk 24

# Narrow cleartext to your own desktop (see Step 3)
.\build.ps1 -CleartextHosts 100.x.y.z
```

**One trap worth knowing:** build-tools `34.0.0` ships R8 8.2.2, which throws an
internal `NullPointerException` when run under a JDK 23 runtime. The script
picks the newest build-tools you have, which avoids it. If you pin an older one
with `-BuildTools`, expect that NPE and don't go hunting in the app code for it.

### Releases are debug-signed

`debug.keystore` is committed on purpose, with the standard throwaway password
`android`, so a fresh clone builds a runnable APK with zero setup.

That means **anyone can produce an APK that Android treats as a legitimate
update to this package.** For a personal client that is an acceptable trade.
For anything you distribute widely, generate your own keystore and change
`android/package` to a namespace you control:

```powershell
keytool -genkeypair -keystore my-release.keystore -alias mykey `
  -keyalg RSA -keysize 2048 -validity 10000
```

Then edit `build.ps1` / `build.sh` to point at it, or fork and keep your key
private. Never commit a real release keystore.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| App shows "Cannot reach the desktop" | Tailscale off or logged out on the phone | Open Tailscale, confirm the tailnet is up |
| `Test` reports `Reachable — HTTP 401` but the app still fails | Token is stale | Re-pair with the fresh `LAN:` URL |
| `Test` times out | DSH not running, or firewall rule missing | Restart DSH with the patch; re-check the rule |
| Desktop IP changed | Tailscale reassigned the address | `tailscale ip -4`, then re-pair — or switch to the [loopback + MagicDNS variant](TAILSCALE-BINDINGS.md), where the name is stable and you never re-pair for this |
| App can't reach a host you pinned | `-CleartextHosts` is a record of intent, not a fence — the base config stays permissive | Almost certainly not the cause. Check Tailscale, DSH, and the firewall rule |
| `dsh-stream-market` spams "port 18899 occupied" | Two DSH instances running at once | Run **one**. Stop the Electron desktop app before starting the patched `dsh web`, or ignore it — the feature degrades, the web app still boots |
| Everything works, then dies after a desktop restart | Token is per-process | Re-pair. This is by design, not a bug |
| `aapt2` errors on a resource name containing a dot | A `.template.xml` file reached the compiler | Build through `build.ps1`/`build.sh`, which filters templates out |

---

## Files

```
dsh-mobile/
├─ dsh-tailnet.patch.yml                     server-side overlay (the "plugin")
├─ dsh-tailnet-3081.patch.yml                same, for when the desktop app holds 3080
├─ TAILSCALE-BINDINGS.md                     the loopback + MagicDNS variant
├─ build.ps1 / build.sh                      toolchain-driven APK build
├─ debug.keystore                            self-signed, pass: android (see above)
├─ SECURITY.md                               threat model and reporting
└─ android/
   ├─ AndroidManifest.xml
   ├─ res/                                   layouts, strings, colors, theme, icon, NSC
   │  └─ xml/
   │     ├─ network_security_config.template.xml   edited by hand
   │     └─ network_security_config.xml            generated by the build
   └─ src/com/dsh/mobile/
      ├─ MainActivity.java                   WebView host, file chooser, lifecycle
      ├─ SetupActivity.java                  pairing + reachability probe
      ├─ DshUrl.java                         tolerant URL/token parser
      └─ Prefs.java                          stored connection facts
```

---

## Alternative: skip the APK

DSH already ships a PWA manifest (`display: fullscreen`). In Chrome on Android,
open the working `LAN:` URL and choose **Add to Home screen**. You get a
fullscreen, icon-launched client with zero installs.

The APK exists because the PWA cannot: hold a wake lock for background streams,
deny camera/mic permissions at the app layer, route the back button through SPA
history, or show a real diagnostic panel instead of Chrome's error wall.

---

## License

MIT — see [LICENSE](LICENSE). This is an independent client; it is not
affiliated with or endorsed by DeepSeek. DeepSeek Harness itself is MIT
licensed and is not bundled here: the app talks to whatever DSH instance you
run.
