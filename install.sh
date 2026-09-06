#!/usr/bin/env bash
# Hannah installer: the WHOLE companion, not just the window.
#
#   curl -fsSL https://vanthlabs.org/install.sh | bash
#
# What it sets up, in order (each step is skipped if already done, so re-running is safe):
#   1. system packages (git, python, uv, unzip) via your distro's package manager; Node 22 as a
#      private copy if your system Node is not an LTS with prebuilt native modules
#   2. NOT the brain: on first run Hannah asks where she should think (Ollama here, installed
#      in your user folder if you say so, or a provider key), nothing of that runs from here
#   3. the code under ~/Hannah-Motion (the hannah repo)
#   4. Node deps for the backend, Python venvs for the sidecars (voice, listening, the watch
#      sidecar hannah-sense) and the gesture model
#   5. the weights that are not in git: Kokoro voice (from upstream) and the trained
#      text->motion model (from Hannah's GitHub release)
#   6. the overlay AppImage (it carries the frontend), and the `hannah` launcher on your PATH
#
# NOT installed until you ask: the agent (the "hands": `hannah hands on`) and the YOLO vision
# provider (sidecar/requirements-vision-yolo.txt); both are off by default.
# Output: one line per step; everything each step prints goes to ~/Hannah-Motion/.hannah-install.log.
#
# Why not a single package: the stack is several GB of Python/CUDA environments and models that
# must be built and downloaded on YOUR machine (GPU-specific wheels, non-redistributable
# models). The AppImage alone is only the window, it needs all of this behind it.
set -euo pipefail

ORG="Vanth-Labs"
RELEASE_REPO="${ORG}/hannah"
ROOT="${HANNAH_HOME:-$HOME/Hannah-Motion}"
BIN_DIR="$HOME/.local/bin"
API="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
# the gesture model's weights (~400 MB, used by the Python motion server, not by the app):
# a release of their own so the app release only lists apps
SITE="https://vanthlabs.org"
DOCS="https://github.com/${ORG}/hannah#readme"
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
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# Everything below lives inside main() so a `curl | bash` that gets cut off half-way runs
# NOTHING: bash only executes the function once its closing brace has arrived.
main() {

# ── platform ──────────────────────────────────────────────────────────────────────────
case "$(uname -s -m)" in
  "Linux x86_64") ;;
  "Linux aarch64"|"Linux arm64") die "only x86_64 is supported right now (got $(uname -m))." ;;
  Darwin*) die "this installer supports Linux only. macOS: see ${DOCS}" ;;
  CYGWIN*|MINGW*|MSYS*) die "this installer supports Linux only. Windows: see ${DOCS}" ;;
  *) die "unsupported platform: $(uname -s -m)." ;;
esac

mkdir -p "$ROOT"
LOGF="$ROOT/.hannah-install.log"; printf '### Hannah install %s\n' "$(date '+%F %T')" >>"$LOGF"

# ── 1. system packages ────────────────────────────────────────────────────────────────
say "system packages"
if has pacman; then
  PKG="sudo pacman -S --needed --noconfirm"; PKGS="git nodejs npm python python-pip uv unzip curl"
elif has apt-get; then
  PKG="sudo apt-get install -y"; PKGS="git nodejs npm python3 python3-pip python3-venv unzip curl"
elif has dnf; then
  PKG="sudo dnf install -y"; PKGS="git nodejs npm python3 python3-pip unzip curl"
else
  warn "unknown package manager: make sure git, node 20+, python 3.12+, unzip and curl are installed"; PKG=""; PKGS=""
fi
missing=""
for c in git python3 unzip curl; do has "$c" || missing="$missing $c"; done   # node: see below (private copy if needed)
if [ -n "$missing" ] && [ -n "$PKG" ]; then
  sub "installing:$missing (your distro's package manager, needs sudo)"
  $PKG $PKGS   # visible on purpose: sudo asks for the password here
fi
has python3 || die "python3 is required (3.12+)."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Node: only an LTS line with prebuilt native modules (20, 22, 24). Anything else (e.g. Node 26
# on Arch: no better-sqlite3 prebuilds, and its npm 12 refuses to run package install scripts)
# leaves the backend without its SQLite binary ("Could not locate the bindings file"). In that
# case a private Node 22 goes to $ROOT/.tools/node; the launcher puts it first on its PATH.
# The system node is never touched or shadowed.
TOOLS="$ROOT/.tools"
node_lts_ok() { has node && case "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" in 20|22|24) return 0 ;; esac; return 1; }
if [ -x "$TOOLS/node/bin/node" ]; then export PATH="$TOOLS/node/bin:$PATH"; fi
if ! node_lts_ok; then
  case "$(uname -m)" in x86_64) NODE_ARCH=linux-x64 ;; aarch64|arm64) NODE_ARCH=linux-arm64 ;; *) die "no Node 22 build for $(uname -m)" ;; esac
  sub "Node 22 (private copy in $TOOLS/node; your system node $(node -v 2>/dev/null || echo 'is missing') stays as it is)"
  tgz="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ | grep -oE "node-v22\.[0-9.]+-${NODE_ARCH}\.tar\.gz" | head -1)"
  [ -n "$tgz" ] || die "could not find a Node 22 build for ${NODE_ARCH}"
  curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$tmp/node.tgz" "https://nodejs.org/dist/latest-v22.x/$tgz" || die "download failed: $tgz"
  mkdir -p "$TOOLS"; rm -rf "$TOOLS/node"; mkdir -p "$TOOLS/node"; tar -xzf "$tmp/node.tgz" -C "$TOOLS/node" --strip-components=1
  export PATH="$TOOLS/node/bin:$PATH"
