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

# The repo was renamed loopy -> segno; GitHub redirects the old name, but
# name the real one so a future rename does not silently break on a 301.
REPO="${GITHUB_REPO:-tomassasovsky/segno}"
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
    # Download *.raucb + *.hex atomically (temp then rename), so a device
    # polling mid-sync never sees a half-written file.
    #
    # manifest.json is different: it is the only file a device reads to decide
    # what to download, so it goes live LAST and ONLY once everything it names
    # is on disk with the right checksum. Publishing it earlier — before the
    # bundle, or after a bundle fetch failed — told every console that checked
    # about a version the mirror could not serve; each of them failed with a
    # 404 (0.1.0-experimental.128, .129 and .130 all did this on 2026-09-03).
    # Until then the previous manifest stays in place and keeps working.
    #
    # The list goes through a file, not a pipe: a `| while read` runs in a
    # subshell, and the flags set inside it would never reach the code below.
    list="${dest}/.tmp.$$.assets"
    echo "$rel" | jq -r '.assets[]? | [.name, .browser_download_url] | @tsv' \
    | awk -F"$(printf '\t')" '$1 == "manifest.json" { m = $0; next } { print } END { if (m) print m }' \
    > "$list"
    published=0
    while IFS="$(printf '\t')" read -r name url; do
        case "$name" in
            manifest.json|*.raucb|*.hex) ;;
            *) continue ;;
        esac
        echo "[$channel]   fetch $name"
        # Temp name is unique per run. It used to be .tmp.<name>, shared by
        # every run, so two overlapping cycles raced for the same path and one
        # renamed the other's file away. The lock should prevent overlap; this
        # makes a collision harmless if it ever gets one anyway.
        tmp="${dest}/.tmp.$$.${name}"
        if ! gh_asset -o "$tmp" "$url"; then
            echo "[$channel]   FAILED $name"; rm -f "$tmp"
            continue
        fi
        if [ "$name" = "manifest.json" ]; then
            if mirror_complete "$dest" "$tmp"; then
                mv -f "$tmp" "${dest}/manifest.json"
                published=1
            else
                echo "[$channel]   holding manifest.json: it names files the mirror does not have yet"
                rm -f "$tmp"
            fi
        else
            mv -f "$tmp" "${dest}/${name}"
        fi
    done < "$list"
    rm -f "$list"
    # Only stamp the tag once the NEW manifest is live and everything it
    # references is on disk, so a partial mirror retries on the next cycle
    # instead of being frozen in place. Stamping on the manifest alone is how
    # the pedal firmware silently went missing for two releases: the manifest
    # advertised a .hex the mirror had never fetched, the tag matched, and no
    # later cycle ever retried it.
    if [ "$published" -eq 1 ] && mirror_complete "$dest"; then
        echo "$tag" > "${dest}/.tag"
    else
        echo "[$channel] incomplete — not stamping $tag; will retry next cycle"
    fi
}

# mirror_complete DIR [MANIFEST]: is every file MANIFEST names present in DIR
# with the published checksum? MANIFEST defaults to the live one in DIR; the
# sync passes a just-downloaded one to decide whether it may go live.
mirror_complete() {
    d="$1"
    manifest="${2:-${d}/manifest.json}"
    [ -f "$manifest" ] || { echo "  missing: manifest.json"; return 1; }
    bad=0
    pairs=$(jq -r '[
                     {n: .bundle, s: .sha256},
                     {n: .pedalFirmware.hex, s: .pedalFirmware.sha256}
                   ]
                   | map(select(.n != null and .n != ""))
                   | .[] | "\(.n) \(.s // "")"' \
              "$manifest" 2>/dev/null)
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
HEARTBEAT="${LOCK}/heartbeat"
# How long a lock may go untouched before it is nobody's. The holder refreshes
# it while it works, so this only ever fires for a holder that is gone.
STALE_AFTER_MIN="${STALE_AFTER_MIN:-2}"

# A trap does not run when the container is killed, and this one is not killed
# gently: watchtower restarts it on every image push, in the middle of whatever
# it was doing. A lock directory left behind that way used to be honoured for a
# full 30 minutes, during which every cycle logged "another sync cycle is
# running" and did nothing — so a release could sit unmirrored while its
# manifest was already published (2026-09-03: .128 and .129 both stranded).
#
# So the holder proves it is alive by touching a heartbeat inside the lock, and
# a lock whose heartbeat has stopped is taken over. flock would be the usual
# answer and needs no heartbeat, but it is not in busybox and this runs in a
# minimal image.
lock_is_dead() {
    [ -d "$LOCK" ] || return 1
    # No heartbeat yet: either a holder that is between mkdir and its first
    # touch (give it the same grace as a stalled one), or a lock left by the
    # version of this script that never wrote one.
    [ -f "$HEARTBEAT" ] || {
        [ -n "$(find "$LOCK" -maxdepth 0 -mmin "+${STALE_AFTER_MIN}" 2>/dev/null)" ]
        return
    }
    [ -n "$(find "$HEARTBEAT" -maxdepth 0 -mmin "+${STALE_AFTER_MIN}" 2>/dev/null)" ]
}

with_lock() {
    if [ -d "$LOCK" ]; then
        if lock_is_dead; then
            echo "clearing a sync lock whose holder is gone"
            rm -rf "$LOCK" 2>/dev/null || true
        else
            echo "another sync cycle is running; skipping"
            return 0
        fi
    fi
    mkdir "$LOCK" 2>/dev/null || { echo "another sync cycle just started; skipping"; return 0; }
    touch "$HEARTBEAT"
    trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT INT TERM

    # Keep the heartbeat warm for as long as the work runs, so a slow but
    # healthy sync is never mistaken for a dead one. The beater watches its
    # parent: if the script dies without reaching the cleanup below (a signal
    # it does not trap), an orphaned beater must not keep a dead holder's lock
    # alive forever. $$ in the subshell is still this script's PID.
    holder=$$
    (
        while kill -0 "$holder" 2>/dev/null && [ -d "$LOCK" ]; do
            touch "$HEARTBEAT" 2>/dev/null || exit 0
            sleep 30
        done
    ) &
    beat=$!

    "$@"
    status=$?

    kill "$beat" 2>/dev/null || true
    wait "$beat" 2>/dev/null || true
    rm -rf "$LOCK" 2>/dev/null || true
    trap - EXIT INT TERM
    return $status
}

# Tests source this file for its functions and run nothing.
[ "${SYNC_NO_MAIN:-0}" = 1 ] && return 0

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
