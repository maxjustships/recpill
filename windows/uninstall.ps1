# RecPill uninstaller for Windows. No admin needed. Your recordings are never touched.
#   irm https://github.com/maxjustships/recpill/releases/latest/download/uninstall.ps1 | iex
& {
  $ErrorActionPreference = 'Stop'
  $dir = Join-Path $env:LOCALAPPDATA 'RecPill'
  $menu = if ($env:RECPILL_START_MENU) { $env:RECPILL_START_MENU } else { [Environment]::GetFolderPath('Programs') }
  $exe = Join-Path $dir 'RecPill.exe'
  Set-Location $env:TEMP

  if (Get-Process RecPill -ErrorAction SilentlyContinue) {
    throw 'A recording is in progress. Stop it first (Stop recording shortcut), then run this again.'
  }

  # shortcuts that point at our exe (Start menu root and Desktop), whatever they are called
  $sh = New-Object -ComObject WScript.Shell
  $places = @(
    $menu,
    [Environment]::GetFolderPath('DesktopDirectory')
  )
  foreach ($p in $places) {
    if (-not (Test-Path $p)) { continue }
    foreach ($l in Get-ChildItem $p -Filter *.lnk -ErrorAction SilentlyContinue) {
      try { if ($sh.CreateShortcut($l.FullName).TargetPath -eq $exe) { Remove-Item $l.FullName -Force; "removed shortcut $($l.Name)" } } catch { }
    }
  }
  # old Start menu folder from earlier layouts, if it is ours
  $old = Join-Path $menu 'RecPill'
  if (Test-Path $old) { Remove-Item $old -Recurse -Force }

  Remove-Item 'HKCU:\Software\Classes\AppUserModelId\RecPill.Recorder' -Recurse -Force -ErrorAction SilentlyContinue

  if (Test-Path $dir) {
    $left = @(Get-ChildItem (Join-Path $dir 'tmp') -Filter *.pcm -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
      "NOTE: $($left.Count) unsaved raw recording(s) are kept in $dir\tmp (open RecPill once to recover them, or delete the folder)."
      Get-ChildItem $dir -Exclude tmp | Remove-Item -Recurse -Force
    } else {
      Remove-Item $dir -Recurse -Force
    }
    "removed $dir"
  }
  'RecPill is uninstalled. Your recordings were not touched.'
}
