#!/usr/bin/env bash
# herdr install helper, shared by the two macOS bootstraps and by
# provision/herdr-setup.sh on the server.
#
# The version lives HERE and nowhere else on purpose. A herdr client and server
# negotiate a protocol version (0.8.0 speaks protocol 19), and a mismatch
# between the Mac and the server is the first thing that breaks and the last
# thing you would think to check. One constant, used by every machine's
# bootstrap, means they cannot drift apart by accident.
#
# Not installed via Homebrew even on macOS: there is no official formula, the
# release binaries are what herdr.dev's own installer fetches, and going
# straight to them is what lets this pin a version and verify a checksum.

HERDR_VERSION="${HERDR_VERSION:-v0.8.0}"

# herdr.dev publishes a manifest with per-platform URLs AND sha256 sums. Both
# the client and the update machinery inside herdr itself read it.
HERDR_MANIFEST_URL="${HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}"

# ensure_herdr [version]
#
# Installs herdr to ~/.local/bin/herdr unless the pinned version is already
# there. Returns non-zero if the download cannot be verified.
ensure_herdr() {
  local want="${1:-$HERDR_VERSION}"
  local bare="${want#v}"
  local dest="$HOME/.local/bin/herdr"
  local os arch key url want_sha got_sha tmp

  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) echo "  ERROR: herdr: unsupported OS $(uname -s)" >&2; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *) echo "  ERROR: herdr: unsupported architecture $(uname -m)" >&2; return 1 ;;
  esac
  key="${os}-${arch}"

  if [ -x "$dest" ] && [ "$("$dest" --version 2>/dev/null)" = "herdr ${bare}" ]; then
    echo "  herdr ${bare} already installed"
    return 0
  fi

  # Ask the manifest for the URL rather than hard-coding a GitHub path: the
  # project has already moved organizations once (herdrdev/herdr), and the
  # manifest is what herdr's own updater follows.
  local meta
  meta="$(curl -fsSL "$HERDR_MANIFEST_URL" | python3 -c '
import json, sys
want, key = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
# The top level describes the CURRENT release; older ones live under releases.
rel = d if d.get("version") == want else d.get("releases", {}).get(want)
if not rel:
    sys.exit(3)
url = rel.get("assets", {}).get(key)
if not url:
    sys.exit(4)
# Only the current release carries checksums in this manifest; an older pin
# gets an empty second field and is reported as unverified below.
print(url)
print((rel.get("sha256") or {}).get(key, ""))
' "$bare" "$key")" || {
    echo "  ERROR: herdr: no ${key} build published for ${bare}" >&2
    return 1
  }

  url="$(printf '%s\n' "$meta" | sed -n 1p)"
  want_sha="$(printf '%s\n' "$meta" | sed -n 2p)"

  echo "  installing herdr ${bare} (${key})"
  tmp="$(mktemp)"
  # No trap here: this is sourced into scripts that set their own, and an EXIT
  # trap installed by a helper would silently replace the caller's.
  if ! curl -fsSL -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "  ERROR: herdr: download failed: $url" >&2
    return 1
  fi

  if [ -n "$want_sha" ]; then
    # macOS ships shasum, Linux ships sha256sum, and this helper runs on both.
    if command -v sha256sum >/dev/null 2>&1; then
      got_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
    else
      got_sha="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
    fi
    if [ "$got_sha" != "$want_sha" ]; then
      rm -f "$tmp"
      echo "  ERROR: herdr: checksum mismatch for ${key}" >&2
      echo "         expected ${want_sha}" >&2
      echo "         got      ${got_sha}" >&2
      return 1
    fi
    echo "  checksum verified"
  else
    # Pinning an older version is legitimate, but say plainly that the download
    # was not verified rather than implying it was.
    echo "  NOTE: herdr.dev publishes no checksum for ${bare} — download NOT verified"
  fi

  chmod +x "$tmp"
  # Run it before installing it: a truncated download or a wrong-arch binary is
  # the realistic failure, and finding out now beats finding out at attach time.
  if ! "$tmp" --version >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "  ERROR: herdr: downloaded binary does not run" >&2
    return 1
  fi

  mkdir -p "$HOME/.local/bin"
  install -m 755 "$tmp" "$dest"
  rm -f "$tmp"
  echo "  installed $("$dest" --version) to $dest"
}
