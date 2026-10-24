param(
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Resolve-Path (Join-Path $ScriptDir "..")
$RepoRoot = Resolve-Path (Join-Path $AppDir "..")
. (Join-Path $ScriptDir "lib/backend_paths.ps1")
$ContractsScript = Resolve-BackendScriptPath -RepoRoot $RepoRoot -ScriptName "release_contracts.py"
$SigningScript = Join-Path $ScriptDir "sign_windows_release.ps1"
$WixSource = Join-Path $AppDir "packaging/windows/wix/DeployDash.wxs"
$BuildDir = Join-Path $AppDir "build/windows/x64/runner/Release"
$OutputDir = Join-Path $AppDir "build/windows/installer"
$InstallerPath = Join-Path $OutputDir "DeployDash.msi"
$DartDefinesFile = $env:DEPLOYDASH_DART_DEFINES_FILE
$BuildName = $env:DEPLOYDASH_BUILD_NAME
$BuildNumber = $env:DEPLOYDASH_BUILD_NUMBER
$PythonInterpreter = Resolve-UvPython313

if (-not $SkipBuild) {
  $flutterBuildArgs = @("build", "windows", "--release")
  $contractArgs = @(
    "flutter-build-args",
    "--app-dir", $AppDir
  )
  if (-not [string]::IsNullOrWhiteSpace($DartDefinesFile)) {
    $contractArgs += @("--dart-defines-file", $DartDefinesFile)
  }
  if (-not [string]::IsNullOrWhiteSpace($BuildName)) {
    $contractArgs += @("--build-name", $BuildName)
  }
  if (-not [string]::IsNullOrWhiteSpace($BuildNumber)) {
    $contractArgs += @("--build-number", $BuildNumber)
  }
  $resolvedBuildArgs = & $PythonInterpreter $ContractsScript @contractArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve Flutter build arguments."
  }
  if ($resolvedBuildArgs) {
    $flutterBuildArgs += $resolvedBuildArgs
  }
  $flutterBuildArgs += @(
    "--dart-define=DEPLOYDASH_DISTRIBUTION=msi",
    "--dart-define=DEPLOYDASH_RELEASE_CHANNEL=stable"
  )
  Push-Location $AppDir
  & flutter @flutterBuildArgs
  Pop-Location
}

foreach ($command in @("wix")) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $command"
  }
}

& $PythonInterpreter $ContractsScript validate-windows-release-bundle --build-dir $BuildDir
if ($LASTEXITCODE -ne 0) {
  throw "Windows release bundle validation failed."
}
& $PythonInterpreter $ContractsScript validate-windows-binary-hardening --build-dir $BuildDir
if ($LASTEXITCODE -ne 0) {
  throw "Windows binary hardening validation failed."
}
& $SigningScript -BuildDir $BuildDir

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

wix build `
  $WixSource `
  -define SourceDir=$BuildDir `
  -o $InstallerPath

if ($LASTEXITCODE -ne 0) {
  throw "WiX build failed with exit code $LASTEXITCODE"
}

& $PythonInterpreter $ContractsScript assert-artifact --path $InstallerPath --label MSI
if ($LASTEXITCODE -ne 0) {
  throw "MSI artifact validation failed."
}
& $SigningScript -BuildDir $BuildDir -ArtifactPath $InstallerPath

Write-Host "Built MSI at $InstallerPath"
