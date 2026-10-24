param(
  [string]$BaseVersion = "1.0.0",
  [string]$CandidateVersion = "1.0.1",
  [ValidateSet("x64", "arm64")][string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
Import-Module `
  (Join-Path $ScriptDir "lib/windows_store_e2e.psm1") `
  -Force

$result = Invoke-DeployDashWindowsStoreE2EPairBuild `
  -AppDir $AppDir `
  -BaseVersion $BaseVersion `
  -CandidateVersion $CandidateVersion `
  -Arch $Arch

Write-Host "Built disposable Windows Store E2E pair:"
Write-Host "  $($result.BasePackage)"
Write-Host "  $($result.CandidatePackage)"
Write-Host "  $($result.Certificate)"