fi
node_lts_ok || die "node 20/22/24 is required (found $(node -v 2>/dev/null || echo none))."
# third-party installers: to a file first, then run, never `curl | sh` (a cut-off download
# would otherwise run half a script). Their content is whatever the vendor serves today.
fetch_script() { curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"; }
# uv creates the venvs far faster than pip; install it to the user if the distro has none.
install_uv() { fetch_script "https://astral.sh/uv/install.sh" "$tmp/uv-install.sh" && sh "$tmp/uv-install.sh"; }
if ! has uv; then
  step "uv (fast Python installer, into ~/.local/bin)" install_uv || true
  export PATH="$HOME/.local/bin:$PATH"
  has uv || warn "uv install failed; falling back to pip (slower)"
fi
NVIDIA=""
if has nvidia-smi && nvidia-smi >/dev/null 2>&1; then NVIDIA=1; sub "NVIDIA GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
else warn "no NVIDIA GPU detected: the voice and gesture models will run on CPU (slower)."; fi

# ── 2. the brain is NOT installed here ────────────────────────────────────────────────
# Where Hannah thinks (Ollama on this PC, or a provider key) is chosen on the FIRST RUN, in
# her window: she detects Ollama if you already have it, installs it in your user folder if
# you ask, and downloads the models with a progress bar. Nothing of that belongs in a script.

# ── 3. repos ──────────────────────────────────────────────────────────────────────────
# git must never prompt for a password in a piped install: fail fast with a clear message.
export GIT_TERMINAL_PROMPT=0
clone() {  # clone <repo> <dir>
  if [ -d "$ROOT/$2/.git" ]; then (cd "$ROOT/$2" && git pull -q --ff-only || true); echo "$2 updated"
  else
    git clone -q "https://github.com/${ORG}/$1.git" "$ROOT/$2" \
      || { echo "could not clone ${ORG}/$1. If the repo is private you need access; otherwise check your connection."; return 1; }
    echo "$2 cloned"
  fi
}
clone_all() {
  # the hannah repo IS the root (launcher, docs, backend/, frontend/, desktop/)
  if [ -d "$ROOT/.git" ]; then
    # an install from before the single repo points at the old workspace repo: same history, so a
    # remote switch and a pull bring the folders in without touching anything else
    ( cd "$ROOT" && case "$(git remote get-url origin 2>/dev/null)" in
        *"/${ORG}/workspace"*|*"/Hannah-Motion-Lab/workspace"*) git remote set-url origin "https://github.com/${ORG}/hannah.git" ;;
      esac
      git pull -q --ff-only || true )
    echo "hannah updated"
  else
    rm -rf "$ROOT.tmp"   # a previous run that died mid-clone leaves this behind
    git clone -q "https://github.com/${ORG}/hannah.git" "$ROOT.tmp" || { echo "could not clone ${ORG}/hannah"; return 1; }
    cp -a "$ROOT.tmp/." "$ROOT/" && rm -rf "$ROOT.tmp"; echo "hannah cloned"
  fi
  # the agent (hands) comes with `hannah hands on`; the gesture model is a package, installed below
  migrate_old_layout
}
# Installs from before the single repo had hannah-backend/, hannah-motion-lab/ and
# hannah-desktop/ as separate clones. What matters to the user moves over (keys, memory, the
# avatar, the downloaded weights); the old clones stay until the user removes them.
migrate_old_layout() {
  local old="$ROOT/hannah-backend" moved=""
  if [ -d "$old" ]; then
    [ -f "$old/.env" ] && [ ! -f "$ROOT/backend/.env" ] && cp -p "$old/.env" "$ROOT/backend/.env" && moved="$moved .env"
    if [ -d "$old/data" ] && [ ! -d "$ROOT/backend/data" ]; then cp -a "$old/data" "$ROOT/backend/data" && moved="$moved data/"; fi
  fi
  if [ -d "$ROOT/hannah-motion-lab/runs" ] && [ ! -d "$ROOT/backend/sidecar/gestures/runs" ]; then
    mkdir -p "$ROOT/backend/sidecar/gestures" && cp -a "$ROOT/hannah-motion-lab/runs" "$ROOT/backend/sidecar/gestures/runs" && moved="$moved weights"
  fi
  [ -n "$moved" ] && echo "kept from the previous layout:$moved (old folders hannah-backend/, hannah-motion-lab/, hannah-desktop/ can be deleted)"
  return 0
}
step "code -> $ROOT" clone_all

