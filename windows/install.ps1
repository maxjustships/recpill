# RecPill installer for Windows 10/11. No admin rights needed. ASCII only on purpose (works through `irm | iex`).
#   irm https://github.com/maxjustships/recpill/releases/latest/download/install.ps1 | iex
#
# Optional environment variables, set before running:
#   $env:RECPILL_OUTPUT  = 'D:\Calls'   where recordings go (default: %USERPROFILE%\Music\RecPill)
#   $env:RECPILL_DESKTOP = '1'          also put Start/Stop shortcuts on the Desktop
#   $env:RECPILL_VERSION = 'v0.1.0'     install a specific release (default: latest)
#   $env:RECPILL_LANG    = 'ru'         shortcut names language (default: your Windows UI language)
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $repo = 'maxjustships/recpill'
  $base = $env:RECPILL_BASE_URL
  if (-not $base) {
    $base = if ($env:RECPILL_VERSION) { "https://github.com/$repo/releases/download/$($env:RECPILL_VERSION)" } else { "https://github.com/$repo/releases/latest/download" }
  }
  $dir = Join-Path $env:LOCALAPPDATA 'RecPill'
  $exe = Join-Path $dir 'RecPill.exe'

  if (Get-Process RecPill -ErrorAction SilentlyContinue) {
    throw 'A recording is in progress. Stop it first, then run the installer again.'
  }

  # download + verify
  $tmp = Join-Path $env:TEMP ('recpill-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'RecPill-win-x64.zip'
    Write-Host 'Downloading RecPill...'
    Invoke-WebRequest "$base/RecPill-win-x64.zip" -OutFile $zip -UseBasicParsing
    $sums = (Invoke-WebRequest "$base/SHA256SUMS" -UseBasicParsing).Content
    if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
    $want = $null
    foreach ($line in ($sums -split "`n")) { if ($line -match '^([0-9a-fA-F]{64})\s+\*?RecPill-win-x64\.zip\s*$') { $want = $Matches[1].ToLower() } }
    if (-not $want) { throw 'SHA256SUMS has no entry for RecPill-win-x64.zip' }
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) { throw "Checksum mismatch: expected $want, got $got. Nothing was installed." }

    # unpack over the install dir (config.ini, logs and tmp\ are kept)
    New-Item -ItemType Directory -Force $dir, (Join-Path $dir 'tmp') | Out-Null
    $ex = Join-Path $tmp 'x'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $ex)
    Get-ChildItem $ex -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $dir $_.Name) -Force }
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

  # config.ini: created once, never overwritten; RECPILL_OUTPUT updates the output folder
  $cfg = Join-Path $dir 'config.ini'
  if (-not (Test-Path $cfg)) {
    $defOut = Join-Path ([Environment]::GetFolderPath('MyMusic')) 'RecPill'
    $txt = "# RecPill settings. Lines starting with # are comments.`r`n" +
           "# Where recordings are saved:`r`noutput_dir=$defOut`r`n" +
           "# Stop automatically after this many hours:`r`nmax_hours=4`r`n" +
           "# Message language: auto, en or ru`r`nlanguage=auto`r`n" +
           "# Set to off to disable the toast notifications:`r`nnotifications=on`r`n"
    [IO.File]::WriteAllText($cfg, $txt, (New-Object Text.UTF8Encoding($false)))
  }
  if ($env:RECPILL_OUTPUT) {
    $lines = Get-Content $cfg -Encoding UTF8 | ForEach-Object { if ($_ -match '^\s*output_dir\s*=') { "output_dir=$($env:RECPILL_OUTPUT)" } else { $_ } }
    [IO.File]::WriteAllText($cfg, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
  }

  # Start menu shortcuts (+ optional Desktop). Names follow the Windows UI language.
  $ru = ($env:RECPILL_LANG -eq 'ru') -or ((-not $env:RECPILL_LANG) -and ((Get-UICulture).TwoLetterISOLanguageName -eq 'ru'))
  if ($ru) {
    $n = @{
      start  = [regex]::Unescape('\u0421\u0442\u0430\u0440\u0442 \u0437\u0430\u043f\u0438\u0441\u0438')
      stop   = [regex]::Unescape('\u0421\u0442\u043e\u043f \u0437\u0430\u043f\u0438\u0441\u0438')
      toggle = [regex]::Unescape('\u0417\u0430\u043f\u0438\u0441\u044c \u0437\u0432\u043e\u043d\u043a\u0430')
    }
  } else {
    $n = @{ start = 'Start recording'; stop = 'Stop recording'; toggle = 'Toggle recording' }
  }
  $links = @(
    @{ name = $n.start;  arg = 'start';  icon = "$dir\rec.ico,0";                       desc = 'Start recording: microphone + computer sound'; desktop = $true },
    @{ name = $n.stop;   arg = 'stop';   icon = "$env:WINDIR\System32\shell32.dll,131"; desc = 'Stop recording and save the file';          desktop = $true },
    @{ name = $n.toggle; arg = 'toggle'; icon = "$dir\rec.ico,0";                       desc = 'Start or stop recording with one button';     desktop = $false }
  )
  $sh = New-Object -ComObject WScript.Shell
  # RECPILL_START_MENU only exists for tests / portable setups: put the shortcuts somewhere else
  $targets = @($(if ($env:RECPILL_START_MENU) { $env:RECPILL_START_MENU } else { [Environment]::GetFolderPath('Programs') }))
  New-Item -ItemType Directory -Force $targets[0] | Out-Null
  $desk = [Environment]::GetFolderPath('DesktopDirectory')
  foreach ($l in $links) {
    $places = @($targets[0])
    if ($env:RECPILL_DESKTOP -eq '1' -and $l.desktop) { $places += $desk }
    foreach ($p in $places) {
      $s = $sh.CreateShortcut((Join-Path $p ($l.name + '.lnk')))
      $s.TargetPath = $exe; $s.Arguments = $l.arg; $s.WorkingDirectory = $dir
      $s.IconLocation = $l.icon; $s.Description = $l.desc; $s.WindowStyle = 7
      $s.Save()
    }
  }

  $out = ((Get-Content $cfg -Encoding UTF8) | Where-Object { $_ -match '^\s*output_dir\s*=' } | Select-Object -First 1) -replace '^\s*output_dir\s*=\s*', ''
  Write-Host ''
  Write-Host "RecPill installed in $dir"
  Write-Host "Recordings go to:   $out   (change it in $cfg)"
  Write-Host "Start menu:         $($n.start) / $($n.stop) / $($n.toggle)"
  Write-Host 'Not signed: if SmartScreen warns on first start, choose More info > Run anyway.'
  Write-Host "Uninstall:          irm https://github.com/$repo/releases/latest/download/uninstall.ps1 | iex"
}
