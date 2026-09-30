# The loopback + MagicDNS variant

The main README binds DSH to `0.0.0.0` and leans on a firewall rule to keep the
port off your LAN. That works, but it has an unforgiving failure mode: apply the
overlay, forget the rule, and your local network gets a shell.

This variant removes the failure mode instead of warning about it. DSH stays on
loopback, so **there is nothing to firewall** — and you connect by a stable
MagicDNS name instead of a tailnet IP that changes.

Verified against the installed packages, not assumed:

- `dsh web` binds `127.0.0.1` by default (its own `--host` default), so no patch
  is needed to keep it loopback.
- `dsh web --trusted-host <authority...>` is a first-class flag: *"extra
  authority the /api browser-trust fence accepts (host or host:port;
  repeatable)"*. It lands in `trustedHosts: [...lanAddresses, ...extra]`.
- A patch overlay may contain `!!js` expressions, and a patch whose target row
  is absent is only a warning — so overlays compose safely across surfaces.

## Why this is stricter, not just different

With `host: 127.0.0.1` the server never listens on an external adapter. Tailscale
still routes your tailnet address to that loopback listener — that is how
Tailscale works, it proxies into the node — so the phone reaches DSH without DSH
ever binding anything but loopback.

The consequence worth internalising: **the loopback bind is enforced by the
server process itself.** A firewall rule is enforced by something you can forget,
misconfigure, or have reset by a Windows update. This is strictly better on that
axis.

There is one honest tradeoff: the `0.0.0.0` overlay auto-trusts every non-internal
IPv4 on the machine (`resolveLanTrust` enumerates them). Loopback mode trusts
nothing automatically, so the MagicDNS name must be named explicitly. That is the
point — trust becomes deliberate — but it does mean an unedited command below
will fail the `/api` trust fence with a 401-style rejection until the name is
right.

## Setup

### 1. Find your MagicDNS name

```powershell
tailscale status --json
```

Look for your desktop's `DNSName`, e.g. `dsh-desktop.tail1234.ts.net.` — **drop
the trailing dot** when you pass it to `--trusted-host`.

MagicDNS must be enabled in your tailnet's DNS settings, and the phone must be
using Tailscale's DNS (the default on Android).

### 2. Start DSH on loopback, trusting that name

`dsh` splits its own flags from the web app's by position: **the first token the
launcher does not recognise starts the web app's arguments.** So put launcher
flags (`--patch`) first and web-app flags after — and note there is no `--`
separator here, despite what many CLIs do.

```powershell
dsh web --host 127.0.0.1 --port 3080 --trusted-host dsh-desktop.tail1234.ts.net --no-open
```

To run a patched instance alongside the desktop app, the launcher flag goes
before the web app's — otherwise it stops being a launcher flag and gets handed
to the web app instead:

```powershell
dsh web --patch .\dsh-tailnet-3081.patch.yml --host 127.0.0.1 --port 3081 --trusted-host dsh-desktop.tail1234.ts.net --no-open
```

If you would rather not depend on argument order at all, the equivalent
`!!js` overlay also works, and is what the upstream patch file recommends for
adding authorities while preserving the LAN literals:

```yaml
- id: connection
  config:
    trustedHosts: !!js ['dsh-desktop.tail1234.ts.net', ...ctx.webRuntime.trustedHosts]
```

I have not run that overlay — see "Not yet verified" at the end.

### 3. Confirm the bind before you trust it

In a second terminal:

```powershell
Get-NetTCPConnection -LocalPort 3080 -State Listen |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

`LocalAddress` must read **`127.0.0.1`**. If it reads `0.0.0.0` or `::`, you are
running the other overlay and you still need the firewall rule.

### 4. Pair the phone

Paste `http://dsh-desktop.tail1234.ts.net:3080/?token=…` — the hostname, not an
IP. The app parses hostnames fine (`DshUrl` keeps scheme, host, port, token), so
nothing in the client changes.

Because the name is stable, this survives the desktop's tailnet address
changing. That deletes the "desktop IP changed → re-pair" row from the
troubleshooting table. You still re-pair when DSH restarts, because the token is
per-process.

No firewall rule is needed. If you created the one from the main README and are
switching to this variant, you can remove it:

```powershell
Remove-NetFirewallRule -DisplayName "DSH Web (Tailscale only)"
```

## Why not `tailscale serve`?

The obvious question, so answering it directly. `tailscale serve` terminates TLS
on 443 with a real Let's Encrypt certificate for your `*.ts.net` name and proxies
to a local port. A WebView *would* trust that certificate, so unlike a
self-signed cert this is not a dead end.

It is skipped here for two reasons. WireGuard already encrypts the link end to
end, so TLS inside the tunnel protects against nothing an attacker on the path
can exploit. And it adds a second long-running process on the desktop that can
fail independently. If you later want DSH reachable from outside the tailnet,
`tailscale serve` is the right tool — but reaching outside the tailnet is the
thing this whole design exists to avoid.

## What still applies

- **The token is still the only application-layer gate.** Loopback does not
  change that. Anyone holding the pairing URL can run commands on the machine.
- **The tailnet is still the transport.** Confidentiality is WireGuard's.
- **Cleartext is still permitted** by the app, for the reasons in `SECURITY.md`.
  No firewall rule is now involved, but WireGuard is still encrypting the link.
- **Tailscale ACLs remain your second boundary** and are now your *first*
  network control, since no firewall rule is in the path.

## If it does not work

| Symptom | Likely cause |
|---|---|
| `Test` reports 401, then the app fails to load the UI | The `--trusted-host` value does not match the name in the URL exactly, or kept its trailing dot |
| Connection refused from the phone | DSH is not running, or bound somewhere other than loopback — recheck Step 3 |
| `--trusted-host` is not recognised | It was placed before the `--`, so the launcher consumed it |
| Works on the desktop browser, fails on the phone | MagicDNS not enabled, or the phone is not using Tailscale DNS |
| Hostname does not resolve on the phone | Phone is off the tailnet, or `--accept-dns` is disabled |

## Not yet verified

State this plainly rather than letting you discover it: **the running variant has
not been executed end to end.** Every claim above about *mechanism* was read out
of the installed packages (`dsh-web-app`'s flag definition and `startup.js`,
`resolveLanTrust`, `loadOverlayPatches`, and the launcher's argument split), but
no `dsh web` invocation was actually started and reached from a phone, because
every `dsh` command writes `$DSH_HOME/profiles/web/cordis.yml`, which is outside
the sandbox this was developed in.

The untested steps are narrow and each has its own check above:

1. That `--host 127.0.0.1 --trusted-host <name>` survives the launcher's argument
   split — Step 3 confirms the bind, and a successful UI load confirms the trust
   fence.
2. The optional `!!js` overlay spelling, which was not run at all. Prefer the
   flag form until someone confirms it.

If either fails, the default `0.0.0.0` + firewall setup in the main README is
known-good and remains the supported path.

