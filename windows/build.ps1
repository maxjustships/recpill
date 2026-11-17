# Build RecPill for Windows with the csc.exe that ships with Windows (.NET Framework 4.x). No SDK needed.
#   powershell -File windows\build.ps1            build dist\RecPill.exe (+ NAudio.dll, icons)
#   powershell -File windows\build.ps1 -Test      also compile and run the unit tests
#   powershell -File windows\build.ps1 -Zip       also write dist\RecPill-win-x64.zip (what the installer downloads)
param([switch]$Test, [switch]$Zip, [string]$Out = "$PSScriptRoot\dist")
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location $PSScriptRoot

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
New-Item -ItemType Directory -Force $Out, "$PSScriptRoot\build" | Out-Null

# NAudio 1.10.0 (MIT) from NuGet: lib\net35\NAudio.dll
$na = "$PSScriptRoot\build\NAudio.dll"
if (-not (Test-Path $na)) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $pkg = "$PSScriptRoot\build\naudio.nupkg"
  Invoke-WebRequest 'https://www.nuget.org/api/v2/package/NAudio/1.10.0' -OutFile $pkg -UseBasicParsing
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zipf = [IO.Compression.ZipFile]::OpenRead($pkg)
  try {
    $e = $zipf.Entries | Where-Object { $_.FullName -eq 'lib/net35/NAudio.dll' }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $na, $true)
  } finally { $zipf.Dispose() }
  Remove-Item $pkg
}

# System.Speech is only used by the developer "say" test command
$speech = (Get-ChildItem "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\System.Speech" -Recurse -Filter System.Speech.dll -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $speech) { $speech = (Get-ChildItem "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework" -Recurse -Filter System.Speech.dll -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
if (-not $speech) { throw 'System.Speech.dll not found' }

if ($Test) {
  & $csc /nologo /optimize+ /codepage:65001 /out:"$Out\tests.exe" Tests.cs Core.cs
  if ($LASTEXITCODE -ne 0) { throw 'test build failed' }
  & "$Out\tests.exe"
  if ($LASTEXITCODE -ne 0) { throw 'unit tests failed' }
}

$o = & $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /win32icon:rec.ico /r:"$na" /r:"$speech" /r:System.Drawing.dll /out:"$Out\RecPill.exe" RecPill.cs Core.cs 2>&1
if ($LASTEXITCODE -ne 0) { $o | Out-String | Write-Host; throw 'build failed' }
Copy-Item $na, 'rec.ico', 'rec.png', 'uninstall.ps1', '..\LICENSE' $Out -Force
Copy-Item '..\THIRD-PARTY.md' $Out -Force
Get-Item "$Out\RecPill.exe" | Select-Object Name, Length | Format-List | Out-String

if ($Zip) {
  $z = "$Out\RecPill-win-x64.zip"
  if (Test-Path $z) { Remove-Item $z }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $files = 'RecPill.exe', 'NAudio.dll', 'rec.ico', 'rec.png', 'uninstall.ps1', 'LICENSE', 'THIRD-PARTY.md'
  $arc = [IO.Compression.ZipFile]::Open($z, 'Create')
  try { foreach ($f in $files) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($arc, "$Out\$f", $f) } } finally { $arc.Dispose() }
  "$((Get-FileHash $z -Algorithm SHA256).Hash.ToLower())  RecPill-win-x64.zip" | Set-Content "$Out\SHA256SUMS" -Encoding ASCII
  "wrote $z"
}
