#!/usr/bin/env bash
# Hannah: one-command install for macOS (Apple Silicon or Intel). No admin needed.
#
#   curl -fsSL https://vanthlabs.org/install-mac.sh | bash
#
# What it does, all inside your home folder:
#   1. tools: Node 22 (private copy if needed), uv (Python 3.12). Not bun: `hannah hands on` brings it
#   2. NOT the brain: on first run Hannah asks where she should think (Ollama here, installed
#      in your user folder if you say so, or a provider key)
#   3. clones the Hannah repos into ~/Hannah-Motion
#   4. backend + voice/listening sidecars on the CPU, the watches (hannah-sense)
#      and the gesture model (text → motion) on Apple's GPU (MPS) or the CPU
#   5. the overlay app from the latest release (no Apple certificate: the quarantine flag is
#      removed AND the bundle is ad-hoc signed, or macOS never grants it the mic/camera)
#   6. a `hannah` command on your PATH: `hannah` brings everything up and opens the window,
#      `hannah stop` shuts it down, `hannah doctor` tells you what is running.
# Needs: git (Xcode Command Line Tools, the ONE thing that may ask an admin) and curl.
set -u

ORG="Vanth-Labs"
RELEASE_REPO="${ORG}/hannah"
ROOT="${HANNAH_HOME:-$HOME/Hannah-Motion}"
BIN_DIR="$HOME/.local/bin"
TOOLS="$ROOT/.tools"
API="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
DOCS="https://github.com/${ORG}/hannah/blob/main/SETUP.md#macos-and-windows"
KOKORO="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"

if [ -t 1 ]; then
  C_INFO=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi
