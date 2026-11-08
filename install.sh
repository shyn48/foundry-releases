#!/bin/bash
# Install Foundry on this Mac with one line (the public releases repo holds this file at its root):
#
#   curl -fsSL https://raw.githubusercontent.com/shyn48/foundry-releases/main/install.sh | bash
#
# Run as yourself, never with sudo. On a fresh Mac it ends with Foundry running (supervisor, control plane and hub as launchd agents, the operations engine on,
# full access CLOSED), /Applications/Foundry.app installed and opened, and your browser on the page where you enrol your first passkey, with the one-time code
# printed here. Nothing is compiled and no source is downloaded: the release is PREBUILT for your CPU (deploy/release.sh makes it: foundry-<rev>-darwin-arm64.tar.gz for Apple
# Silicon, -darwin-amd64 for Intel) and attached to a GitHub release of the public releases repo, and its sha256 is checked before anything in it runs.
#
#   FOUNDRY_RELEASE=<tag>   install that revision instead of the newest        (a tag is the short git revision)
#   bash -s -- --upgrade    on an installed Mac: upgrade to the newest release without asking
#
# What it does, in order: checks macOS >= 14 and which CPU this is -> makes sure the Command Line Tools are there (the agent runtime's build needs git) -> downloads and
# verifies the release for this CPU into ~/Library/Application Support/Foundry/src/<rev> (the tree the app's Upgrade sheet points at) -> puts the bun that comes in it
# under ~/Library/Application Support/Foundry/tools (the OMP agent runtime is a bun program; nothing is fetched for it) -> runs deploy/mac/local-control.sh
# install --fresh --operations --mac-app from it, which copies the binaries, UI and app into place, builds the pinned OMP runtime (npm tarball, hash-checked) and starts
# everything -> opens the passkey page. Telegram is optional and not installed (deploy/mac/telegram.sh).
# The whole script is one { } block so bash reads all of it before running anything: under `| bash`, any command that reads stdin would swallow the rest of it.
{
set -euo pipefail
say() { printf '\033[1;33m[foundry]\033[0m %s\n' "$*"; }
die() { echo "foundry install: $*" >&2; exit 1; }

REPO=${FOUNDRY_RELEASES_REPO:-shyn48/foundry-releases}; API=${FOUNDRY_API:-https://api.github.com}
F="$HOME/Library/Application Support/Foundry"; LA="$HOME/Library/LaunchAgents"
UPGRADE=0; for a in "$@"; do case "$a" in --upgrade) UPGRADE=1 ;; *) die "unknown option $a (only --upgrade)" ;; esac; done

# ---- this Mac ------------------------------------------------------------------------------------------------------------
[[ "$(uname -s)" == Darwin ]] || die "this installs on macOS. (Linux: deploy/linux/foundry.sh.)"
[[ "$(id -u)" -ne 0 ]] || die "do not run this with sudo: Foundry runs as you, and nothing here needs root."
major=$(sw_vers -productVersion | cut -d. -f1); [[ "$major" -ge 14 ]] || die "macOS 14 or newer is required (this is $(sw_vers -productVersion))."
# The release is named for the CPU: arm64 (Apple Silicon) or amd64 (Intel). A shell run under Rosetta reports x86_64 on an Apple Silicon Mac, so the hardware decides.
case "$(uname -m)" in arm64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; *) die "unsupported CPU $(uname -m)" ;; esac
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]] || ARCH=arm64
command -v curl >/dev/null || die "curl is missing"

# ---- release: which revision, and where its tarball for this CPU and its hash are ---------------------------------------------
json_get() { plutil -extract "$2" raw -o - - <<<"$1" 2>/dev/null; } # plutil reads JSON: no python or jq on a fresh Mac
if [[ -n "${FOUNDRY_RELEASE:-}" ]]; then url="$API/repos/$REPO/releases/tags/$FOUNDRY_RELEASE"; else url="$API/repos/$REPO/releases/latest"; fi
meta=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$url") || die "could not read the release from $url (no release yet, a wrong FOUNDRY_RELEASE, or GitHub's unauthenticated rate limit: try again in a few minutes)"
REV=$(json_get "$meta" tag_name) || die "the release at $url has no tag"
[[ "$REV" =~ ^[0-9a-f]{7,40}$ ]] || die "the release tag '$REV' is not a git revision"
NAME="foundry-$REV-darwin-$ARCH.tar.gz"; TGZ="" SHA=""
for i in $(seq 0 20); do
  n=$(json_get "$meta" "assets.$i.name") || break
  case "$n" in "$NAME") TGZ=$(json_get "$meta" "assets.$i.browser_download_url") ;; "$NAME.sha256") SHA=$(json_get "$meta" "assets.$i.browser_download_url") ;; esac
done
[[ -n "$TGZ" && -n "$SHA" ]] || die "release $REV has no $NAME and $NAME.sha256 assets: it is not built for this CPU (Foundry publishes darwin-arm64 and darwin-amd64)"

# ---- already installed: say so, and offer the upgrade --------------------------------------------------------------------------
if [[ -e "$F/control-plane/control.db" || -e "$LA/com.foundry.control.plist" || -e "$LA/com.foundry.hub.plist" ]]; then
  have=$(cat "$F/src/.installed" 2>/dev/null || true)
  if [[ "$have" == "$REV" ]]; then say "Foundry is already installed and is the newest release ($REV). Nothing to do."; exit 0; fi
  say "Foundry is already installed${have:+ (revision $have)}; the newest release is $REV. Use upgrade: your projects, agents and passkeys are kept."
  if [[ "$UPGRADE" != 1 ]]; then
    echo "  to upgrade now:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --upgrade"
    if [[ -r /dev/tty ]]; then read -r -p "Upgrade to $REV now? [y/N] " ans </dev/tty || ans=n; [[ "$ans" == [yY]* ]] && UPGRADE=1; fi
    [[ "$UPGRADE" == 1 ]] || exit 0
  fi
