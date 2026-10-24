param([switch]$SkipClean)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$RepoRoot = (Resolve-Path (Join-Path $AppDir "..")).Path
. (Join-Path $ScriptDir "lib/backend_paths.ps1")
$ContractsScript = Resolve-BackendScriptPath -RepoRoot $RepoRoot -ScriptName "release_contracts.py"

function Require-Command {
  param([string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

foreach ($command in @("flutter", "uv")) {
  Require-Command -Name $command
}

Write-Host "Building Windows debug bundle with Drift native SQLite support"

if (-not $SkipClean) {
    Push-Location $AppDir
    try {
      & flutter clean
      if ($LASTEXITCODE -ne 0) {
        throw "flutter clean failed with exit code $LASTEXITCODE"
      }
    }
    finally {
      Pop-Location
    }
}

& flutter config --enable-windows-desktop
if ($LASTEXITCODE -ne 0) {
  throw "Unable to enable Windows desktop support in Flutter."
}

$dartDefinesFile = $env:DEPLOYDASH_DART_DEFINES_FILE
$buildName = $env:DEPLOYDASH_BUILD_NAME
$buildNumber = $env:DEPLOYDASH_BUILD_NUMBER
$pythonInterpreter = Resolve-UvPython313
$contractArgs = @("flutter-build-args", "--app-dir", $AppDir)
if (-not [string]::IsNullOrWhiteSpace($dartDefinesFile)) {
  $contractArgs += @("--dart-defines-file", $dartDefinesFile)
}
if (-not [string]::IsNullOrWhiteSpace($buildName)) {
  $contractArgs += @("--build-name", $buildName)
}
if (-not [string]::IsNullOrWhiteSpace($buildNumber)) {
  $contractArgs += @("--build-number", $buildNumber)
}

$resolvedBuildArgs = & $pythonInterpreter $ContractsScript @contractArgs
if ($LASTEXITCODE -ne 0) {
  throw "Failed to resolve Flutter build arguments."
}

$flutterBuildArgs = @("build", "windows", "--debug")
if ($resolvedBuildArgs) {
  $flutterBuildArgs += $resolvedBuildArgs
}

Push-Location $AppDir
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) {
      throw "flutter pub get failed with exit code $LASTEXITCODE"
    }

    & flutter @flutterBuildArgs
    if ($LASTEXITCODE -ne 0) {
      throw "Flutter Windows debug build failed with exit code $LASTEXITCODE"
    }
}
finally {
  Pop-Location
}

$buildDir = Join-Path $AppDir "build\windows\x64\runner\Debug"
& $pythonInterpreter $ContractsScript validate-windows-release-bundle --build-dir $buildDir
if ($LASTEXITCODE -ne 0) {
  throw "Windows debug bundle validation failed."
}

Write-Host "Built Windows debug app at $buildDir"
