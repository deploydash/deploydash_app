$ErrorActionPreference = "Stop"
$script:DeployDashE2ECertificateFriendlyName = `
  "Deploy Dash E2E package signing"

function Remove-DeployDashE2ESigningCertificates {
  param([Parameter(Mandatory = $true)][string]$Publisher)

  $certificates = @(Get-ChildItem "Cert:\CurrentUser\My" |
    Where-Object {
      $_.Subject -eq $Publisher -and
      $_.FriendlyName -in @(
        $script:DeployDashE2ECertificateFriendlyName,
        "MSIX Dev Certificate"
      )
    })
  foreach ($certificate in $certificates) {
    Remove-Item `
      -LiteralPath $certificate.PSPath `
      -Force `
      -ErrorAction SilentlyContinue
  }
}

function Get-DeployDashSdkToolVersion {
  param(
    [Parameter(Mandatory = $true)][string]$ToolPath
  )

  $item = Get-Item $ToolPath -ErrorAction SilentlyContinue
  if ($item -and $item.VersionInfo -and $item.VersionInfo.FileVersion) {
    return $item.VersionInfo.FileVersion
  }
  return "unknown"
}

function Invoke-DeployDashSignTool {
  param(
    [Parameter(Mandatory = $true)][string]$SignToolPath,
    [Parameter(Mandatory = $true)][string]$CertificateThumbprint,
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$Description,
    [string]$MakeAppxPath = ""
  )

  # Same stderr discipline as Invoke-DeployDashNativeCommand: signtool
  # progress on stderr must never read as failure while the exit code is 0.
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    # /v /debug stay on permanently: E2E signing failures arrive with
    # only this captured output, and the default one-line progress hides
    # the cause (seen live: bare "Done Adding Additional Store", exit 1).
    $output = @(& $SignToolPath sign /fd SHA256 /v /debug /sha1 `
      $CertificateThumbprint /s My $PackagePath 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  $output | ForEach-Object { Write-Host "$_" }
  if ($exitCode -ne 0) {
    $detail = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    # Self-diagnose the signing context: hosted E2E fails with an empty
    # cert enumeration while the identical flow signs in probes, so the
    # failure carries the store/identity view it died with.
    $storeCount = @(
      Get-ChildItem "Cert:\CurrentUser\My" -ErrorAction SilentlyContinue
    ).Count
    $whoami = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $pkgLeaf = Test-Path $PackagePath -PathType Leaf
    $pkgSize = -1
    $zipEntries = -1
    $contentTypes = "unknown"
    $sizeInfo = Get-Item $PackagePath -ErrorAction SilentlyContinue
    if ($sizeInfo) {
      $pkgSize = $sizeInfo.Length
    }
    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem `
        -ErrorAction SilentlyContinue
      $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
      try {
        $zipEntries = @($archive.Entries).Count
        $contentTypes = (@($archive.Entries |
          Where-Object { $_.FullName -eq "[Content_Types].xml" }).Count -gt 0)
      } finally {
        $archive.Dispose()
      }
    } catch {
      $zipEntries = -1
    }
    $signToolVersion = Get-DeployDashSdkToolVersion -ToolPath $SignToolPath
    $makeAppxVersion = "n/a"
    if ($MakeAppxPath) {
      $makeAppxVersion = Get-DeployDashSdkToolVersion -ToolPath $MakeAppxPath
    }
    $diag = "STORE-COUNT=$storeCount WHOAMI=$whoami " + `
      "APPDATA=$env:APPDATA PKG-LEAF=$pkgLeaf PKG-SIZE=$pkgSize " + `
      "ZIP-ENTRIES=$zipEntries CONTENT-TYPES=$contentTypes " + `
      "SIGNTOOL=$signToolVersion MAKEAPPX=$makeAppxVersion"
    throw "$Description failed with exit code $exitCode. $($detail.Trim()) [$diag]"
  }
}

function Invoke-DeployDashStoreBuildScript {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [switch]$SkipClean
  )

  & $ScriptPath -SkipClean:$SkipClean
  if ($LASTEXITCODE -ne 0) {
    throw "Windows Store E2E build failed with exit code $LASTEXITCODE."
  }
}

function New-DeployDashE2ESigningCertificate {
  param(
    [Parameter(Mandatory = $true)][string]$Publisher,
    [Parameter(Mandatory = $true)][string]$CertificatePath
  )

  $certificate = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Publisher `
    -FriendlyName $script:DeployDashE2ECertificateFriendlyName `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy NonExportable `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddDays(7) `
    -KeyUsage DigitalSignature `
    -TextExtension @(
      "2.5.29.19={text}CA=false",
      "2.5.29.37={text}1.3.6.1.5.5.7.3.3"
    )
  if (-not $certificate -or
      [string]::IsNullOrWhiteSpace($certificate.Thumbprint)) {
    throw "Could not create the disposable E2E signing certificate."
  }
  try {
    [byte[]]$publicCertificate = $certificate.RawData
    if ($publicCertificate.Length -eq 0) {
      throw "The generated certificate has no public data."
    }
    [IO.File]::WriteAllBytes(
      $CertificatePath,
      $publicCertificate
    )
  } catch {
    throw "Could not export the disposable E2E public certificate."
  }
  return [string]$certificate.Thumbprint
}

