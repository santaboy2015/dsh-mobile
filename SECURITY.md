# Security Policy

## The one-sentence version

This app connects a phone to a machine that can run shell commands. The token
in the pairing URL is the only application-layer gate, and the desktop firewall
rule is the only real network boundary. Everything below is detail on those two
facts.

## Reporting a vulnerability

Open a [private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities)
rather than a public issue, or email the maintainer listed in the repository
profile. Please include:

- the app version (visible in the build output or the release tag),
- the Android version and device,
- what you expected versus what happened,
- whether the desktop was on a tailnet, a LAN, or loopback at the time.

There is no bug bounty. Reasonable reports get a fix and credit.

## Threat model

### What this design protects against

| Threat | Mitigation |
|---|---|
| Someone on the same Wi-Fi reaching your DSH | Firewall rule pins the port to the Tailscale interface; other adapters have no path in |
| Someone on the public internet reaching your DSH | There is no public listener, no port forward, and no relay. Tailscale is a private overlay network |
| Passive packet capture between phone and desktop | WireGuard encrypts the transport end to end |
| A phone app reading the session cookie | Cookie lives in the app's private WebView store, not a shared browser jar |
| A malicious page using the camera or mic through this client | `onPermissionRequest` denies unconditionally |

### What it does not protect against

| Threat | Why, and what to do instead |
|---|---|
| Anyone who obtains the pairing URL | The token is process-wide and bearer-style. There is no per-device session to revoke. Treat the URL as a password; rotate it by restarting DSH |
| A compromised tailnet device | Tailscale ACLs are the tool. Restrict which devices may reach the port in your tailnet policy file |
| A phone that is lost or stolen while unlocked | The token sits in app-private `SharedPreferences`, readable on a rooted or debuggable device. Pairing again after a restart invalidates the old token |
| A hostile APK claiming to be an update | Debug-signed releases share a public keystore — see below. Build your own, or verify the release hash out of band |
| Traffic to a host you did not intend | Unless you pin hosts with `-CleartextHosts`, cleartext HTTP is permitted to any host. That flag records intent only — the firewall rule, not the app, is what limits reachability |

The strongest control available is to keep DSH on loopback and name your host
explicitly, so no firewall rule is in the path at all. See
[TAILSCALE-BINDINGS.md](TAILSCALE-BINDINGS.md). It is stricter because the
boundary is enforced by the server process rather than by a rule someone can
forget.

## Cleartext HTTP

The app permits cleartext HTTP by default. This is a deliberate trade, not an
oversight:

- Android's network security config matches **literal hosts only**. It has no
  CIDR or wildcard support, so "allow private ranges" is not expressible. A
  tailnet address is assigned per tailnet, so there is no literal to hardcode.
- Confidentiality comes from WireGuard, which encrypts the link regardless.
  Adding TLS would mean a self-signed certificate the WebView refuses to trust,
  which buys a warning rather than a guarantee.

One honest caveat: `tailscale serve` is a real exception, since it issues
Let's Encrypt certificates for `*.ts.net` names and a WebView would trust them.
It is not used here because it adds a second moving part on the desktop to
encrypt traffic that WireGuard has already encrypted. It becomes worth
considering only if you want to serve DSH beyond the tailnet.

To pin your intended host into a `<domain-config>`, build with an explicit list:

```powershell
.\build.ps1 -CleartextHosts 100.x.y.z,dsh-desktop.tailXXXX.ts.net
```

**This is not a boundary, and it is important not to read it as one.** The
generated config keeps a permissive `base-config` in both modes, because this
file ships to other people's devices and a deny-all base is a decision for the
device owner, not for a build flag. The allowlist records the host you meant to
use; it does not stop the app from reaching any other host. Only the firewall
rule limits reachability.

## Debug-signed releases

`debug.keystore` is committed with the standard password `android` so a fresh
clone produces a runnable APK with no setup. The consequence is that **the
signing identity is public**: anyone can build an APK that Android accepts as an
update to this package name.

Two acceptable responses:

1. Build from source and install your own artifact. Recommended.
2. If you distribute widely, generate a private keystore, keep it out of version
   control, and rename the Android package to a namespace you control.

Never commit a real release keystore.
