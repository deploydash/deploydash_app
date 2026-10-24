param(
  [Parameter(Mandatory = $true)]
  [string]$BuildDir,
  [string]$ArtifactPath = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Resolve-Path (Join-Path $ScriptDir "..")
$RepoRoot = Resolve-Path (Join-Path $AppDir "..")
. (Join-Path $ScriptDir "lib/backend_paths.ps1")
. (Join-Path $ScriptDir "lib/windows_sdk.ps1")
$ContractsScript = Resolve-BackendScriptPath -RepoRoot $RepoRoot -ScriptName "release_contracts.py"
$PythonInterpreter = Resolve-UvPython313
$Thumbprint = ([string]$env:DEPLOYDASH_WINDOWS_SIGN_CERT_SHA1).Replace(" ", "")
$SigningRequired = $env:DEPLOYDASH_WINDOWS_SIGNING_REQUIRED -eq "1"
$TimestampUrl = $env:DEPLOYDASH_WINDOWS_SIGN_TIMESTAMP_URL

if ([string]::IsNullOrWhiteSpace($TimestampUrl)) {
  $TimestampUrl = "http://timestamp.digicert.com"
}

if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
  if ($SigningRequired) {
    throw "Windows signing is required, but DEPLOYDASH_WINDOWS_SIGN_CERT_SHA1 is not set."
  }
  Write-Warning "Windows signing certificate is not configured; artifacts remain unsigned."
  return
}

$SignToolPath = Resolve-WindowsSdkTool -Name "signtool.exe"

$SigningPaths = @()
if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
  $SigningPaths = & $PythonInterpreter $ContractsScript windows-signing-paths --build-dir $BuildDir
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve the Windows signing contract."
  }
} else {
  $SigningPaths = @($ArtifactPath)
}

foreach ($Path in $SigningPaths) {
  if (-not (Test-Path $Path -PathType Leaf)) {
    throw "Required Windows signing target is missing: $Path"
  }
  $Arguments = @(
    "sign",
    "/sha1", $Thumbprint,
    "/fd", "SHA256",
    "/tr", $TimestampUrl,
    "/td", "SHA256",
    $Path
  )
  if ($env:DEPLOYDASH_WINDOWS_SIGN_CERT_STORE -eq "machine") {
    $Arguments = @("sign", "/sm") + $Arguments[1..($Arguments.Length - 1)]
  }
  & $SignToolPath @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Authenticode signing failed for: $Path"
  }
  & $SignToolPath verify /pa /all $Path | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Authenticode verification failed for: $Path"
  }
}
