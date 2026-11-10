<#
Builds the Windows release files into build\release-<version>\ :

  BizKhata-Setup-<version>.exe              installer (per user, no admin rights needed)
  BizKhata-<version>-windows-portable.zip   the same app in one BizKhata folder, for a USB stick

Usage, from any folder:

  powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1
  powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1 -Iscc "D:\Inno Setup 6\ISCC.exe"

Google sign-in is built in when google_oauth.json exists (see docs/google-setup.md).
-SkipBuild packages the current build\windows\x64\runner\Release folder without rebuilding.
#>
param(
  [string]$Iscc = $env:ISCC,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  $version = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
  if (-not $version) { throw 'No version found in pubspec.yaml' }
  Write-Host "BizKhata $version"

  if (-not $SkipBuild) {
    $buildArgs = @('build', 'windows', '--release')
    if (Test-Path google_oauth.json) {
      $buildArgs += '--dart-define-from-file=google_oauth.json'
    } else {
      Write-Warning 'google_oauth.json not found: this build hides Google sign-in.'
    }
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
  }

  # The exe needs everything else in this folder; refuse to package half a build.
  $bundle = (Resolve-Path 'build\windows\x64\runner\Release').Path.TrimEnd('\')
  foreach ($f in 'bizkhata.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat', 'data\flutter_assets') {
    if (-not (Test-Path (Join-Path $bundle $f))) { throw "$f is missing from $bundle" }
  }

  $out = Join-Path $root "build\release-$version"
  New-Item -ItemType Directory -Force $out | Out-Null

  # Installer
  if (-not $Iscc) {
    $found = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $Iscc = @(
      $(if ($found) { $found.Source }),
      "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
      "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
      "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  }
  if (-not $Iscc) { throw 'Inno Setup 6 (ISCC.exe) not found. Install it, or pass -Iscc <path to ISCC.exe>.' }
  & $Iscc /Qp "/DAppVersion=$version" installer\bizkhata.iss
  if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
  Copy-Item "build\installer\BizKhata-Setup-$version.exe" $out -Force

  # Portable zip. Everything sits inside one BizKhata folder, so opening the zip
  # shows a folder rather than a loose bizkhata.exe that's easy to copy out alone.
  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
  $zipPath = Join-Path $out "BizKhata-$version-windows-portable.zip"
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  $readme = [IO.File]::ReadAllText((Join-Path $root 'installer\portable-readme.txt'), [Text.Encoding]::UTF8)
  $readme = $readme.Replace('{version}', $version).Replace("`r`n", "`n").Replace("`n", "`r`n")
  $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
  try {
    Get-ChildItem $bundle -Recurse -File | ForEach-Object {
      $name = 'BizKhata/' + $_.FullName.Substring($bundle.Length + 1).Replace('\', '/')
      [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, $_.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
    }
    $writer = New-Object IO.StreamWriter(($zip.CreateEntry('BizKhata/README.txt')).Open(), (New-Object Text.UTF8Encoding($true)))
    try { $writer.Write($readme) } finally { $writer.Dispose() }
  } finally {
    $zip.Dispose()
  }

  Write-Host ''
  Write-Host "Release files in $out"
  Get-ChildItem $out | ForEach-Object { '  {0,-45} {1,6:N1} MB' -f $_.Name, ($_.Length / 1MB) }
} finally {
  Pop-Location
}
