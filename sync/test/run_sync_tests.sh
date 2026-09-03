#!/bin/sh
# Tests for sync/sync.sh — the mirror cycle and its lock, run against fake
# GitHub responses so no network, token or container is needed.
#
# The rule under test: a device must never be told about a version the mirror
# cannot serve. So manifest.json goes live last, only once every file it names
# is present with the published checksum, and a lock left by a holder that
# died (a recreated container, a killed cycle) is taken over, not honoured.
#
# Run: sh sync/test/run_sync_tests.sh
set -u

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export WWW_DIR="$work/www"
export SYNC_NO_MAIN=1
# Test hosts without coreutils (macOS) have shasum with the same output shape.
command -v sha256sum >/dev/null 2>&1 || sha256sum() { shasum -a 256 "$@"; }

. "$here/../sync.sh"

passed=0; failed=0
check() {
    if eval "$2"; then passed=$((passed + 1)); echo "PASS: $1"
    else failed=$((failed + 1)); echo "FAIL: $1"; fi
}

# --- fake GitHub -------------------------------------------------------------
# $ASSETS/<name> is what a download yields; a name listed in $FAIL fails.
ASSETS="$work/assets"; FAIL=""; FETCHED="$work/fetched"
sha() { sha256sum "$1" | cut -d' ' -f1; }

release_json() {
    tag="$1"; shift
    printf '{"tag_name":"%s","prerelease":true,"draft":false,"published_at":"2026-09-03T21:23:10Z","assets":[' "$tag"
    sep=""
    for n in "$@"; do
        printf '%s{"name":"%s","browser_download_url":"fake://%s"}' "$sep" "$n" "$n"; sep=","
    done
    printf ']}'
}
gh_api() {
    case "$1" in
        *releases/latest) return 1 ;;
        *) printf '[%s]' "$RELEASE" ;;
    esac
}
gh_asset() {
    out="$2"; name="${3#fake://}"
    echo "$name" >> "$FETCHED"
    case " $FAIL " in *" $name "*) return 22 ;; esac
    cp "$ASSETS/$name" "$out"
}

stage_release() {
    # A release whose manifest names the bundle with its real checksum.
    ver="$1"
    rm -rf "$ASSETS"; mkdir -p "$ASSETS"; : > "$FETCHED"
    head -c 4096 /dev/urandom > "$ASSETS/segno-appliance-${ver}.raucb"
    printf '{"version":"%s","bundle":"segno-appliance-%s.raucb","sha256":"%s","channel":"experimental"}\n' \
        "$ver" "$ver" "$(sha "$ASSETS/segno-appliance-${ver}.raucb")" > "$ASSETS/manifest.json"
    # GitHub lists the manifest FIRST — the order that used to be mirrored.
    RELEASE=$(release_json "appliance-experimental-$ver" manifest.json "segno-appliance-${ver}.raucb")
}

dest="$WWW_DIR/updates/appliance/experimental"

# --- 1. a clean release mirrors completely, manifest last -------------------
stage_release 0.1.0-experimental.130
mirror_channel experimental prerelease >/dev/null
check "bundle is on disk" '[ -f "$dest/segno-appliance-0.1.0-experimental.130.raucb" ]'
check "manifest is live" 'grep -q "experimental.130" "$dest/manifest.json"'
check "tag is stamped" '[ "$(cat "$dest/.tag")" = appliance-experimental-0.1.0-experimental.130 ]'
check "manifest was fetched after the bundle" '[ "$(tail -n1 "$FETCHED")" = manifest.json ]'
check "no temp files left behind" '[ -z "$(ls -A "$dest" | grep "^\.tmp\.")" ]'

# --- 2. a bundle fetch fails: the old manifest keeps serving ----------------
stage_release 0.1.0-experimental.131
FAIL="segno-appliance-0.1.0-experimental.131.raucb"
out=$(mirror_channel experimental prerelease)
check "manifest is held when its bundle is missing" 'echo "$out" | grep -q "holding manifest.json"'
check "the previous manifest still serves" 'grep -q "experimental.130" "$dest/manifest.json"'
check "tag is not advanced" '[ "$(cat "$dest/.tag")" = appliance-experimental-0.1.0-experimental.130 ]'
check "no temp files left behind after a failure" '[ -z "$(ls -A "$dest" | grep "^\.tmp\.")" ]'

# --- 3. the next cycle finishes the job ------------------------------------
FAIL=""; : > "$FETCHED"
mirror_channel experimental prerelease >/dev/null
check "retry mirrors the bundle" '[ -f "$dest/segno-appliance-0.1.0-experimental.131.raucb" ]'
check "retry publishes the manifest" 'grep -q "experimental.131" "$dest/manifest.json"'
check "retry stamps the tag" '[ "$(cat "$dest/.tag")" = appliance-experimental-0.1.0-experimental.131 ]'

# --- 4. a checksum that does not match is not served -----------------------
stage_release 0.1.0-experimental.132
head -c 4096 /dev/urandom > "$ASSETS/segno-appliance-0.1.0-experimental.132.raucb"   # now differs from the manifest's sha
out=$(mirror_channel experimental prerelease)
check "manifest is held on a checksum mismatch" 'echo "$out" | grep -q "holding manifest.json"'
check "checksum mismatch keeps the previous manifest" 'grep -q "experimental.131" "$dest/manifest.json"'

# --- 5. an up-to-date channel does nothing --------------------------------
stage_release 0.1.0-experimental.131
out=$(mirror_channel experimental prerelease)
check "matching tag is a no-op" 'echo "$out" | grep -q "up to date" && [ ! -s "$FETCHED" ]'

# --- 6. the lock -----------------------------------------------------------
LOCK="$WWW_DIR/.sync.lock"; HEARTBEAT="$LOCK/heartbeat"
ran="$work/ran"; job() { echo yes > "$ran"; }

rm -f "$ran"; mkdir -p "$LOCK"; touch -t 202001010000 "$HEARTBEAT"
out=$(with_lock job)
check "a lock whose heartbeat stopped is taken over" 'echo "$out" | grep -q "holder is gone" && [ -f "$ran" ]'
check "the lock is released afterwards" '[ ! -d "$LOCK" ]'

rm -f "$ran"; mkdir -p "$LOCK"; touch -t 202001010000 "$LOCK"
out=$(with_lock job)
check "an old lock with no heartbeat at all is taken over" 'echo "$out" | grep -q "holder is gone" && [ -f "$ran" ]'

rm -f "$ran"; mkdir -p "$LOCK"; touch "$HEARTBEAT"
out=$(with_lock job)
check "a live lock is respected" 'echo "$out" | grep -q "another sync cycle is running" && [ ! -f "$ran" ]'
rm -rf "$LOCK"

rm -f "$ran"; mkdir -p "$LOCK"   # fresh, no heartbeat yet: a holder between mkdir and its first touch
out=$(with_lock job)
check "a brand-new lock without a heartbeat is respected" 'echo "$out" | grep -q "another sync cycle is running" && [ ! -f "$ran" ]'
rm -rf "$LOCK"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