say()  { printf '%s\n' "${C_DIM}==>${C_OFF} ${C_INFO}$*${C_OFF}"; }
sub()  { printf '%s\n' "    ${C_DIM}$*${C_OFF}"; }
warn() { printf '%s\n' "${C_WARN}warning:${C_OFF} $*" >&2; }
die()  { printf '%s\n' "${C_ERR}error:${C_OFF} $*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }
# step <label> <function>: one line on the terminal, the function's whole output in the log.
# A failed step shows the last lines of the log and the path, then stops. Downloads are NOT
# run through here: their progress bar is the one thing worth seeing.
LOGF=""
step() {
  local label="$1"; shift
  { printf '\n### %s  %s\n' "$(date '+%F %T')" "$label"; } >>"$LOGF"
  if [ -t 1 ]; then
    printf '%s' "${C_DIM}==>${C_OFF} ${C_INFO}$label${C_OFF} "
    "$@" >>"$LOGF" 2>&1 &
    local pid=$! i=0 sp='|/-\\'
    while kill -0 "$pid" 2>/dev/null; do printf '%s\b' "${sp:i++%4:1}"; sleep 0.15; done
    local rc=0; wait "$pid" || rc=$?
  else
    printf '%s' "==> $label "
    local rc=0; "$@" >>"$LOGF" 2>&1 || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then printf '%s\n' "${C_DIM}ok${C_OFF}"; return 0; fi
  printf '%s\n' "${C_ERR}FAILED${C_OFF}"
  tail -n 25 "$LOGF" | sed 's/^/    /'
  die "$label failed. Full log: $LOGF"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# Everything lives inside main() so a `curl | bash` that gets cut off half-way runs NOTHING.
main() {

# ── platform ──────────────────────────────────────────────────────────────────────────
[ "$(uname -s)" = Darwin ] || die "this installer is for macOS. Linux: install.sh · Windows: install.ps1 (see the site)."
case "$(uname -m)" in
  arm64) ARCH=arm64; NODE_ARCH=darwin-arm64 ;;
  x86_64) ARCH=x64; NODE_ARCH=darwin-x64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac
has curl || die "curl is required."
has git  || die "git is required. Run: xcode-select --install   (Apple's Command Line Tools; this is the one step that may ask for an admin) and re-run."
mkdir -p "$BIN_DIR" "$TOOLS" "$HOME/Applications" "$ROOT"
LOGF="$ROOT/.hannah-install.log"; printf '### Hannah install %s\n' "$(date '+%F %T')" >>"$LOGF"
export PATH="$BIN_DIR:$HOME/.bun/bin:$TOOLS/node/bin:$PATH"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fetch() { curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$2" "$1" || die "download failed: $1"; }
fetch_script() { curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"; }

# ── 1. tools, all in $HOME ────────────────────────────────────────────────────────────
say "tools (in your home folder, no admin)"
# only an LTS line with prebuilt native modules (20, 22, 24): a newer node (26) has no
# better-sqlite3 prebuilds and its npm 12 refuses package install scripts (backend without SQLite)
node_ok() { has node && case "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" in 20|22|24) return 0 ;; esac; return 1; }
if ! node_ok; then
  sub "Node 22 (private copy in $TOOLS/node)"
  tgz="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ | grep -oE "node-v22\.[0-9.]+-${NODE_ARCH}\.tar\.gz" | head -1)"
  [ -n "$tgz" ] || die "could not find a Node 22 build for ${NODE_ARCH}"
  fetch "https://nodejs.org/dist/latest-v22.x/$tgz" "$tmp/node.tgz"
  rm -rf "$TOOLS/node"; mkdir -p "$TOOLS/node"; tar -xzf "$tmp/node.tgz" -C "$TOOLS/node" --strip-components=1
  for b in node npm npx; do ln -sf "$TOOLS/node/bin/$b" "$BIN_DIR/$b"; done
fi
node_ok || die "Node 20/22/24 still not usable (is $BIN_DIR on your PATH?)"
install_uv() { fetch_script "https://astral.sh/uv/install.sh" "$tmp/uv.sh" && sh "$tmp/uv.sh"; }
has uv || step "uv (Python 3.12 without touching the system)" install_uv
has uv || die "uv is required and did not install (see $LOGF)"
# bun + the agent (the hands) are NOT installed here: `hannah hands on` does it on demand

# ── 2. the brain is NOT installed here ────────────────────────────────────────────────
# Where Hannah thinks (Ollama on this Mac, or a provider key) is chosen on the FIRST RUN, in
# her window: she detects Ollama if you already have it, installs it in your user folder if
# you ask, and downloads the models with a progress bar.

# ── 3. repos ──────────────────────────────────────────────────────────────────────────
export GIT_TERMINAL_PROMPT=0
clone() {
  if [ -d "$ROOT/$2/.git" ]; then (cd "$ROOT/$2" && git pull -q --ff-only || true); echo "$2 updated"
  else git clone -q "https://github.com/${ORG}/$1.git" "$ROOT/$2" || { echo "could not clone ${ORG}/$1"; return 1; }; echo "$2 cloned"; fi
}
clone_all() {
  # the hannah repo IS the root (launcher, docs, backend/, frontend/, desktop/)
  if [ -d "$ROOT/.git" ]; then
    ( cd "$ROOT" && case "$(git remote get-url origin 2>/dev/null)" in
        *"/${ORG}/workspace"*|*"/Hannah-Motion-Lab/workspace"*) git remote set-url origin "https://github.com/${ORG}/hannah.git" ;;
      esac
      git pull -q --ff-only || true )
    echo "hannah updated"
  else
    rm -rf "$ROOT.tmp"; git clone -q "https://github.com/${ORG}/hannah.git" "$ROOT.tmp" || { echo "could not clone ${ORG}/hannah"; return 1; }
    cp -a "$ROOT.tmp/." "$ROOT/" && rm -rf "$ROOT.tmp"; echo "hannah cloned"
  fi
  migrate_old_layout
}
# Installs from before the single repo: keys, memory, avatar and weights move over; old folders stay.
migrate_old_layout() {
  local old="$ROOT/hannah-backend" moved=""
  if [ -d "$old" ]; then
    [ -f "$old/.env" ] && [ ! -f "$ROOT/backend/.env" ] && cp -p "$old/.env" "$ROOT/backend/.env" && moved="$moved .env"
    if [ -d "$old/data" ] && [ ! -d "$ROOT/backend/data" ]; then cp -a "$old/data" "$ROOT/backend/data" && moved="$moved data/"; fi
  fi
  if [ -d "$ROOT/hannah-motion-lab/runs" ] && [ ! -d "$ROOT/backend/sidecar/gestures/runs" ]; then
    mkdir -p "$ROOT/backend/sidecar/gestures" && cp -a "$ROOT/hannah-motion-lab/runs" "$ROOT/backend/sidecar/gestures/runs" && moved="$moved weights"
  fi
  [ -n "$moved" ] && echo "kept from the previous layout:$moved (old folders hannah-backend/ and hannah-motion-lab/ can be deleted)"
  return 0
}
step "code -> $ROOT" clone_all

# ── 4. backend + sidecars (CPU) ───────────────────────────────────────────────────────
backend_deps() {
  cd "$ROOT/backend"
  # always run: a failed install leaves a partial node_modules, and npm is a fast no-op when complete
  npm install --no-audit --no-fund --no-progress --loglevel=error
  # the SQLite binary must exist for THIS node: an earlier install under another node (or an npm
  # that blocks install scripts) leaves node_modules "complete" but without it, and npm install
  # then does nothing. prebuild-install fetches it in a second.
  [ -e node_modules/better-sqlite3/build/Release/better_sqlite3.node ] || npm rebuild better-sqlite3 --no-audit --no-fund --loglevel=error
  # node-pty ships prebuilds/darwin-*/spawn-helper at 0644 in its tarball; without +x every
  # terminal session dies with "posix_spawnp failed". The backend's postinstall does this too;
  # here it also covers a node_modules that predates it.
  chmod +x node_modules/node-pty/prebuilds/darwin-*/spawn-helper 2>/dev/null || true
  if [ ! -f .env ]; then
    cp .env.example .env
    # local listening; the brain is chosen on first run
    sed -i '' 's/^LLM_MODEL=.*/LLM_MODEL=qwen2.5:7b/; s/^ASR_PROVIDER=.*/ASR_PROVIDER=local/' .env
    tok="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sed -i '' "s|^#\{0,1\}[[:space:]]*HANNAH_AGENT_TOKEN=.*|HANNAH_AGENT_TOKEN=$tok|" .env
    chmod 600 .env
    echo ".env created"
  else echo ".env kept"; fi
}
step "backend (Node dependencies)" backend_deps
sidecar_venv() {
  cd "$ROOT/backend/sidecar"
  [ -x .venv/bin/python ] || uv venv .venv --python 3.12 || return 1
  # onnxruntime-gpu has no macOS wheel (YOLO is opt-in through requirements-vision-yolo.txt)
  sed -e 's/^onnxruntime-gpu==.*/onnxruntime/' requirements.txt > "$tmp/req-mac.txt"
  uv pip install -q -p .venv/bin/python -r "$tmp/req-mac.txt"
}
step "voice and listening (Whisper, Kokoro), CPU" sidecar_venv
# the watches (hannah-sense, :8007): its own venv; on macOS R1/R5 use pgrep and lsof (in the
# system already), R6 (systemd) simply is not offered
sense_venv() {
  cd "$ROOT/backend/sidecar/sense"
  [ -x .venv/bin/python ] || uv venv .venv --python 3.12 || return 1
  uv pip install -q -p .venv/bin/python -r requirements.txt
}
step "watches (hannah-sense)" sense_venv
motion_venv() {
  cd "$ROOT/backend/sidecar/gestures"
  if [ ! -x .venv/bin/python ]; then
    uv venv .venv --python 3.12 || return 1
    # macOS: the PyPI torch build carries MPS (Apple Silicon) and CPU
    uv pip install -q -p .venv/bin/python torch || return 1
  fi
  # every run, not only on creation: a pull can pin a newer model package
  uv pip install -q -p .venv/bin/python -r requirements.txt
}
step "gesture model (text -> motion, on Apple's GPU or the CPU; the big one)" motion_venv
say "gesture model (weights)"
# from huggingface.co/Vanth-Labs/hannah-motion, pinned to a revision inside the package; the Hub
# verifies each file (LFS sha256) and resumes interrupted downloads
( cd "$ROOT/backend/sidecar/gestures"
  if [ -f runs/vae/latest.pt ] && [ -f runs/flow/latest.pt ]; then :; else
    sub "gesture model: vae + flow (390 MB, from Hugging Face)"
    MOTIONLAB_RUNS=runs .venv/bin/python -m motionlab.serve --download-only >>"$LOGF" 2>&1 || die "could not download the gesture weights (see $LOGF)"
  fi
  sub "gestures ✓" )
say "voice model"
( cd "$ROOT/backend/sidecar/tts"
  [ -f kokoro-v1.0.onnx ] || { sub "Kokoro voice model (311 MB)"; fetch "$KOKORO/kokoro-v1.0.onnx" kokoro-v1.0.onnx; }
  [ -f voices-v1.0.bin ]  || { sub "Kokoro voices (27 MB)";       fetch "$KOKORO/voices-v1.0.bin"  voices-v1.0.bin; }
  sub "voice ✓" )

# (the hands, i.e. the agent + bun, are NOT installed here: `hannah hands on` does it on demand)

# ── 6. the overlay app ────────────────────────────────────────────────────────────────
say "overlay app (macOS $ARCH)"
code="$(curl -fsSL -o "$tmp/release.json" -w '%{http_code}' "$API" 2>/dev/null)" || true
[ "${code:-000}" = "200" ] || die "could not read the latest release (HTTP ${code:-network error}). https://github.com/${RELEASE_REPO}/releases"
asset() { grep -o "\"browser_download_url\": *\"[^\"]*$1\"" "$tmp/release.json" | head -n1 | sed 's/.*"\(https[^"]*\)"/\1/'; }
url="$(asset "-mac-${ARCH}.dmg")"; [ -n "$url" ] || die "the latest release has no macOS ($ARCH) build."
sums="$(asset SHA256SUMS)"
if [ -d "$HOME/Applications/Hannah.app" ] && [ "$(defaults read "$HOME/Applications/Hannah.app/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "$(basename "$url" | sed -E 's/^Hannah-([0-9.]+)-.*/\1/')" ]; then
  sub "Hannah.app ✓ (already this version)"
else
  fetch "$url" "$tmp/Hannah.dmg"
  if [ -n "$sums" ] && curl -fsSL -o "$tmp/SHA256SUMS" "$sums"; then
    want="$(grep -E " [*]?$(basename "$url")\$" "$tmp/SHA256SUMS" | awk '{print $1}' | head -1)"
    got="$(shasum -a 256 "$tmp/Hannah.dmg" | awk '{print $1}')"
    [ -z "$want" ] || [ "$got" = "$want" ] || die "checksum mismatch for $(basename "$url"), nothing was installed"
  else warn "no SHA256SUMS: the app was not verified"; fi
  mnt="$tmp/dmg"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -quiet -mountpoint "$mnt" "$tmp/Hannah.dmg" || die "could not mount the dmg"
  rm -rf "$HOME/Applications/Hannah.app"
  cp -R "$mnt/Hannah.app" "$HOME/Applications/Hannah.app" || { hdiutil detach -quiet "$mnt"; die "could not copy Hannah.app"; }
  hdiutil detach -quiet "$mnt" || true
  # unsigned build: without this macOS says the app "is damaged"/"can't be opened"
  xattr -dr com.apple.quarantine "$HOME/Applications/Hannah.app" 2>/dev/null || true
  sub "Hannah.app → ~/Applications ✓"
fi
# ── 6b. the microphone: ad-hoc signature ──────────────────────────────────────────────
# macOS keys mic/camera access to the entitlement com.apple.security.device.audio-input, and
# entitlements only exist inside a code signature: an unsigned bundle never even gets the
# permission prompt (tccd: "Policy disallows prompt"), so Hannah is deaf with no error anywhere.
# Releases from 1.0.15 come signed ad-hoc with the entitlements; this re-signs in place so older
# DMGs work too. Ad-hoc needs no Apple account, no certificate, no admin, and re-signing is
# idempotent. OUTSIDE the version check on purpose: an app already at this version must be
# signed as well.
if [ -d "$HOME/Applications/Hannah.app" ] && has codesign; then
  say "microphone + camera (ad-hoc signature)"
  cat > "$tmp/hannah.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST
  # inside-out: the nested helpers and frameworks first, the outer bundle last
  find "$HOME/Applications/Hannah.app/Contents/Frameworks" -depth \
       \( -name '*.app' -o -name '*.framework' -o -name '*.dylib' -o -name '*.node' \) \
       -exec codesign --force --sign - --options runtime --entitlements "$tmp/hannah.entitlements" {} \; 2>/dev/null || true
  codesign --force --sign - --options runtime --entitlements "$tmp/hannah.entitlements" "$HOME/Applications/Hannah.app" 2>/dev/null || true
  if codesign -d --entitlements - "$HOME/Applications/Hannah.app" 2>/dev/null | grep -q 'security\.device\.audio-input'; then
    sub "signed ✓ (macOS can now ask for the mic and the camera)"
  else
    warn "could not sign Hannah.app: macOS will never ask for the microphone. See ${DOCS}"
  fi
fi

# ── 7. the launcher ───────────────────────────────────────────────────────────────────
chmod +x "$ROOT/hannah-mac"
ln -sf "$ROOT/hannah-mac" "$BIN_DIR/hannah"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not in your PATH. Add it with:"
     printf '       %s\n' "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac

cat <<EOF

  ${C_INFO}Hannah is installed.${C_OFF}   ${C_DIM}($ROOT)${C_OFF}

  Run her (brings up voice, listening, gestures and the overlay; the first time she asks where to think):

      ${C_WARN}hannah${C_OFF}

  Other commands:
      hannah doctor     what is running
      hannah stop       shut everything down
      hannah hands on   install and enable the hands (multi-step tasks; needs an API key)
      hannah uninstall  remove it all (Ollama and its models stay)
  Install log: ${LOGF}

  On macOS the voice runs on the CPU and the gestures on Apple's GPU (MPS) or the CPU: each
  sentence takes a bit longer to prepare than with an NVIDIA card, but she moves while she speaks.
  Nothing else was installed: no Ollama, no language model, that is her first question.

  Let her act on this Mac (terminal, apps, commands): the switch in the overlay, ⚙ -> Manos.

  Docs: ${DOCS}

EOF
}

main "$@"
