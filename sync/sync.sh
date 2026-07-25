#!/bin/sh
# segno update mirror — polls the GitHub Releases API and mirrors per-channel
# artifacts into what nginx serves (www/updates/appliance/<channel>/), so the
# devices only ever talk to segno.aquiles.dev, never GitHub.
#
# Channels:
#   experimental <- the latest PRERELEASE
#   production   <- the latest full release (/releases/latest)
#
# Per release we mirror the assets named `manifest.json` and `*.raucb` (the app
# bundle). The manifest CI produces carries the version, the bundle filename
# (relative), and its sha256 — the device reads it and installs the bundle.
set -eu

REPO="${GITHUB_REPO:-tomassasovsky/loopy}"
WWW="${WWW_DIR:-/www}"
INTERVAL="${POLL_INTERVAL:-300}"
API="https://api.github.com/repos/${REPO}"

# GitHub API auth is optional (public releases work unauthenticated at 60 req/h;
# a token raises the limit and is required if the repo/releases are private).
gh() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
             -H "Accept: application/vnd.github+json" "$@"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$@"
    fi
}

mirror_channel() {
    channel="$1"; kind="$2"
    dest="${WWW}/updates/appliance/${channel}"
    mkdir -p "$dest"

    if [ "$kind" = "release" ]; then
        rel=$(gh "${API}/releases/latest" 2>/dev/null || true)
    else
        # newest prerelease
        rel=$(gh "${API}/releases?per_page=30" 2>/dev/null \
              | jq -c 'map(select(.prerelease==true and .draft==false)) | .[0] // empty' || true)
    fi
    [ -n "${rel:-}" ] && [ "$rel" != "null" ] || { echo "[$channel] no release yet"; return 0; }

    tag=$(echo "$rel" | jq -r '.tag_name // empty')
    [ -n "$tag" ] || { echo "[$channel] release has no tag"; return 0; }
    cur=$(cat "${dest}/.tag" 2>/dev/null || echo "")
    if [ "$tag" = "$cur" ]; then echo "[$channel] up to date ($tag)"; return 0; fi

    echo "[$channel] new release: $tag (was: ${cur:-none})"
    # Download manifest.json + *.raucb assets atomically (temp then rename).
    echo "$rel" | jq -r '.assets[]? | [.name, .browser_download_url] | @tsv' \
    | while IFS="$(printf '\t')" read -r name url; do
        case "$name" in
            manifest.json|*.raucb)
                echo "[$channel]   fetch $name"
                if gh -o "${dest}/.tmp.${name}" "$url"; then
                    mv -f "${dest}/.tmp.${name}" "${dest}/${name}"
                else
                    echo "[$channel]   FAILED $name"; rm -f "${dest}/.tmp.${name}"
                fi
                ;;
        esac
    done
    # Only stamp the tag once the manifest is present (so a partial mirror retries).
    if [ -f "${dest}/manifest.json" ]; then echo "$tag" > "${dest}/.tag"; fi
}

echo "segno mirror: repo=${REPO} interval=${INTERVAL}s -> ${WWW}/updates/appliance/{experimental,production}"
while true; do
    mirror_channel experimental prerelease || true
    mirror_channel production   release    || true
    sleep "$INTERVAL"
done
