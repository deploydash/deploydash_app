param(
  [switch]$SkipBuild,
  [switch]$SkipClean,
  [ValidateSet("x64", "arm64")][string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$RepoRoot = (Resolve-Path (Join-Path $AppDir "..")).Path
Import-Module `
  (Join-Path $ScriptDir "lib/windows_store_packaging.psm1") `
  -Force

$result = Invoke-DeployDashWindowsStoreBuild `
  -AppDir $AppDir `
  -RepoRoot $RepoRoot `
  -Arch $Arch `
  -SkipBuild:$SkipBuild `
  -SkipClean:$SkipClean

Write-Host "Built Microsoft Store submission for $($result.PackageName)."
Write-Host "  Version: $($result.PackageVersion)"
Write-Host "  Product ID: $($result.ProductId)"
Write-Host "  MSIX: $($result.MsixPath)"
Write-Host "  Symbols: $($result.AppxSymPath)"
Write-Host "  Upload: $($result.MsixUploadPath)"
Write-Host "  Manifest: $($result.BuildManifestPath)"
