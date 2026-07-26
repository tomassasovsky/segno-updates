# segno update server

Static host for Loopy/segno updates — appliance RAUC bundles + a JSON manifest the
Pi polls (and desktop Sparkle/WinSparkle appcasts later). Runs behind **Nginx Proxy
Manager** (a separate container), which reverse-proxies `https://segno.aquiles.dev`
to this container as `segno-updates:3029` over a shared Docker network.

## Layout served
```
/updates/appliance/<channel>/manifest.json     # the Pi reads this
/updates/appliance/<channel>/loopy-appliance-<v>.raucb
/updates/macos/appcast.xml   (later)
/updates/windows/appcast.xml (later)
```

`manifest.json` schema:
```json
{ "version": "0.2.0-experimental.9", "bundle": "loopy-appliance-….raucb", "sha256": "<hex>", "channel": "experimental" }
```
The Pi OTA client compares `version` to the running build; if newer it downloads
`bundle` from the same dir, verifies `sha256`, then `rauc install`s it (RAUC also
verifies the bundle's own X.509 signature — the manifest is not the security
boundary, the signature is).

## Deploy on Portainer (git-repository stack)
Both services **build** (nginx bakes its config in; the mirror builds from `sync/`),
and the served files live in a **named volume** — so there are NO host-file bind
mounts to pre-create. Deploy it as a git stack so Portainer has the build
context:

1. Portainer → Stacks → Add stack → **Repository** → this repo
   (`https://github.com/tomassasovsky/segno-updates`), compose path `docker-compose.yml`.
   Deploy — it builds both images and publishes host port **3029**.
2. Point Nginx Proxy Manager's `segno.aquiles.dev` proxy host at `<docker-host>:3029`.
3. Set stack env **`SYNC_TOKEN`** to a long random secret (same value as the loopy
   repo Actions secret `SEGNO_SYNC_TOKEN`). Without it, `/hooks/sync` returns 503
   and only the poll loop runs.

Verify: `curl https://segno.aquiles.dev/healthz` → `ok`. Until the first release is
published the manifest 404s (nothing mirrored yet) — that's expected.

## Publishing an update
The mirror selects the newest **prerelease by `published_at`** (GitHub's `/releases`
list order is not reliable). Automatic path:

1. The app repo's release pipeline publishes a signed `.raucb` + `manifest.json` to a
   GitHub Release per channel.
2. CI then `POST`s `https://segno.aquiles.dev/hooks/sync` with
   `Authorization: Bearer $SEGNO_SYNC_TOKEN`, which runs one mirror cycle immediately.
3. Fallback: `segno-mirror` still polls the Releases API every `POLL_INTERVAL`s
   (default 300) and writes into the `updates-www` volume nginx serves
   (`no-cache` headers → the Pi sees changes immediately).

Manual trigger (same as CI):
```bash
curl -fsS -X POST \
  -H "Authorization: Bearer $SEGNO_SYNC_TOKEN" \
  https://segno.aquiles.dev/hooks/sync
```