function Invoke-DeployDashSignedMsixValidation {
  param(
    [Parameter(Mandatory = $true)][string]$PythonInterpreter,
    [Parameter(Mandatory = $true)][string]$ContractsScript,
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$PackageVersion,
    [Parameter(Mandatory = $true)][ValidateSet("x64", "arm64")][string]$Arch
  )

  & $PythonInterpreter `
    $ContractsScript `
    validate-windows-store-msix `
    --msix $PackagePath `
    --package-version $PackageVersion `
    --arch $Arch `
    --allow-signed
  if ($LASTEXITCODE -ne 0) {
    throw "Signed Windows Store E2E package validation failed."
  }
}

function Find-DeployDashSuspiciousPayloadEntries {
  param(
    [Parameter(Mandatory = $true)][string]$PackagePath
  )

  # Read the zip central directory directly: duplicates, case
  # collisions, and symlink bits are invisible after extraction, and a
  # minimal MSIX signs fine on hosted runners while the real payload
  # dies 0x800700C1, so the culprit is an entry shape, not the host.
  # Empty files are NOT suspicious (py.typed, REQUESTED, and empty
  # __init__ markers are conventionally zero bytes).
  Add-Type -AssemblyName System.IO.Compression.FileSystem `
    -ErrorAction SilentlyContinue
  $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
  try {
    $names = @($archive.Entries | ForEach-Object { $_.FullName })
    $risks = @()
    $seenExact = @{}
    $seenFolded = @{}
    foreach ($name in $names) {
      if ($seenExact.ContainsKey($name)) {
        $risks += "DUPLICATE:$name"
      } else {
        $seenExact[$name] = $true
      }
      $folded = $name.ToLowerInvariant()
      if ($seenFolded.ContainsKey($folded)) {
        $risks += "CASECOLLISION:$name"
      } else {
        $seenFolded[$folded] = $true
      }
      if ($name.Length -gt 200) {
        $risks += "LONGPATH:$name"
      }
      if ($name -match '[\[\];,]' -and $name -cne "[Content_Types].xml") {
        $risks += "HOSTILECHARS:$name"
      }
      if ($name -match '[^\x00-\x7F]') {
        $risks += "NONASCII:$name"
      }
      if ($name -match '(^|[\\/])\.\.([\\/]|$)' -or
        $name -match '^[a-zA-Z]:' -or
        $name -match '^[\\/]') {
        $risks += "ESCAPE:$name"
      }
      $segments = $name -split '[\\/]'
      foreach ($segment in $segments) {
        if ($segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
          $risks += "DOSNAME:$name"
          break
        }
        if ($segment -match '(\.| )$') {
          $risks += "TRAILING:$name"
          break
        }
      }
    }
    foreach ($entry in $archive.Entries) {
      if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
        $risks += "SYMLINK:$($entry.FullName)"
      }
    }
    $ctEntry = $archive.GetEntry("[Content_Types].xml")
    if ($ctEntry) {
      $ctReader = New-Object IO.StreamReader($ctEntry.Open())
      try {
        $ctXml = $ctReader.ReadToEnd()
      } finally {
        $ctReader.Close()
      }
      $seenExt = @{}
      foreach ($m in [regex]::Matches(
        $ctXml, '<Default[^>]*?Extension\s*=\s*"([^"]+)"')) {
        $ext = $m.Groups[1].Value.ToLowerInvariant()
        if ($seenExt.ContainsKey($ext)) {
          $risks += "CONTENTTYPE-DUP-EXT:$ext"
        } else {
          $seenExt[$ext] = $true
        }
      }
      $seenPart = @{}
      foreach ($m in [regex]::Matches(
        $ctXml, '<Override[^>]*?PartName\s*=\s*"([^"]+)"')) {
        $part = $m.Groups[1].Value.ToLowerInvariant()
        if ($seenPart.ContainsKey($part)) {
          $risks += "CONTENTTYPE-DUP-PART:$part"
        } else {
          $seenPart[$part] = $true
        }
      }
    }
    return @($risks | Select-Object -Unique)
  } finally {
    $archive.Dispose()
  }
}

function Invoke-DeployDashE2EPackagePreSignValidation {
  param(
    [Parameter(Mandatory = $true)][string]$MakeAppxPath,
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$Description
  )

  $pkgInfo = Get-Item $PackagePath -ErrorAction SilentlyContinue
  if (-not $pkgInfo) {
    throw "$Description is missing before signing: $PackagePath."
  }
  $stream = [IO.File]::OpenRead($PackagePath)
  try {
    $header = New-Object byte[] 4
    [void]$stream.Read($header, 0, 4)
    $magic = ($header | ForEach-Object { $_.ToString("X2") }) -join ""
  } finally {
    $stream.Close()
  }
  if ($magic -ne "504B0304") {
    throw "$Description has a bad header before signing: " + `
      "magic=$magic length=$($pkgInfo.Length)."
  }
  $probeDir = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("e2e-presign-" + [guid]::NewGuid().ToString("N"))
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $MakeAppxPath unpack /p $PackagePath /d $probeDir /o 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
  try {
    if ($exitCode -ne 0) {
      throw "$Description failed makeappx unpack before signing " + `
        "(exit $exitCode): $($text.Trim())"
    }
    $suspicious = Find-DeployDashSuspiciousPayloadEntries -PackagePath $PackagePath
    if ($suspicious.Count -gt 0) {
      $preview = ($suspicious | Select-Object -First 20) -join '; '
      throw "$Description payload has suspicious entries " + `
        "(total $($suspicious.Count)): $preview"
    }
  } finally {
    Remove-Item -Recurse -Force $probeDir -ErrorAction SilentlyContinue
  }
}

