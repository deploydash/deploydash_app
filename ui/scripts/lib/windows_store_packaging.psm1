$ErrorActionPreference = "Stop"

function Invoke-DeployDashNativeCommand {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Command,
    [Parameter(Mandatory = $true)][string]$Description,
    [switch]$RequireOutput
  )

  # Native stderr merged with 2>&1 is a terminating error under Stop, so a
  # chatty-but-successful tool (flutter's first-run "Building flutter
  # tool...") would kill the build before the exit code is even checked.
  # Scope Continue around the capture: the exit code below stays the only
  # failure signal, which is this wrapper's whole contract.
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $Command 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
  if ($exitCode -ne 0) {
    throw "$Description failed with exit code $exitCode. $($text.Trim())"
  }
  if ($RequireOutput -and [string]::IsNullOrWhiteSpace($text)) {
    throw "$Description returned no output."
  }
  return $text.Trim()
}

function Write-DeployDashStoreAsset {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height
  )

  Add-Type -AssemblyName System.Drawing
  $source = [System.Drawing.Image]::FromFile($SourcePath)
  $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.InterpolationMode = `
      [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scale = [Math]::Min($Width / $source.Width, $Height / $source.Height)
    $drawWidth = [int][Math]::Round($source.Width * $scale)
    $drawHeight = [int][Math]::Round($source.Height * $scale)
    $x = [int](($Width - $drawWidth) / 2)
    $y = [int](($Height - $drawHeight) / 2)
    $graphics.DrawImage($source, $x, $y, $drawWidth, $drawHeight)
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
    $source.Dispose()
  }
}

function Invoke-DeployDashWindowsStoreBuild {
  param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][ValidateSet("x64", "arm64")][string]$Arch,
    [switch]$SkipBuild,
    [switch]$SkipClean
  )

  $scriptDir = Join-Path $AppDir "scripts"
  . (Join-Path $scriptDir "lib/backend_paths.ps1")
  . (Join-Path $scriptDir "lib/windows_sdk.ps1")
  $contractsScript = Resolve-BackendScriptPath `
    -RepoRoot $RepoRoot `
    -ScriptName "release_contracts.py"
  $pythonInterpreter = Resolve-UvPython313
  $manifestTemplate = Join-Path `
    $AppDir `
    "packaging/windows/msix/Package.appxmanifest"
  $lastPublishedVersionFile = Join-Path `
    $AppDir `
    "packaging/windows/store-last-published-version.txt"
  $buildDir = Join-Path $AppDir "build/windows/$Arch/runner/Release"
  $packageRoot = Join-Path $AppDir "build/windows/msix-package"
  $assetsDir = Join-Path $packageRoot "Assets"
  $outputDir = Join-Path $AppDir "build/windows/installer"
  $iconSource = Join-Path $AppDir "assets/icons/app_icon.png"
  $buildName = $env:DEPLOYDASH_BUILD_NAME

  $versionArguments = @(
    "windows-store-package-version",
    "--app-dir", $AppDir
  )
  if (-not [string]::IsNullOrWhiteSpace($buildName)) {
    $versionArguments += @("--build-name", $buildName)
  }
  $packageVersion = Invoke-DeployDashNativeCommand `
    -Command { & $pythonInterpreter $contractsScript @versionArguments } `
    -Description "Windows Store package-version resolution" `
    -RequireOutput
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        validate-windows-store-version `
        --package-version $packageVersion `
        --last-published-version-file $lastPublishedVersionFile
    } `
    -Description "Windows Store published-version gate" | Out-Null
  $artifactNames = Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        windows-store-artifact-names `
        --package-version $packageVersion `
        --arch $Arch
    } `
    -Description "Windows Store artifact-name resolution" `
    -RequireOutput | ConvertFrom-Json
  $storeIdentity = Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        windows-store-identity `
        --arch $Arch
    } `
    -Description "Windows Store identity resolution" `
    -RequireOutput | ConvertFrom-Json
  $msixPath = Join-Path $outputDir $artifactNames.msix
  $appxSymPath = Join-Path $outputDir $artifactNames.appxsym
  $msixUploadPath = Join-Path $outputDir $artifactNames.msixupload
  $buildManifestPath = Join-Path $outputDir $artifactNames.build_manifest

  if (-not $SkipBuild) {
    Push-Location $AppDir
    try {
      if (-not $SkipClean) {
        Invoke-DeployDashNativeCommand `
          -Command { & flutter clean } `
          -Description "Flutter clean" | Out-Null
      }
      $flutterArguments = @("build", "windows", "--release")
      $contractArguments = @(
        "flutter-build-args",
        "--app-dir", $AppDir,
        "--default-to-pubspec"
      )
      if (-not [string]::IsNullOrWhiteSpace(
          $env:DEPLOYDASH_DART_DEFINES_FILE
      )) {
        $contractArguments += @(
          "--dart-defines-file",
          $env:DEPLOYDASH_DART_DEFINES_FILE
        )
      }
      if (-not [string]::IsNullOrWhiteSpace($buildName)) {
        $contractArguments += @("--build-name", $buildName)
      }
      if (-not [string]::IsNullOrWhiteSpace($env:DEPLOYDASH_BUILD_NUMBER)) {
        $contractArguments += @(
          "--build-number",
          $env:DEPLOYDASH_BUILD_NUMBER
        )
      }
      $resolvedArgumentsText = Invoke-DeployDashNativeCommand `
        -Command {
          & $pythonInterpreter $contractsScript @contractArguments
        } `
        -Description "Flutter build-argument resolution"
      $resolvedArguments = @(
        $resolvedArgumentsText -split [Environment]::NewLine |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
      $flutterArguments += $resolvedArguments
      $flutterArguments += @(
        "--dart-define=DEPLOYDASH_DISTRIBUTION=windows_store",
        "--dart-define=DEPLOYDASH_RELEASE_CHANNEL=stable",
        "--dart-define=DEPLOYDASH_WINDOWS_PACKAGE_FAMILY_NAME=TidyTechnology.DeployDash_rf5wcg4kb0x8a"
      )
      Invoke-DeployDashNativeCommand `
        -Command { & flutter @flutterArguments } `
        -Description "Flutter Windows release build" | Out-Null
    } finally {
      Pop-Location
    }
  }

  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        validate-windows-release-bundle `
        --build-dir $buildDir
    } `
    -Description "Windows release bundle validation" | Out-Null
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        validate-windows-binary-hardening `
        --build-dir $buildDir
    } `
    -Description "Windows binary hardening validation" | Out-Null

  Remove-Item -Recurse -Force $packageRoot -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  Copy-Item -Recurse -Force (Join-Path $buildDir "*") $packageRoot
  Get-ChildItem $packageRoot -File -Recurse -Include "*.pdb", "*.lib", "*.exp" |
    Remove-Item -Force

  Write-DeployDashStoreAsset `
    -SourcePath $iconSource `
    -OutputPath (Join-Path $assetsDir "StoreLogo.png") `
    -Width 50 `
    -Height 50
  Write-DeployDashStoreAsset `
    -SourcePath $iconSource `
    -OutputPath (Join-Path $assetsDir "Square44x44Logo.png") `
    -Width 44 `
    -Height 44
  Write-DeployDashStoreAsset `
    -SourcePath $iconSource `
    -OutputPath (Join-Path $assetsDir "Square150x150Logo.png") `
    -Width 150 `
    -Height 150
  Write-DeployDashStoreAsset `
    -SourcePath $iconSource `
    -OutputPath (Join-Path $assetsDir "Wide310x150Logo.png") `
    -Width 310 `
    -Height 150

  $renderedManifest = Join-Path $packageRoot "AppxManifest.xml"
  $manifest = (Get-Content $manifestTemplate -Raw).Replace(
    "__PACKAGE_VERSION__",
    $packageVersion
  ).Replace(
    "__ARCHITECTURE__",
    $Arch
  )
  Set-Content -Path $renderedManifest -Value $manifest -Encoding utf8
  $forbiddenArguments = @()
  if (-not [string]::IsNullOrWhiteSpace(
      $env:DEPLOYDASH_WINDOWS_FORBIDDEN_VALUES_FILE
  )) {
    $forbiddenArguments = @(
      "--forbidden-values-file",
      $env:DEPLOYDASH_WINDOWS_FORBIDDEN_VALUES_FILE
    )
  }
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        validate-windows-store-package-root `
        --package-root $packageRoot `
        --package-version $packageVersion `
        --arch $Arch `
        @forbiddenArguments
    } `
    -Description "Windows Store package-root validation" `
    -RequireOutput | Out-Null

  foreach ($path in @(
    $msixPath,
    $appxSymPath,
    $msixUploadPath,
    $buildManifestPath
  )) {
    Remove-Item $path -Force -ErrorAction SilentlyContinue
  }
  $makeAppx = Resolve-WindowsSdkTool -Name "makeappx.exe"
  Invoke-DeployDashNativeCommand `
    -Command { & $makeAppx pack /d $packageRoot /p $msixPath /o } `
    -Description "MakeAppx package creation" | Out-Null
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        validate-windows-store-msix `
        --msix $msixPath `
        --package-version $packageVersion `
        --arch $Arch `
        @forbiddenArguments
    } `
    -Description "Packed Windows Store MSIX validation" | Out-Null
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        create-windows-store-appxsym `
        --build-dir $buildDir `
        --output $appxSymPath
    } `
    -Description "Windows Store symbol archive creation" | Out-Null
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        create-windows-store-msixupload `
        --msix $msixPath `
        --appxsym $appxSymPath `
        --output $msixUploadPath
    } `
    -Description "Windows Store upload archive creation" | Out-Null
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        write-windows-store-build-manifest `
        --output $buildManifestPath `
        --package-version $packageVersion `
        --arch $Arch `
        --package-root $packageRoot `
        --msix $msixPath `
        --appxsym $appxSymPath `
        --msixupload $msixUploadPath
    } `
    -Description "Windows Store build-manifest generation" | Out-Null
  Invoke-DeployDashNativeCommand `
    -Command {
      & $pythonInterpreter `
        $contractsScript `
        validate-windows-store-build-manifest `
        --manifest $buildManifestPath `
        --arch $Arch `
        --package-root $packageRoot `
        --msix $msixPath `
        --appxsym $appxSymPath `
        --msixupload $msixUploadPath
    } `
    -Description "Windows Store build-manifest validation" | Out-Null

  return [pscustomobject]@{
    PackageName = $storeIdentity.package_name
    PackageVersion = $packageVersion
    ProductId = $storeIdentity.product_id
    MsixPath = $msixPath
    AppxSymPath = $appxSymPath
    MsixUploadPath = $msixUploadPath
    BuildManifestPath = $buildManifestPath
  }
}

Export-ModuleMember -Function @(
  "Invoke-DeployDashNativeCommand",
  "Write-DeployDashStoreAsset",
  "Invoke-DeployDashWindowsStoreBuild"
)