# ── 4. dependencies ───────────────────────────────────────────────────────────────────
backend_deps() {
  cd "$ROOT/backend"
  # always run: a failed install leaves a partial node_modules, and npm is a fast no-op when complete
  npm install --no-audit --no-fund --no-progress --loglevel=error
  # the SQLite binary must exist for THIS node: an earlier install under another node (or an npm
  # that blocks install scripts) leaves node_modules "complete" but without it, and npm install
  # then does nothing. prebuild-install fetches it in a second.
  [ -e node_modules/better-sqlite3/build/Release/better_sqlite3.node ] || npm rebuild better-sqlite3 --no-audit --no-fund --loglevel=error
  if [ ! -f .env ]; then
    cp .env.example .env
    # defaults that make it work on the first try: the brain that is best at actions, and
    # the local ASR (the example points at the cloud, which needs an OpenAI key)
    sed -i 's/^LLM_MODEL=.*/LLM_MODEL=qwen2.5:7b/; s/^ASR_PROVIDER=.*/ASR_PROVIDER=local/' .env
    # the backend<->agent bearer: generated now so the agent is never reachable without it
    tok="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sed -i "s|^#\?[[:space:]]*HANNAH_AGENT_TOKEN=.*|HANNAH_AGENT_TOKEN=$tok|" .env
    chmod 600 .env
    echo ".env created"
  else echo ".env kept"; fi
}
step "backend (Node dependencies)" backend_deps
# the voice sidecars: faster-whisper + Kokoro. No torch and no YOLO here: the vision provider
# (VISION_PROVIDER=yolo) is opt-in through sidecar/requirements-vision-yolo.txt, and the CUDA
# libs Kokoro/Whisper need are preloaded from the gesture model's venv (sidecar/common.py).
sidecar_venv() {
  cd "$ROOT/backend/sidecar"
  if [ ! -x .venv/bin/python ]; then
    if has uv; then uv venv .venv --python 3.12 || uv venv .venv
    else python3 -m venv .venv; fi
  fi
  # every run: a pull can change requirements.txt (a no-op when nothing changed)
  if has uv; then uv pip install -q -p .venv/bin/python -r requirements.txt; else .venv/bin/pip install -q -r requirements.txt; fi
}
step "voice and listening (Whisper, Kokoro)" sidecar_venv
# hannah-sense (:8007, the watches) gets its OWN venv, with --system-site-packages so the
# screen and AT-SPI rungs can reach `gi`/`dbus`, which are distro packages. It is NOT the venv
# above: that one pins numpy and onnxruntime-gpu for faster-whisper and Kokoro, and letting the
# system site-packages in would break the voice at runtime and in silence.
sense_venv() {
  cd "$ROOT/backend/sidecar/sense"
  if [ ! -x .venv/bin/python ]; then
    if has uv; then uv venv .venv --python 3.12 --system-site-packages || uv venv .venv --system-site-packages
    else python3 -m venv --system-site-packages .venv; fi
  fi
  if has uv; then uv pip install -q -p .venv/bin/python -r requirements.txt; else .venv/bin/pip install -q -r requirements.txt; fi
}
step "watches (hannah-sense)" sense_venv
motion_venv() {
  cd "$ROOT/backend/sidecar/gestures"
  if [ ! -x .venv/bin/python ]; then
    if has uv; then
      uv venv .venv --python 3.12 || uv venv .venv
      # torch must come from the CUDA 12.8 index (RTX 50xx needs it; older GPUs work too)
      if [ -n "$NVIDIA" ]; then uv pip install -q -p .venv/bin/python torch --index-url https://download.pytorch.org/whl/cu128
      else uv pip install -q -p .venv/bin/python torch --index-url https://download.pytorch.org/whl/cpu; fi
    else
      python3 -m venv .venv
      if [ -n "$NVIDIA" ]; then .venv/bin/pip install -q torch --index-url https://download.pytorch.org/whl/cu128
      else .venv/bin/pip install -q torch --index-url https://download.pytorch.org/whl/cpu; fi
    fi
  fi
  # every run, not only on creation: a pull can pin a newer model package
  if has uv; then uv pip install -q -p .venv/bin/python -r requirements.txt; else .venv/bin/pip install -q -r requirements.txt; fi
}
step "gesture model (text -> motion, torch $([ -n "$NVIDIA" ] && echo CUDA || echo CPU); the big one)" motion_venv

