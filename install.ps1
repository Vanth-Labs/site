# Hannah: one-command install for Windows 10/11 (x64). No admin needed.
#
#   irm https://vanthlabs.org/install.ps1 | iex
#
# Everything is installed for YOUR user only, nothing touches Program Files or the registry
# beyond your own PATH:
#   1. tools as portable copies in %USERPROFILE%\Hannah-Motion\.tools: Git (MinGit), Node 22;
#      uv (Python 3.12) in your profile. Not bun: `hannah hands on` brings the agent on demand
#   2. NOT the brain: on first run Hannah asks where she should think (Ollama here, installed
#      per-user if you say so, or a provider key)
#   3. clones the Hannah repos into %USERPROFILE%\Hannah-Motion
#   4. backend + voice/listening sidecars, the watches (hannah-sense) and the
#      gesture model (text -> motion) on your NVIDIA card if there is one, else on the CPU
#   5. the overlay app from the latest release (per-user install, silent)
#   6. a `hannah` command: `hannah` brings everything up and opens the window,
#      `hannah stop` shuts it down, `hannah doctor` tells you what is running.
#   Output: one line per step; the details go to %USERPROFILE%\Hannah-Motion\.hannah-install.log
# If PowerShell refuses to run scripts:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

function Install-Hannah {
  # 'Continue', not 'Stop': in Windows PowerShell 5.1 a native program that writes to stderr
  # (bun, npm, git, uv all do) becomes a terminating NativeCommandError under 'Stop'. Failures
  # are checked by hand ($LASTEXITCODE) and the cmdlets that matter carry -ErrorAction Stop.
  $ErrorActionPreference = 'Continue'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $Org = 'Vanth-Labs'
  $Root = if ($env:HANNAH_HOME) { $env:HANNAH_HOME } else { Join-Path $env:USERPROFILE 'Hannah-Motion' }
  $Tools = Join-Path $Root '.tools'
  $Api = "https://api.github.com/repos/$Org/hannah/releases/latest"
  $Docs = "https://github.com/$Org/hannah/blob/main/SETUP.md#macos-and-windows"
  $Kokoro = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0'

  function Say($m)  { Write-Host "==> $m" -ForegroundColor Green }
  function Sub($m)  { Write-Host "    $m" -ForegroundColor DarkGray }
  function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
  function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; throw $m }
  function Has($c)  { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
  function Fetch($url, $out) { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop }
  # Invoke-Step 'label' { block }: one line on the console, the block's whole output in the log.
  # A failed step shows the last lines of the log and the path, then stops. Downloads keep
  # their own progress; they are not run through here.
  $script:LogF = $null
  function Invoke-Step($label, [scriptblock]$block) {
    Add-Content $script:LogF "`n### $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $label"
    Write-Host "==> $label " -ForegroundColor Green -NoNewline
    $global:LASTEXITCODE = 0
    $failed = $false
    try { & $block *>> $script:LogF; if ($LASTEXITCODE) { $failed = $true } } catch { Add-Content $script:LogF "$_"; $failed = $true }
    if (-not $failed) { Write-Host 'ok' -ForegroundColor DarkGray; return }
    Write-Host 'FAILED' -ForegroundColor Red
    Get-Content $script:LogF -Tail 25 | ForEach-Object { Write-Host "    $_" }
    Die "$label failed. Full log: $script:LogF"
  }
  function Add-UserPath($dir) {
    if (-not (Test-Path $dir)) { return }
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($cur -split ';') -notcontains $dir) { [Environment]::SetEnvironmentVariable('Path', "$dir;$cur", 'User') }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
  }

  if (-not [Environment]::Is64BitOperatingSystem) { Die 'Hannah needs 64-bit Windows.' }
  New-Item -ItemType Directory -Force -Path $Root, $Tools | Out-Null
  $script:LogF = Join-Path $Root '.hannah-install.log'
  Add-Content $script:LogF "### Hannah install $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("hannah-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null

  # -- 1. tools, portable, in your profile ----------------------------------------------
  Say 'tools (portable copies in your profile, no admin)'
  if (-not (Has git)) {
    Sub 'Git (MinGit, portable)'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UseBasicParsing -ErrorAction Stop
    $a = $rel.assets | Where-Object { $_.name -match '^MinGit-[\d.]+-64-bit\.zip$' } | Select-Object -First 1
    if (-not $a) { Die 'could not find a MinGit build' }
    Fetch $a.browser_download_url "$tmp\git.zip"
    Expand-Archive "$tmp\git.zip" -DestinationPath "$Tools\git" -Force -ErrorAction Stop
    Add-UserPath "$Tools\git\cmd"
  }
  # only an LTS line with prebuilt native modules (20, 22, 24): a newer node has no
  # better-sqlite3 prebuilds and its npm 12 refuses package install scripts (backend without SQLite)
  $nodeMajor = if (Has node) { [int]((node -p 'process.versions.node.split(".")[0]') 2>$null) } else { 0 }
  $nodeOk = @(20, 22, 24) -contains $nodeMajor
  if (-not $nodeOk) {
    Sub 'Node 22 (portable)'
    $idx = Invoke-WebRequest 'https://nodejs.org/dist/latest-v22.x/' -UseBasicParsing
    $zip = ([regex]'node-v22\.[\d.]+-win-x64\.zip').Match($idx.Content).Value
    if (-not $zip) { Die 'could not find a Node 22 build' }
    Fetch "https://nodejs.org/dist/latest-v22.x/$zip" "$tmp\node.zip"
    Expand-Archive "$tmp\node.zip" -DestinationPath "$tmp\node" -Force -ErrorAction Stop
    if (Test-Path "$Tools\node") { Remove-Item "$Tools\node" -Recurse -Force }
    Move-Item (Get-ChildItem "$tmp\node" | Select-Object -First 1).FullName "$Tools\node" -ErrorAction Stop
    Add-UserPath "$Tools\node"
  }
  if (-not (Has uv)) {
    Invoke-Step 'uv (Python 3.12 without touching the system)' {
      Fetch 'https://astral.sh/uv/install.ps1' "$tmp\uv.ps1"
      & powershell -NoProfile -ExecutionPolicy Bypass -File "$tmp\uv.ps1"
    }
    Add-UserPath (Join-Path $env:USERPROFILE '.local\bin')
  }
  # bun + the agent (the hands) are NOT installed here: `hannah hands on` does it on demand
  # -- 2. the brain is NOT installed here ---------------------------------------------
  # Where Hannah thinks (Ollama on this PC, or a provider key) is chosen on the FIRST RUN, in
  # her window: she detects Ollama if you already have it, installs it per-user if you ask,
  # and downloads the models with a progress bar.

  # -- 3. repos ------------------------------------------------------------------------
  function Clone($repo, $dir) {
    $d = Join-Path $Root $dir
    if (Test-Path (Join-Path $d '.git')) { Push-Location $d; git pull -q --ff-only 2>$null; Pop-Location; Write-Output "$dir updated" }
    else { git clone -q "https://github.com/$Org/$repo.git" $d; if ($LASTEXITCODE) { throw "could not clone $Org/$repo" }; Write-Output "$dir cloned" }
  }
  Invoke-Step "code -> $Root" {
    # the hannah repo IS the root (launcher, docs, backend\, frontend\, desktop\)
    if (Test-Path (Join-Path $Root '.git')) {
      Push-Location $Root
      $origin = (git remote get-url origin 2>$null)
      if ($origin -match '/(Vanth-Labs|Hannah-Motion-Lab)/workspace') { git remote set-url origin "https://github.com/$Org/hannah.git" }
      git pull -q --ff-only 2>$null
      Pop-Location; Write-Output 'hannah updated'
    }
    else {
      if (Test-Path "$Root.tmp") { Remove-Item "$Root.tmp" -Recurse -Force }
      git clone -q "https://github.com/$Org/hannah.git" "$Root.tmp"; if ($LASTEXITCODE) { throw "could not clone $Org/hannah" }
      Copy-Item "$Root.tmp\*" $Root -Recurse -Force; Remove-Item "$Root.tmp" -Recurse -Force; Write-Output 'hannah cloned'
    }
    # installs from before the single repo: keys, memory, avatar and weights move over; old folders stay
    $old = Join-Path $Root 'hannah-backend'; $moved = @()
    if (Test-Path $old) {
      if ((Test-Path "$old\.env") -and -not (Test-Path "$Root\backend\.env")) { Copy-Item "$old\.env" "$Root\backend\.env"; $moved += '.env' }
      if ((Test-Path "$old\data") -and -not (Test-Path "$Root\backend\data")) { Copy-Item "$old\data" "$Root\backend\data" -Recurse; $moved += 'data' }
    }
    if ((Test-Path "$Root\hannah-motion-lab\runs") -and -not (Test-Path "$Root\backend\sidecar\gestures\runs")) { New-Item -ItemType Directory -Force -Path "$Root\backend\sidecar\gestures" | Out-Null; Copy-Item "$Root\hannah-motion-lab\runs" "$Root\backend\sidecar\gestures\runs" -Recurse; $moved += 'weights' }
    if ($moved.Count) { Write-Output ("kept from the previous layout: " + ($moved -join ', ') + " (old folders hannah-backend and hannah-motion-lab can be deleted)") }
    # the agent (hands) comes with `hannah hands on`; the app carries the frontend
    $global:LASTEXITCODE = 0
  }
  Add-UserPath $Root   # `hannah` (hannah.cmd) is usable from a NEW terminal from this point on

  # -- 4. backend + sidecars (CPU) -----------------------------------------------------
  $back = Join-Path $Root 'backend'
  Push-Location $back
  Invoke-Step 'backend (Node dependencies)' {
    # always run: a failed install leaves a partial node_modules, and npm is a fast no-op when complete
    npm install --no-audit --no-fund --no-progress --loglevel=error; if ($LASTEXITCODE) { throw 'npm install failed in backend' }
    # the SQLite binary must exist for THIS node: an earlier install under another node leaves
    # node_modules "complete" without it and npm install then does nothing
    if (-not (Test-Path 'node_modules\better-sqlite3\build\Release\better_sqlite3.node')) { npm rebuild better-sqlite3 --no-audit --no-fund --loglevel=error; if ($LASTEXITCODE) { throw 'better-sqlite3 has no binary for this node' } }
  }
  if (-not (Test-Path '.env')) {
    $envText = Get-Content '.env.example' -Raw
    $envText = $envText -replace '(?m)^LLM_MODEL=.*$', 'LLM_MODEL=qwen2.5:7b' -replace '(?m)^ASR_PROVIDER=.*$', 'ASR_PROVIDER=local'
    $tok = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $envText = $envText -replace '(?m)^#?\s*HANNAH_AGENT_TOKEN=.*$', "HANNAH_AGENT_TOKEN=$tok"
    Set-Content '.env' $envText -NoNewline
    Sub '.env created (edit it to enable tools/terminal/agent)'
  } else { Sub '.env kept' }
  Push-Location 'sidecar'
  Invoke-Step 'voice and listening (Whisper, Kokoro), CPU' {
    if (-not (Test-Path '.venv\Scripts\python.exe')) { uv venv .venv --python 3.12; if ($LASTEXITCODE) { throw 'uv could not create the venv' } }
    # onnxruntime-gpu needs CUDA libs we do not ship here (YOLO is opt-in through requirements-vision-yolo.txt)
    (Get-Content 'requirements.txt') -replace '^onnxruntime-gpu==.*$', 'onnxruntime' | Set-Content "$tmp\req-win.txt"
    uv pip install -q -p .venv\Scripts\python.exe -r "$tmp\req-win.txt"; if ($LASTEXITCODE) { throw 'sidecar dependencies failed' }
  }
  Pop-Location
  # the watches (hannah-sense, :8007): its own venv; on Windows R1/R5 use psutil (no pgrep/ss)
  Push-Location 'sidecar\sense'
  Invoke-Step 'watches (hannah-sense)' {
    if (-not (Test-Path '.venv\Scripts\python.exe')) { uv venv .venv --python 3.12; if ($LASTEXITCODE) { throw 'uv could not create the sense venv' } }
    uv pip install -q -p .venv\Scripts\python.exe -r requirements.txt; if ($LASTEXITCODE) { throw 'sense dependencies failed' }
  }
  Pop-Location
  $lab = Join-Path $back 'sidecar\gestures'
  Push-Location $lab
  $nvidia = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
  Invoke-Step "gesture model (text -> motion, torch $(if ($nvidia) { 'CUDA' } else { 'CPU' }); the big one)" {
    if (-not (Test-Path '.venv\Scripts\python.exe')) {
      uv venv .venv --python 3.12; if ($LASTEXITCODE) { throw 'uv could not create the motion venv' }
      if ($nvidia) { uv pip install -q -p .venv\Scripts\python.exe torch --index-url https://download.pytorch.org/whl/cu128 }
      else { uv pip install -q -p .venv\Scripts\python.exe torch --index-url https://download.pytorch.org/whl/cpu }
      if ($LASTEXITCODE) { throw 'torch install failed' }
    }
    # every run, not only on creation: a pull can pin a newer model package
    uv pip install -q -p .venv\Scripts\python.exe -r requirements.txt; if ($LASTEXITCODE) { throw 'motion dependencies failed' }
  }
  # weights from huggingface.co/Vanth-Labs/hannah-motion, pinned to a revision inside the package
  if (-not ((Test-Path 'runs\vae\latest.pt') -and (Test-Path 'runs\flow\latest.pt'))) {
    Sub 'gesture model: vae + flow (390 MB, from Hugging Face)'
    $env:MOTIONLAB_RUNS = 'runs'
    & .venv\Scripts\python.exe -m motionlab.serve --download-only 2>&1 | Out-File -Append $script:LogF
    if ($LASTEXITCODE) { Die "could not download the gesture weights (see $script:LogF)" }
  }
  Sub 'gestures ok'
  Pop-Location
  Say 'voice model'
  $tts = Join-Path $back 'sidecar\tts'
  if (-not (Test-Path "$tts\kokoro-v1.0.onnx")) { Sub 'Kokoro voice model (311 MB)'; Fetch "$Kokoro/kokoro-v1.0.onnx" "$tts\kokoro-v1.0.onnx" }
  if (-not (Test-Path "$tts\voices-v1.0.bin"))  { Sub 'Kokoro voices (27 MB)';       Fetch "$Kokoro/voices-v1.0.bin"  "$tts\voices-v1.0.bin" }
  Sub 'voice ok'
  Pop-Location

  # (the hands, i.e. the agent + bun, are NOT installed here: `hannah hands on` does it on demand)

  # -- 6. the overlay app (per-user, silent) -------------------------------------------
  Say 'overlay app'
  $rel = Invoke-RestMethod $Api -UseBasicParsing -ErrorAction Stop
  $asset = $rel.assets | Where-Object { $_.name -like '*-win-x64.exe' } | Select-Object -First 1
  if (-not $asset) { Die 'the latest release has no Windows build.' }
  # Where electron-builder's per-user NSIS puts it by default, and where it went if not there:
  # the Uninstall key it writes (InstallLocation) or any Hannah.exe under Programs\*.
  function Find-HannahExe {
    $default = Join-Path $env:LOCALAPPDATA 'Programs\Hannah\Hannah.exe'
    if (Test-Path $default) { return $default }
    foreach ($k in (Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue)) {
      $v = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
      if ($v.DisplayName -like 'Hannah*' -and $v.InstallLocation) { $c = Join-Path $v.InstallLocation 'Hannah.exe'; if (Test-Path $c) { return $c } }
    }
    $hit = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Filter 'Hannah.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $default
  }
  $appExe = Find-HannahExe
  $ver = ($asset.name -replace '^Hannah-([\d.]+)-.*$', '$1')
  $installed = if (Test-Path $appExe) { (Get-Item $appExe).VersionInfo.ProductVersion } else { '' }
  if ($installed -eq $ver) { Sub "Hannah.exe ok (already $ver)" }
  else {
    Fetch $asset.browser_download_url "$tmp\HannahSetup.exe"
    $sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if ($sums) {
      $want = ((Invoke-WebRequest $sums.browser_download_url -UseBasicParsing -ErrorAction Stop).Content -split "`n" | Where-Object { $_ -match [regex]::Escape($asset.name) + '$' } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
      $got = (Get-FileHash "$tmp\HannahSetup.exe" -Algorithm SHA256).Hash.ToLower()
      if ($want -and $got -ne $want.ToLower()) { Die "checksum mismatch for $($asset.name), nothing was installed" }
    } else { Warn 'no SHA256SUMS: the app was not verified' }
    # NSIS one-click, per-user (no UAC): lands in %LOCALAPPDATA%\Programs\Hannah. The download
    # carries the mark of the web; without Unblock-File SmartScreen can refuse a silent run.
    Unblock-File "$tmp\HannahSetup.exe" -ErrorAction SilentlyContinue
    $proc = Start-Process -Wait -PassThru -FilePath "$tmp\HannahSetup.exe" -ArgumentList '/S' -ErrorAction Stop
    Start-Sleep 2
    $appExe = Find-HannahExe
    if (-not (Test-Path $appExe)) {
      # not fatal: everything else is installed; keep the installer next to the code so it can be
      # run by hand (SmartScreen: More info -> Run anyway), and the launcher will say where it looks.
      Copy-Item "$tmp\HannahSetup.exe" (Join-Path $Root 'HannahSetup.exe') -Force
      Warn "the overlay did not install silently (installer exit code $($proc.ExitCode)). Run it yourself: $Root\HannahSetup.exe  (if SmartScreen shows up: More info -> Run anyway), then `hannah`."
    } else { Sub "Hannah $ver -> $appExe ok" }
  }

  # -- 7. the launcher -----------------------------------------------------------------
  Add-UserPath $Root
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

  Write-Host ''
  Write-Host "  Hannah is installed.   ($Root)" -ForegroundColor Green
  Write-Host ''
  Write-Host '  Open a NEW terminal (this one does not see the updated PATH) and run her:'
  Write-Host ''
  Write-Host '      hannah' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  Other commands:   hannah doctor   -   hannah stop   -   hannah hands on   -   hannah uninstall'
  Write-Host "  Install log: $script:LogF"
  Write-Host ''
  Write-Host '  Nothing else was installed: no Ollama, no language model, that is her first question.'
  Write-Host '  Voice and listening run on the CPU; the gestures on your NVIDIA card if there is one, else on the CPU'
  Write-Host '  (each sentence takes a bit longer to prepare, but she moves while she speaks).'
  Write-Host '  SmartScreen may show "Windows protected your PC" the first time: More info -> Run anyway.'
  Write-Host ''
  Write-Host "  Docs: $Docs"
  Write-Host ''
}

Install-Hannah