fi

# ---- Command Line Tools: git (the agent runtime's build applies Foundry's patch to the pinned OMP with it). Nothing is compiled here, so no compiler or swift. --------
if ! xcode-select -p >/dev/null 2>&1; then
  say "the Command Line Tools are needed (the agent runtime's build uses git). macOS will show an install dialog: click Install and wait; this continues by itself."
  xcode-select --install >/dev/null 2>&1 || true
  for _ in $(seq 360); do xcode-select -p >/dev/null 2>&1 && break; sleep 5; done
  xcode-select -p >/dev/null 2>&1 || die "the Command Line Tools did not finish installing in 30 minutes. Install them (xcode-select --install), then run this again."
fi

# ---- download and verify -------------------------------------------------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say "downloading Foundry $REV for darwin-$ARCH"
curl -fsSL --retry 3 -o "$TMP/foundry.tar.gz" "$TGZ" || die "could not download $TGZ"
curl -fsSL --retry 3 -o "$TMP/foundry.sha256" "$SHA" || die "could not download $SHA"
want=$(awk '{print $1; exit}' "$TMP/foundry.sha256"); got=$(shasum -a 256 "$TMP/foundry.tar.gz" | awk '{print $1}')
[[ "$want" =~ ^[0-9a-f]{64}$ && "$got" == "$want" ]] || die "the download does not match its published sha256 (got $got, want $want): nothing was installed."
SRC="$F/src/$REV"; mkdir -p "$F/src"; rm -rf "$SRC.new"; mkdir "$SRC.new"
tar -xzf "$TMP/foundry.tar.gz" -C "$SRC.new" || die "could not unpack the release"
[[ -x "$SRC.new/deploy/mac/local-control.sh" && -x "$SRC.new/bin/foundry-hub" && -x "$SRC.new/tools/bun/bin/bun" && -d "$SRC.new/ui" && -d "$SRC.new/Foundry.app" && -s "$SRC.new/VERSION" ]] \
  || die "the release is not a Foundry release for this CPU (it lacks deploy/mac/local-control.sh, bin/, ui/, Foundry.app, tools/bun or VERSION)"
[[ "$(head -1 "$SRC.new/VERSION" | tr -d '[:space:]')" == "$REV" ]] || die "the release says it is revision $(head -1 "$SRC.new/VERSION") but its tag is $REV: refusing it"
rm -rf "$SRC"; mv "$SRC.new" "$SRC"; say "unpacked into $SRC"

# ---- bun: the OMP agent runtime is a bun program and its launcher execs the bun it was built with, so one stays at a fixed path. It is the one in the release (no download).
# Replaced by rename, never overwritten in place: an agent that is running holds the old file open.
mkdir -p "$F/tools/bun/bin"
if ! cmp -s "$SRC/tools/bun/bin/bun" "$F/tools/bun/bin/bun" 2>/dev/null; then
  cp "$SRC/tools/bun/bin/bun" "$F/tools/bun/bin/bun.new" && chmod 755 "$F/tools/bun/bin/bun.new" && mv -f "$F/tools/bun/bin/bun.new" "$F/tools/bun/bin/bun" || die "could not install bun into $F/tools"
fi
export PATH="$F/tools/bun/bin:$PATH"

# ---- install or upgrade --------------------------------------------------------------------------------------------------------
LC="$SRC/deploy/mac/local-control.sh"
if [[ -e "$F/control-plane/control.db" || -e "$LA/com.foundry.control.plist" ]]; then
  "$LC" upgrade --operations --mac-app
  echo "$REV" >"$F/src/.installed"
  say "upgraded to $REV."
else
  rc=0; "$LC" install --fresh --operations --mac-app || rc=$?
  if [[ $rc -ne 0 && $rc -ne 5 ]]; then exit "$rc"; fi
  echo "$REV" >"$F/src/.installed"
  if [[ $rc -eq 0 ]]; then say "Foundry is running. Register your first passkey now: your browser opens on the page, and this is the one-time code (it works once, for 30 minutes):"
  else say "Foundry is installed but launchd did not start it (exit 5, above). This is the one-time passkey code for when it runs (it works once, for 30 minutes from now):"; fi
  "$LC" arm
  if [[ $rc -ne 0 ]]; then exit "$rc"; fi # launchd refused: nothing to open yet; the summary and the code are above
  open "http://localhost:${FOUNDRY_HUB_PORT:-4717}" || true
  open -a "${FOUNDRY_APP_DEST:-/Applications/Foundry.app}" || true
  say "done. After the passkey: Foundry asks for a model login (Settings, Providers) and walks you through your first project and agent. Telegram is optional: deploy/mac/telegram.sh."
fi
# keep this release and the previous one: the app's Upgrade sheet and RepoRoot point into src/
n=0; while IFS= read -r d; do n=$((n + 1)); [[ $n -le 2 ]] || rm -rf "$d"; done < <(ls -dt "$F"/src/*/ 2>/dev/null | sed 's|/$||')
exit 0
}
