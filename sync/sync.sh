#!/bin/sh
# segno update mirror — polls the GitHub Releases API and mirrors per-channel
# artifacts into what nginx serves (www/updates/appliance/<channel>/), so the
# devices only ever talk to segno.aquiles.dev, never GitHub.
#
# Channels:
#   experimental <- newest PRERELEASE by published_at (NOT GitHub list order)
#   production   <- the latest full release (/releases/latest)
#
# Per release we mirror `manifest.json`, `*.raucb` (the OS/app bundle) and
# `*.hex` (the paired Pro Micro pedal firmware). The manifest CI produces carries
# the version, the bundle filename (relative) and its sha256, and optionally a
# pedalFirmware block naming the .hex and its sha256 — the device reads the
# manifest and fetches whichever of those it needs from here.
#
# Modes (first arg):
#   loop  — forever poll (default; used by the container entrypoint)
#   once  — single mirror cycle then exit (used by POST /hooks/sync)
set -eu

REPO="${GITHUB_REPO:-tomassasovsky/loopy}"
WWW="${WWW_DIR:-/www}"
INTERVAL="${POLL_INTERVAL:-300}"
API="https://api.github.com/repos/${REPO}"

# GitHub API auth is optional (public releases work unauthenticated at 60 req/h;
# a token raises the limit and is required if the repo/releases are private).
gh_api() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
             -H "Accept: application/vnd.github+json" "$@"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$@"
    fi
}

# Asset downloads use browser_download_url (302 → Azure blob). Do not send the
# GitHub JSON Accept header — keep a plain curl follow-redirects fetch.
gh_asset() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
             -H "Accept: application/octet-stream" "$@"
    else
        curl -fsSL "$@"
    fi
}

mirror_channel() {
    channel="$1"; kind="$2"
    dest="${WWW}/updates/appliance/${channel}"
    mkdir -p "$dest"

    if [ "$kind" = "release" ]; then
        rel=$(gh_api "${API}/releases/latest" 2>/dev/null || true)
    else
        # GitHub's /releases list is NOT reliably newest-first (observed: an older
        # prerelease can appear before later ones). Sort by published_at desc.
        rel=$(gh_api "${API}/releases?per_page=30" 2>/dev/null \
              | jq -c 'map(select(.prerelease==true and .draft==false))
                       | sort_by(.published_at // .created_at)
                       | reverse
                       | .[0] // empty' || true)
    fi
    [ -n "${rel:-}" ] && [ "$rel" != "null" ] || { echo "[$channel] no release yet"; return 0; }

    tag=$(echo "$rel" | jq -r '.tag_name // empty')
    [ -n "$tag" ] || { echo "[$channel] release has no tag"; return 0; }
    cur=$(cat "${dest}/.tag" 2>/dev/null || echo "")
    if [ "$tag" = "$cur" ]; then echo "[$channel] up to date ($tag)"; return 0; fi

    echo "[$channel] new release: $tag (was: ${cur:-none})"
    # Download manifest.json + *.raucb + *.hex assets atomically (temp then
    # rename), so a device polling mid-sync never sees a half-written file.
    echo "$rel" | jq -r '.assets[]? | [.name, .browser_download_url] | @tsv' \
    | while IFS="$(printf '\t')" read -r name url; do
        case "$name" in
            manifest.json|*.raucb|*.hex)
                echo "[$channel]   fetch $name"
                # Temp name is unique per run. It used to be .tmp.<name>,
                # shared by every run, so two overlapping cycles raced for the
                # same path and one renamed the other's file away:
                #   mv: can't rename '.../.tmp.loopy-pedal-….hex': No such file
                # The lock below should prevent overlap; this makes a collision
                # harmless if it ever gets one anyway.
                tmp="${dest}/.tmp.$$.${name}"
                if gh_asset -o "$tmp" "$url"; then
                    mv -f "$tmp" "${dest}/${name}"
                else
                    echo "[$channel]   FAILED $name"; rm -f "$tmp"
                fi
                ;;
        esac
    done
    # Only stamp the tag once EVERYTHING the manifest references is on disk, so
    # a partial mirror retries on the next cycle instead of being frozen in
    # place. Stamping on the manifest alone is how the pedal firmware silently
    # went missing for two releases: the manifest advertised a .hex the mirror
    # had never fetched, the tag matched, and no later cycle ever retried it.
    if mirror_complete "$dest"; then
        echo "$tag" > "${dest}/.tag"
    else
        echo "[$channel] incomplete — not stamping $tag; will retry next cycle"
    fi
}

# Succeeds when every artifact the mirrored manifest points at is present AND
# matches the checksum the manifest states for it.
#
# Presence alone is not enough: a truncated download, or a stale file left by a
# previous release with the same name, both pass an -f test and then fail on
# the device — where the appliance refuses the .hex and the update dies
# mid-flight. The manifest already carries both sha256s, so checking costs a
# read of files we just wrote and needs no extra source of truth.
mirror_complete() {
    d="$1"
    [ -f "${d}/manifest.json" ] || { echo "  missing: manifest.json"; return 1; }
    bad=0
    pairs=$(jq -r '[
                     {n: .bundle, s: .sha256},
                     {n: .pedalFirmware.hex, s: .pedalFirmware.sha256}
                   ]
                   | map(select(.n != null and .n != ""))
                   | .[] | "\(.n) \(.s // "")"' \
              "${d}/manifest.json" 2>/dev/null)
    printf '%s\n' "$pairs" | while IFS=' ' read -r f want; do
        [ -n "$f" ] || continue
        if [ ! -f "${d}/${f}" ]; then
            echo "  missing: $f"; exit 1
        fi
        # A manifest with no sha256 is refused by the appliance anyway, so
        # mirroring it as "complete" would only hide the problem.
        if [ -z "$want" ]; then
            echo "  no sha256 published for: $f"; exit 1
        fi
        got=$(sha256sum "${d}/${f}" | cut -d" " -f1)
        if [ "$got" != "$want" ]; then
            echo "  checksum mismatch: $f (want $want, got $got)"; exit 1
        fi
    done || bad=1
    [ "$bad" -eq 0 ]
}

run_once() {
    mirror_channel experimental prerelease || true
    mirror_channel production   release    || true
}

# Serialise cycles. CI POSTs /hooks/sync up to twelve times while polling, and a
# slow cycle means the next POST starts a second one on the same directories —
# which is how two runs ended up fighting over one temp file on .63. mkdir is
# the portable atomic test-and-set; a stale lock from a killed container is
# cleared by age rather than trusting the PID.
LOCK="${WWW}/.sync.lock"
with_lock() {
    if [ -d "$LOCK" ]; then
        if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
            echo "clearing a stale sync lock"; rmdir "$LOCK" 2>/dev/null || true
        else
            echo "another sync cycle is running; skipping"
            return 0
        fi
    fi
    mkdir "$LOCK" 2>/dev/null || { echo "another sync cycle just started; skipping"; return 0; }
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM
    "$@"
    rmdir "$LOCK" 2>/dev/null || true
    trap - EXIT INT TERM
}

mode="${1:-loop}"
case "$mode" in
    once)
        echo "segno mirror once: repo=${REPO} -> ${WWW}/updates/appliance/{experimental,production}"
        with_lock run_once
        ;;
    loop)
        echo "segno mirror: repo=${REPO} interval=${INTERVAL}s -> ${WWW}/updates/appliance/{experimental,production}"
        while true; do
            with_lock run_once
            sleep "$INTERVAL"
        done
        ;;
    *)
        echo "usage: sync.sh [loop|once]" >&2
        exit 2
        ;;
esac
