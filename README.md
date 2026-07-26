# segno update server

Static host for Loopy/segno updates — appliance RAUC bundles + a JSON manifest the
Pi polls (and desktop Sparkle/WinSparkle appcasts later). Runs behind **Nginx Proxy
Manager** (a separate container), which reverse-proxies `https://segno.aquiles.dev`
to this container as `segno-updates:3029` over a shared Docker network.

## Layout served
```
/updates/appliance/manifest.json     # the Pi reads this
/updates/appliance/loopy-appliance-<v>.raucb   # signed RAUC bundle(s)
/updates/macos/appcast.xml   (later)
/updates/windows/appcast.xml (later)
```

`manifest.json` schema:
```json
{ "version": 3, "bundle": "loopy-appliance-3.raucb", "sha256": "<hex>", "notes": "..." }
```
The Pi OTA client compares `version` to the running build; if newer it downloads
`bundle` from the same dir, verifies `sha256`, then `rauc install`s it (RAUC also
verifies the bundle's own X.509 signature — the manifest is not the security
boundary, the signature is).

## Deploy on Portainer (git-repository stack)
Both services **build** (nginx bakes its config in; the mirror builds from `sync/`),
and the served files live in a **named volume** — so there are NO host-file bind
mounts to pre-create (that's what caused the earlier "mount a directory onto a file"
error with a pasted compose). Deploy it as a git stack so Portainer has the build
context:

1. Portainer → Stacks → Add stack → **Repository** → this repo
   (`https://github.com/tomassasovsky/segno-updates`), compose path `docker-compose.yml`.
   Deploy — it builds both images and publishes host port **3029**.
2. Point Nginx Proxy Manager's `segno.aquiles.dev` proxy host at `<docker-host>:3029`.

Verify: `curl https://segno.aquiles.dev/healthz` → `ok`. Until the first release is
published the manifest 404s (nothing mirrored yet) — that's expected.

## Publishing an update
The mirror selects the newest **prerelease by `published_at`** (GitHub's `/releases` list order is not reliable). Automatic: the app repo's release pipeline publishes a signed `.raucb` + `manifest.json`
to a GitHub Release per channel; `segno-mirror` polls the Releases API every
`POLL_INTERVAL`s and writes them into the `updates-www` volume nginx serves
(`no-cache` headers → the Pi sees changes immediately). No manual file copying.