# ── 5. weights that are not in git ────────────────────────────────────────────────────
say "model weights"
# download to a temp file, verify against SHA256SUMS when the release ships one, then move into
# place, a half-written file never gets the final name, and a tampered one never gets used.
dl() {
  local part="$2.part"
  curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$part" "$1" || { rm -f "$part"; die "download failed: $1"; }
  if [ -s "$tmp/SHA256SUMS" ]; then
    local want; want="$(grep -E " [*]?$(basename "$1")\$" "$tmp/SHA256SUMS" | awk '{print $1}' | head -1)"
    if [ -n "$want" ]; then
      local got; got="$(sha256sum "$part" | awk '{print $1}')"
      [ "$got" = "$want" ] || { rm -f "$part"; die "checksum mismatch for $(basename "$1"), the download is corrupt or tampered; nothing was installed"; }
    else warn "$(basename "$1") is not listed in SHA256SUMS: installed unverified"; fi
  fi
  mv -f "$part" "$2"
}
( cd "$ROOT/backend/sidecar/tts"
  [ -f kokoro-v1.0.onnx ] || { sub "Kokoro voice model (311 MB)"; dl "$KOKORO/kokoro-v1.0.onnx" kokoro-v1.0.onnx; }
  [ -f voices-v1.0.bin ]  || { sub "Kokoro voices (27 MB)";       dl "$KOKORO/voices-v1.0.bin"  voices-v1.0.bin; }
  sub "voice ✓" )
say "looking up the latest Hannah release"
code="$(curl -fsSL -o "$tmp/release.json" -w '%{http_code}' "$API" 2>/dev/null)" || true
[ "${code:-000}" = "200" ] || die "could not read the latest release (HTTP ${code:-network error}). https://github.com/${RELEASE_REPO}/releases"
asset() { grep -o "\"browser_download_url\": *\"[^\"]*$1\"" "$tmp/release.json" | head -n1 | sed 's/.*"\(https[^"]*\)"/\1/'; }
sums="$(asset SHA256SUMS)"
if [ -n "$sums" ]; then curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/SHA256SUMS" "$sums" || warn "could not fetch SHA256SUMS: downloads will not be verified"
else warn "this release ships no SHA256SUMS: downloads will not be verified"; fi
say "gesture model (weights)"
# from huggingface.co/Vanth-Labs/hannah-motion, pinned to a revision inside the package; the Hub
# verifies each file (LFS sha256) and resumes interrupted downloads
( cd "$ROOT/backend/sidecar/gestures"
  if [ -f runs/vae/latest.pt ] && [ -f runs/flow/latest.pt ]; then :; else
    sub "gesture model: vae + flow (390 MB, from Hugging Face)"
    MOTIONLAB_RUNS=runs .venv/bin/python -m motionlab.serve --download-only >>"$LOGF" 2>&1 || die "could not download the gesture weights (see $LOGF)"
  fi
  sub "gestures ✓" )

# ── 6. the overlay + launcher on PATH ─────────────────────────────────────────────────
# (the hands, i.e. the agent + bun, are NOT installed here: `hannah hands on` does it on demand)
say "overlay (AppImage)"
url="$(asset '.AppImage')"; [ -n "$url" ] || die "the latest release has no AppImage."
mkdir -p "$BIN_DIR"
if [ ! -x "$BIN_DIR/Hannah.AppImage" ]; then
  dl "$url" "$tmp/Hannah.AppImage"; mv -f "$tmp/Hannah.AppImage" "$BIN_DIR/Hannah.AppImage"; chmod +x "$BIN_DIR/Hannah.AppImage"
fi
sub "AppImage ✓"
# the launcher: `hannah` from anywhere brings up the stack and opens the overlay
chmod +x "$ROOT/hannah"
ln -sf "$ROOT/hannah" "$BIN_DIR/hannah"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not in your PATH. Add it with:"
     printf '       %s\n' "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
esac

cat <<EOF

  ${C_INFO}Hannah is installed.${C_OFF}   ${C_DIM}($ROOT)${C_OFF}

  Run her (brings up the brain, voice, gestures and the overlay):

      ${C_WARN}hannah${C_OFF}

  Other commands:
      hannah doctor     what works on this desktop and what is missing
      hannah stop       shut everything down and free the GPU
      hannah hands on   install and enable the hands (multi-step tasks; needs an API key)
      hannah uninstall  remove it all (Ollama and its models stay)

  Let her act on this PC (terminal, apps, commands): the switch in the overlay, ⚙ -> Manos.
  Install log: ${LOGF}
  Docs: ${DOCS}
  Overlay won't stay on top / FUSE error? see the README, or run once with:
      ${BIN_DIR}/Hannah.AppImage --appimage-extract-and-run

EOF
}

main "$@"