function Invoke-DeployDashWindowsStoreE2EPairBuild {
  param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$BaseVersion,
    [Parameter(Mandatory = $true)][string]$CandidateVersion,
    [Parameter(Mandatory = $true)][ValidateSet("x64", "arm64")][string]$Arch
  )

  if ($BaseVersion -notmatch '^\d+\.\d+\.\d+$' -or
      $CandidateVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "E2E package versions must use X.Y.Z."
  }
  if ([version]$CandidateVersion -le [version]$BaseVersion) {
    throw "The E2E candidate version must be newer than the base version."
  }
  $scriptDir = Join-Path $AppDir "scripts"
  $repoRoot = (Resolve-Path (Join-Path $AppDir "..")).Path
  . (Join-Path $scriptDir "lib/backend_paths.ps1")
  . (Join-Path $scriptDir "lib/windows_sdk.ps1")
  $contractsScript = Resolve-BackendScriptPath `
    -RepoRoot $repoRoot `
    -ScriptName "release_contracts.py"
  $pythonInterpreter = Resolve-UvPython313
  $storeScript = Join-Path $scriptDir "build_windows_store.ps1"
  $installerDir = Join-Path $AppDir "build/windows/installer"
  $outputDir = Join-Path $AppDir "build/windows/e2e"
  $certificatePath = Join-Path $outputDir "DeployDash-E2E.cer"
  $legacyPrivateCertificatePath = Join-Path $outputDir "DeployDash-E2E.pfx"
  $publisher = "CN=4DF691A0-E545-4698-A115-C49614B329C6"
  $signToolPath = Resolve-WindowsSdkTool -Name "signtool.exe"
  $makeAppxPath = Resolve-WindowsSdkTool -Name "makeappx.exe"
  $certificateThumbprint = ""
  $previousName = $env:DEPLOYDASH_BUILD_NAME
  $previousNumber = $env:DEPLOYDASH_BUILD_NUMBER
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  Remove-DeployDashE2ESigningCertificates -Publisher $publisher
  Remove-Item `
    $legacyPrivateCertificatePath `
    -Force `
    -ErrorAction SilentlyContinue
  try {
    $index = 0
    foreach ($item in @(
      @{Label = "base"; Version = $BaseVersion},
      @{Label = "candidate"; Version = $CandidateVersion}
    )) {
      $index += 1
      $env:DEPLOYDASH_BUILD_NAME = $item.Version
      $env:DEPLOYDASH_BUILD_NUMBER = "$index"
      Invoke-DeployDashStoreBuildScript `
        -ScriptPath $storeScript `
        -SkipClean:($index -gt 1)
      if ($index -eq 1) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        $certificateThumbprint = New-DeployDashE2ESigningCertificate `
          -Publisher $publisher `
          -CertificatePath $certificatePath
        if ([string]::IsNullOrWhiteSpace($certificateThumbprint) -or
            -not (Test-Path $certificatePath -PathType Leaf)) {
          throw "Could not create the disposable E2E signing certificate."
        }
      }
      $packageVersion = "$($item.Version).0"
      $productionPackage = Join-Path `
        $installerDir `
        "DeployDash_${packageVersion}_${Arch}.msix"
      $e2ePackage = Join-Path $outputDir "DeployDash-$($item.Label).msix"
      Copy-Item $productionPackage $e2ePackage -Force
      Invoke-DeployDashE2EPackagePreSignValidation `
        -MakeAppxPath $makeAppxPath `
        -PackagePath $e2ePackage `
        -Description "Windows Store E2E $($item.Label) package"
      Invoke-DeployDashSignTool `
        -SignToolPath $signToolPath `
        -CertificateThumbprint $certificateThumbprint `
        -PackagePath $e2ePackage `
        -MakeAppxPath $makeAppxPath `
        -Description "Windows Store E2E $($item.Label) package signing"
      Invoke-DeployDashSignedMsixValidation `
        -PythonInterpreter $pythonInterpreter `
        -ContractsScript $contractsScript `
        -PackagePath $e2ePackage `
        -PackageVersion $packageVersion `
        -Arch $Arch
    }
  } finally {
    $env:DEPLOYDASH_BUILD_NAME = $previousName
    $env:DEPLOYDASH_BUILD_NUMBER = $previousNumber
    if (-not [string]::IsNullOrWhiteSpace($certificateThumbprint)) {
      Remove-Item `
        "Cert:\CurrentUser\My\$certificateThumbprint" `
        -Force `
        -ErrorAction SilentlyContinue
    }
    Remove-Item `
      $legacyPrivateCertificatePath `
      -Force `
      -ErrorAction SilentlyContinue
  }

  return [pscustomobject]@{
    BasePackage = Join-Path $outputDir "DeployDash-base.msix"
    CandidatePackage = Join-Path $outputDir "DeployDash-candidate.msix"
    Certificate = $certificatePath
  }
}

Export-ModuleMember -Function @(
  "Remove-DeployDashE2ESigningCertificates",
  "Invoke-DeployDashSignTool",
  "Invoke-DeployDashStoreBuildScript",
  "New-DeployDashE2ESigningCertificate",
  "Invoke-DeployDashSignedMsixValidation",
  "Find-DeployDashSuspiciousPayloadEntries",
  "Invoke-DeployDashE2EPackagePreSignValidation",
  "Invoke-DeployDashWindowsStoreE2EPairBuild"
)
