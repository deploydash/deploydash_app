$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
$script:PackagingModule = Join-Path `
  $script:RepoRoot `
  "ui/scripts/lib/windows_store_packaging.psm1"
$script:E2EModule = Join-Path `
  $script:RepoRoot `
  "ui/scripts/lib/windows_store_e2e.psm1"
Import-Module $script:PackagingModule -Force
Import-Module $script:E2EModule -Force

BeforeAll {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
  Import-Module `
    (Join-Path $repoRoot "ui/scripts/lib/windows_store_packaging.psm1") `
    -Force
  Import-Module `
    (Join-Path $repoRoot "ui/scripts/lib/windows_store_e2e.psm1") `
    -Force
}

Describe "Windows Store packaging module" {
  InModuleScope windows_store_packaging {
    It "runs checked commands and enforces exit and output contracts" {
      $global:LASTEXITCODE = 0
      Invoke-DeployDashNativeCommand `
        -Command { Write-Output "value" } `
        -Description "success" `
        -RequireOutput | Should -Be "value"
      { Invoke-DeployDashNativeCommand `
          -Command { } `
          -Description "empty" `
          -RequireOutput } | Should -Throw "*returned no output*"
      $global:LASTEXITCODE = 1
      { Invoke-DeployDashNativeCommand `
          -Command { Write-Output "failure" } `
          -Description "failure" } | Should -Throw "*exit code 1*"
      $global:LASTEXITCODE = 0
    }

    It "treats native stderr as output, not failure, when the exit code is zero" {
      Invoke-DeployDashNativeCommand `
        -Command { & cmd.exe /c "echo simulated first-run noise 1>&2" } `
        -Description "stderr-noise" | Should -Be "simulated first-run noise"
      $global:LASTEXITCODE = 0
    }

    It "writes an exact PNG asset" {
      $source = Join-Path $TestDrive "source.png"
      $output = Join-Path $TestDrive "output.png"
      Add-Type -AssemblyName System.Drawing
      $bitmap = New-Object System.Drawing.Bitmap(8, 8)
      try {
        $bitmap.Save($source, [System.Drawing.Imaging.ImageFormat]::Png)
      } finally {
        $bitmap.Dispose()
      }
      Write-DeployDashStoreAsset `
        -SourcePath $source `
        -OutputPath $output `
        -Width 20 `
        -Height 30
      $image = [System.Drawing.Image]::FromFile($output)
      try {
        $image.Width | Should -Be 20
        $image.Height | Should -Be 30
      } finally {
        $image.Dispose()
      }
    }

    It "orchestrates every production build and validation stage" {
      $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
      $appDir = Join-Path $repoRoot "ui"
      . (Join-Path $appDir "scripts/lib/backend_paths.ps1")
      . (Join-Path $appDir "scripts/lib/windows_sdk.ps1")
      function Invoke-FakePython {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
      }
      function Invoke-FakeNative {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
      }
      function flutter {
        param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
        $script:flutterArguments = @($Arguments)
      }
      Mock Resolve-BackendScriptPath { "contracts.py" }
      Mock Resolve-UvPython313 { "Invoke-FakePython" }
      Mock Resolve-WindowsSdkTool { "Invoke-FakeNative" }
      Mock Push-Location {}
      Mock Pop-Location {}
      Mock Remove-Item {}
      Mock New-Item { [pscustomobject]@{} }
      Mock Copy-Item {}
      Mock Get-ChildItem { @() }
      Mock Get-Content { "manifest __PACKAGE_VERSION__" }
      Mock Set-Content {}
      Mock Write-DeployDashStoreAsset {}
      Mock Invoke-DeployDashNativeCommand {
        & $Command | Out-Null
        switch -Regex ($Description) {
          "package-version" { return "1.2.3.0" }
          "artifact-name" {
            return '{"msix":"DeployDash_1.2.3.0_x64.msix",' +
              '"appxsym":"DeployDash_1.2.3.0_x64.appxsym",' +
              '"msixupload":"DeployDash_1.2.3.0_x64.msixupload",' +
              '"build_manifest":"DeployDash_1.2.3.0_x64.build-manifest.json"}'
          }
          "identity" {
            return '{"package_name":"TidyTechnology.DeployDash",' +
              '"product_id":"9P1GK6Z58B9T"}'
          }
          "build-argument" { return "--build-name=1.2.3" }
          "package-root" { return '{"sha256":"digest"}' }
          default { return "" }
        }
      }
      $env:DEPLOYDASH_BUILD_NAME = "1.2.3"
      $env:DEPLOYDASH_BUILD_NUMBER = "7"
      $env:DEPLOYDASH_DART_DEFINES_FILE = "defines.json"
      $env:DEPLOYDASH_WINDOWS_FORBIDDEN_VALUES_FILE = "forbidden.txt"
      try {
        $result = Invoke-DeployDashWindowsStoreBuild `
          -AppDir $appDir `
          -RepoRoot $repoRoot `
          -Arch "x64"
      } finally {
        Remove-Item Env:DEPLOYDASH_BUILD_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:DEPLOYDASH_BUILD_NUMBER -ErrorAction SilentlyContinue
        Remove-Item Env:DEPLOYDASH_DART_DEFINES_FILE -ErrorAction SilentlyContinue
        Remove-Item `
          Env:DEPLOYDASH_WINDOWS_FORBIDDEN_VALUES_FILE `
          -ErrorAction SilentlyContinue
      }
      $result.PackageVersion | Should -Be "1.2.3.0"
      $result.MsixUploadPath | Should -Match "1.2.3.0_x64.msixupload"
      $script:flutterArguments | Should -Contain `
        "--dart-define=DEPLOYDASH_WINDOWS_PACKAGE_FAMILY_NAME=TidyTechnology.DeployDash_rf5wcg4kb0x8a"
      Assert-MockCalled Invoke-DeployDashNativeCommand -Times 13
      Assert-MockCalled Write-DeployDashStoreAsset -Times 4
    }
  }
}

Describe "Windows Store disposable E2E package module" {
  InModuleScope windows_store_e2e {
    It "removes only Deploy Dash disposable signing certificates" {
      Mock Get-ChildItem {
        @(
          [pscustomobject]@{
            Subject = "CN=publisher"
            FriendlyName = "Deploy Dash E2E package signing"
            PSPath = "Cert:\CurrentUser\My\new"
          },
          [pscustomobject]@{
            Subject = "CN=publisher"
            FriendlyName = "MSIX Dev Certificate"
            PSPath = "Cert:\CurrentUser\My\legacy"
          },
          [pscustomobject]@{
            Subject = "CN=publisher"
            FriendlyName = "Production certificate"
            PSPath = "Cert:\CurrentUser\My\production"
          },
          [pscustomobject]@{
            Subject = "CN=other"
            FriendlyName = "Deploy Dash E2E package signing"
            PSPath = "Cert:\CurrentUser\My\other"
          }
        )
      }
      Mock Remove-Item {}
      Remove-DeployDashE2ESigningCertificates -Publisher "CN=publisher"
      Assert-MockCalled Remove-Item -Times 2
    }

    It "runs signtool by thumbprint and reports native failures" {
      function Invoke-FakeSignTool {
        $script:signToolArgs = @($args)
        $global:LASTEXITCODE = $script:signToolExitCode
        if ($global:LASTEXITCODE -eq 0) { "ok" } else { "bad" }
      }
      $script:signToolExitCode = 0
      { Invoke-DeployDashSignTool `
          -SignToolPath "Invoke-FakeSignTool" `
          -CertificateThumbprint "ABC123" `
          -PackagePath "package.msix" `
          -Description "signtool" } | Should -Not -Throw
      $script:signToolArgs | Should -Contain "/v"
      $script:signToolArgs | Should -Contain "/debug"
      $script:signToolExitCode = 5
      { Invoke-DeployDashSignTool `
          -SignToolPath "Invoke-FakeSignTool" `
          -CertificateThumbprint "ABC123" `
          -PackagePath "package.msix" `
          -Description "signtool" } | Should -Throw "*exit code 5*bad*STORE-COUNT=*"
      $global:LASTEXITCODE = 0
    }

    It "reports tool versions and package forensics in signing failures" {
      $fakeTool = Join-Path $TestDrive "forensic-signtool.cmd"
      "@echo off", "echo boom 1>&2", "exit /b 1" |
        Set-Content -Path $fakeTool -Encoding ascii
      $fakeMakeAppx = Join-Path $TestDrive "forensic-makeappx.cmd"
      "@echo off", "exit /b 0" | Set-Content -Path $fakeMakeAppx -Encoding ascii
      $zipPath = Join-Path $TestDrive "forensic.msix"
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $archive = [IO.Compression.ZipFile]::Open(
        $zipPath, [IO.Compression.ZipArchiveMode]::Create)
      try {
        foreach ($entryName in @("[Content_Types].xml", "AppxManifest.xml")) {
          $writer = New-Object IO.StreamWriter(
            $archive.CreateEntry($entryName).Open())
          try {
            $writer.Write("x")
          } finally {
            $writer.Close()
          }
        }
      } finally {
        $archive.Dispose()
      }
      Mock Get-Item {
        [pscustomobject]@{
          Length      = 1234
          VersionInfo = [pscustomobject]@{ FileVersion = "9.9.9.9" }
        }
      }
      { Invoke-DeployDashSignTool `
          -SignToolPath $fakeTool `
          -CertificateThumbprint "ABC123" `
          -PackagePath $zipPath `
          -MakeAppxPath $fakeMakeAppx `
          -Description "signtool" } | Should -Throw `
        "*PKG-SIZE=1234*ZIP-ENTRIES=2*CONTENT-TYPES=True*SIGNTOOL=9.9.9.9*MAKEAPPX=9.9.9.9*"
      $global:LASTEXITCODE = 0
    }

    It "ignores signtool stderr when signing succeeds" {
      $fakeTool = Join-Path $TestDrive "fake-signtool.cmd"
      "@echo off", "echo simulated signtool noise 1>&2", "exit /b 0" |
        Set-Content -Path $fakeTool -Encoding ascii
      { Invoke-DeployDashSignTool `
          -SignToolPath $fakeTool `
          -CertificateThumbprint "ABC123" `
          -PackagePath "package.msix" `
          -Description "signtool" } | Should -Not -Throw
      $global:LASTEXITCODE = 0
    }

    It "rejects E2E packages that are missing or malformed before signing" {
      $fakeMakeAppx = Join-Path $TestDrive "fake-makeappx.cmd"
      "@echo off", "exit /b 0" | Set-Content -Path $fakeMakeAppx -Encoding ascii
      { Invoke-DeployDashE2EPackagePreSignValidation `
          -MakeAppxPath $fakeMakeAppx `
          -PackagePath (Join-Path $TestDrive "missing.msix") `
          -Description "test package" } | Should -Throw "*missing before signing*"
      $badPkg = Join-Path $TestDrive "bad.msix"
      [IO.File]::WriteAllBytes($badPkg, [byte[]](0x4D, 0x5A, 0x90, 0x00))
      { Invoke-DeployDashE2EPackagePreSignValidation `
          -MakeAppxPath $fakeMakeAppx -PackagePath $badPkg `
          -Description "test package" } | Should -Throw "*bad header*magic=4D5A9000*"
      $global:LASTEXITCODE = 0
    }

    It "rejects E2E packages that makeappx cannot unpack" {
      $failMakeAppx = Join-Path $TestDrive "fail-makeappx.cmd"
      "@echo off", "echo unpack exploded 1>&2", "exit /b 1" |
        Set-Content -Path $failMakeAppx -Encoding ascii
      $goodPkg = Join-Path $TestDrive "good.msix"
      [IO.File]::WriteAllBytes($goodPkg, [byte[]](0x50, 0x4B, 0x03, 0x04))
      { Invoke-DeployDashE2EPackagePreSignValidation `
          -MakeAppxPath $failMakeAppx -PackagePath $goodPkg `
          -Description "test package" } | Should -Throw "*failed makeappx unpack*unpack exploded*"
      $global:LASTEXITCODE = 0
    }

    It "passes clean E2E packages and flags suspicious payload entries" {
      $fakeMakeAppx = Join-Path $TestDrive "fake-makeappx-clean.cmd"
      "@echo off", "exit /b 0" | Set-Content -Path $fakeMakeAppx -Encoding ascii
      $goodPkg = Join-Path $TestDrive "clean.msix"
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $cleanArchive = [IO.Compression.ZipFile]::Open(
        $goodPkg, [IO.Compression.ZipArchiveMode]::Create)
      try {
        foreach ($entryName in @("AppxManifest.xml", "Assets/logo.png")) {
          $writer = New-Object IO.StreamWriter(
            $cleanArchive.CreateEntry($entryName).Open())
          try {
            $writer.Write("x")
          } finally {
            $writer.Close()
          }
        }
        $ctWriter = New-Object IO.StreamWriter(
          $cleanArchive.CreateEntry("[Content_Types].xml").Open())
        try {
          $ctWriter.Write('<Types><Default Extension="xml" ContentType="a"/>' +
            '<Default Extension="png" ContentType="b"/></Types>')
        } finally {
          $ctWriter.Close()
        }
      } finally {
        $cleanArchive.Dispose()
      }
      { Invoke-DeployDashE2EPackagePreSignValidation `
          -MakeAppxPath $fakeMakeAppx -PackagePath $goodPkg `
          -Description "test package" } | Should -Not -Throw
      Mock Find-DeployDashSuspiciousPayloadEntries { @("HOSTILECHARS:payload/evil[x].dll") }
      { Invoke-DeployDashE2EPackagePreSignValidation `
          -MakeAppxPath $fakeMakeAppx -PackagePath $goodPkg `
          -Description "test package" } | Should -Throw "*suspicious entries*evil*"
      $global:LASTEXITCODE = 0
    }

    It "flags zip entries that break AppX signing" {
      $riskyPkg = Join-Path $TestDrive "risky.msix"
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $longName = "a" * 201
      $nonAsciiName = "caf$([char]0xE9).txt"
      $archive = [IO.Compression.ZipFile]::Open(
        $riskyPkg, [IO.Compression.ZipArchiveMode]::Create)
      try {
        foreach ($entryName in @(
          "clean.dll",
          "dup.txt",
          "dup.txt",
          "Case.txt",
          "case.txt",
          $longName,
          "evil[x].txt",
          $nonAsciiName,
          "../escape.txt",
          "sub/NUL.txt",
          "weird./f.txt"
        )) {
          $writer = New-Object IO.StreamWriter(
            $archive.CreateEntry($entryName).Open())
          try {
            $writer.Write("x")
          } finally {
            $writer.Close()
          }
        }
        $link = $archive.CreateEntry("link.txt")
        # 0xA000 file-type bits shifted into ExternalAttributes (wraps to
        # a negative int; the arithmetic right shift recovers 0xA000).
        $link.ExternalAttributes = (0xA000 -shl 16)
        $ctWriter = New-Object IO.StreamWriter(
          $archive.CreateEntry("[Content_Types].xml").Open())
        try {
          $ctWriter.Write('<Types><Default Extension="dll" ContentType="a"/>' +
            '<Default Extension="DLL" ContentType="b"/>' +
            '<Override PartName="/AppxManifest.xml" ContentType="c"/>' +
            '<Override PartName="/AppxManifest.xml" ContentType="c"/></Types>')
        } finally {
          $ctWriter.Close()
        }
      } finally {
        $archive.Dispose()
      }
      $found = Find-DeployDashSuspiciousPayloadEntries -PackagePath $riskyPkg
      $found | Should -Contain "DUPLICATE:dup.txt"
      $found | Should -Contain "CASECOLLISION:case.txt"
      $found | Should -Contain ("LONGPATH:" + $longName)
      $found | Should -Contain "HOSTILECHARS:evil[x].txt"
      $found | Should -Contain ("NONASCII:" + $nonAsciiName)
      $found | Should -Contain "ESCAPE:../escape.txt"
      $found | Should -Contain "DOSNAME:sub/NUL.txt"
      $found | Should -Contain "TRAILING:weird./f.txt"
      $found | Should -Contain "SYMLINK:link.txt"
      $found | Should -Contain "CONTENTTYPE-DUP-EXT:dll"
      $found | Should -Contain "CONTENTTYPE-DUP-PART:/appxmanifest.xml"
      $found | Where-Object { $_ -like "*clean.dll*" } | Should -BeNullOrEmpty
      $found | Where-Object { $_ -like "HOSTILECHARS:*Content_Types*" } |
        Should -BeNullOrEmpty
    }

    It "rejects invalid E2E package versions" {
      { Invoke-DeployDashWindowsStoreE2EPairBuild `
          -AppDir $TestDrive `
          -BaseVersion "1.0" `
          -CandidateVersion "1.0.1" `
          -Arch "x64" } | Should -Throw "*X.Y.Z*"
      { Invoke-DeployDashWindowsStoreE2EPairBuild `
          -AppDir $TestDrive `
          -BaseVersion "1.0.1" `
          -CandidateVersion "1.0.0" `
          -Arch "x64" } | Should -Throw "*newer*"
      { Invoke-DeployDashWindowsStoreE2EPairBuild `
          -AppDir $TestDrive `
          -BaseVersion "1.0.0" `
          -CandidateVersion "1.0.1" `
          -Arch "riscv" } | Should -Throw
    }

    It "runs build and signed-package validation command boundaries" {
      $recorded = Join-Path $TestDrive "validation-args.txt"
      $success = Join-Path $TestDrive "success.ps1"
      Set-Content $success (
        'param([Parameter(ValueFromRemainingArguments=$true)]$Rest); ' +
        '$Rest -join " " | Out-File -FilePath "__RECORDED__" -Encoding utf8; ' +
        '$global:LASTEXITCODE=0'
      ).Replace("__RECORDED__", $recorded)
      Invoke-DeployDashStoreBuildScript -ScriptPath $success
      Invoke-DeployDashSignedMsixValidation `
        -PythonInterpreter $success `
        -ContractsScript "contracts.py" `
        -PackagePath "package.msix" `
        -PackageVersion "1.0.0.0" `
        -Arch "x64"
      $forwarded = Get-Content $recorded -Raw
      $forwarded | Should -Match "--msix package.msix"
      $forwarded | Should -Match "--package-version 1.0.0.0"
      $forwarded | Should -Match "--arch x64"
      $forwarded | Should -Match "--allow-signed"
      $failure = Join-Path $TestDrive "failure.ps1"
      Set-Content $failure `
        'param([Parameter(ValueFromRemainingArguments=$true)]$Rest); $global:LASTEXITCODE=3'
      { Invoke-DeployDashStoreBuildScript -ScriptPath $failure } |
        Should -Throw "*exit code 3*"
      { Invoke-DeployDashSignedMsixValidation `
          -PythonInterpreter $failure `
          -ContractsScript "contracts.py" `
          -PackagePath "package.msix" `
          -PackageVersion "1.0.0.0" `
          -Arch "x64" } | Should -Throw "*validation failed*"
      $global:LASTEXITCODE = 0
    }

    It "creates a non-exportable short-lived code-signing certificate" {
      $path = Join-Path $TestDrive "public.cer"
      Mock New-SelfSignedCertificate {
        $script:keyExportPolicy = [string]$KeyExportPolicy
        $script:certificateStoreLocation = [string]$CertStoreLocation
        $script:certificateFriendlyName = [string]$FriendlyName
        [pscustomobject]@{
          Thumbprint = "ABC123"
          RawData = [byte[]](1, 2, 3)
        }
      }
      New-DeployDashE2ESigningCertificate `
        -Publisher "CN=publisher" `
        -CertificatePath $path | Should -Be "ABC123"
      Test-Path $path | Should -BeTrue
      $script:keyExportPolicy | Should -Be "NonExportable"
      $script:certificateStoreLocation | Should -Be "Cert:\CurrentUser\My"
      $script:certificateFriendlyName | Should -Be `
        "Deploy Dash E2E package signing"
      Assert-MockCalled New-SelfSignedCertificate -Times 1
    }

    It "rejects failed certificate creation and public export" {
      $path = Join-Path $TestDrive "missing.cer"
      Mock New-SelfSignedCertificate { $null }
      { New-DeployDashE2ESigningCertificate `
          -Publisher "CN=publisher" `
          -CertificatePath $path } | Should -Throw "*Could not create*"
      Mock New-SelfSignedCertificate {
        [pscustomobject]@{Thumbprint = ""}
      }
      { New-DeployDashE2ESigningCertificate `
          -Publisher "CN=publisher" `
          -CertificatePath $path } | Should -Throw "*Could not create*"
      Mock New-SelfSignedCertificate {
        [pscustomobject]@{Thumbprint = "ABC123"; RawData = $null}
      }
      { New-DeployDashE2ESigningCertificate `
          -Publisher "CN=publisher" `
          -CertificatePath $path } | Should -Throw "*Could not export*"
    }

    It "builds, signs, validates, and deletes one-use private material" {
      $appDir = Join-Path $TestDrive "app"
      $scripts = Join-Path $appDir "scripts"
      $lib = Join-Path $scripts "lib"
      $installer = Join-Path $appDir "build/windows/installer"
      New-Item -ItemType Directory -Force -Path $lib, $installer | Out-Null
      Set-Content `
        (Join-Path $lib "backend_paths.ps1") `
        @'
function Resolve-BackendScriptPath { return "contracts.py" }
function Resolve-UvPython313 { return "python.exe" }
'@
      Set-Content `
        (Join-Path $lib "windows_sdk.ps1") `
        'function Resolve-WindowsSdkTool { return "signtool.exe" }'
      Set-Content (Join-Path $scripts "build_windows_store.ps1") "fixture"
      foreach ($version in @("1.0.0.0", "1.0.1.0")) {
        Set-Content `
          (Join-Path $installer "DeployDash_${version}_x64.msix") `
          $version
      }
      $legacyPfx = Join-Path `
        $appDir `
        "build/windows/e2e/DeployDash-E2E.pfx"
      New-Item -ItemType Directory -Force (Split-Path $legacyPfx) | Out-Null
      Set-Content $legacyPfx "legacy-private-material"
      $script:e2eOutputDir = Split-Path $legacyPfx
      $script:storeBuildCalls = 0
      Mock Invoke-DeployDashStoreBuildScript {
        $script:storeBuildCalls += 1
        if ($script:storeBuildCalls -eq 1) {
          Remove-Item $script:e2eOutputDir -Recurse -Force
        }
      }
      Mock Remove-DeployDashE2ESigningCertificates {}
      $script:validationArchs = @()
      Mock Invoke-DeployDashSignedMsixValidation {
        $script:validationArchs += $Arch
      }
      Mock New-DeployDashE2ESigningCertificate {
        Set-Content $CertificatePath "public"
        return "ABC123"
      }
      Mock Invoke-DeployDashSignTool {}
      Mock Invoke-DeployDashE2EPackagePreSignValidation {}
      $result = Invoke-DeployDashWindowsStoreE2EPairBuild `
        -AppDir $appDir `
        -BaseVersion "1.0.0" `
        -CandidateVersion "1.0.1" `
        -Arch "x64"
      Test-Path $result.BasePackage | Should -BeTrue
      Test-Path $result.CandidatePackage | Should -BeTrue
      Test-Path $result.Certificate | Should -BeTrue
      Test-Path $legacyPfx | Should -BeFalse
      Assert-MockCalled Invoke-DeployDashStoreBuildScript -Times 2
      Assert-MockCalled Remove-DeployDashE2ESigningCertificates -Times 1
      Assert-MockCalled New-DeployDashE2ESigningCertificate -Times 1
      Assert-MockCalled Invoke-DeployDashE2EPackagePreSignValidation -Times 2
      Assert-MockCalled Invoke-DeployDashSignTool -Times 2
      Assert-MockCalled Invoke-DeployDashSignedMsixValidation -Times 2
      ($script:validationArchs -join ",") | Should -Be "x64,x64"
    }

    It "resolves production packages per arch" {
      $appDir = Join-Path $TestDrive "arch-app"
      $scripts = Join-Path $appDir "scripts"
      $lib = Join-Path $scripts "lib"
      $installer = Join-Path $appDir "build/windows/installer"
      New-Item -ItemType Directory -Force -Path $lib, $installer | Out-Null
      Set-Content `
        (Join-Path $lib "backend_paths.ps1") `
        @'
function Resolve-BackendScriptPath { return "contracts.py" }
function Resolve-UvPython313 { return "python.exe" }
'@
      Set-Content `
        (Join-Path $lib "windows_sdk.ps1") `
        'function Resolve-WindowsSdkTool { return "signtool.exe" }'
      Set-Content (Join-Path $scripts "build_windows_store.ps1") "fixture"
      Set-Content `
        (Join-Path $installer "DeployDash_1.0.0.0_arm64.msix") `
        "arm64-base"
      Set-Content `
        (Join-Path $installer "DeployDash_1.0.1.0_arm64.msix") `
        "arm64-candidate"
      Mock Invoke-DeployDashStoreBuildScript {}
      Mock Remove-DeployDashE2ESigningCertificates {}
      Mock Invoke-DeployDashSignedMsixValidation {}
      Mock New-DeployDashE2ESigningCertificate {
        Set-Content $CertificatePath "public"
        return "ABC123"
      }
      Mock Invoke-DeployDashSignTool {}
      Mock Invoke-DeployDashE2EPackagePreSignValidation {}
      $result = Invoke-DeployDashWindowsStoreE2EPairBuild `
        -AppDir $appDir `
        -BaseVersion "1.0.0" `
        -CandidateVersion "1.0.1" `
        -Arch "arm64"
      Test-Path $result.BasePackage | Should -BeTrue
      Test-Path $result.CandidatePackage | Should -BeTrue
      (Get-Content $result.BasePackage -Raw).Trim() | Should -Be "arm64-base"
      (Get-Content $result.CandidatePackage -Raw).Trim() | Should -Be "arm64-candidate"
      Assert-MockCalled Invoke-DeployDashSignTool -Times 2
    }

    It "rejects certificate generation without both certificate files" {
      $appDir = Join-Path $TestDrive "missing-certificate-app"
      $scripts = Join-Path $appDir "scripts"
      $lib = Join-Path $scripts "lib"
      New-Item -ItemType Directory -Force -Path $lib | Out-Null
      Set-Content `
        (Join-Path $lib "backend_paths.ps1") `
        @'
function Resolve-BackendScriptPath { return "contracts.py" }
function Resolve-UvPython313 { return "python.exe" }
'@
      Set-Content `
        (Join-Path $lib "windows_sdk.ps1") `
        'function Resolve-WindowsSdkTool { return "signtool.exe" }'
      Set-Content (Join-Path $scripts "build_windows_store.ps1") "fixture"
      Mock Invoke-DeployDashStoreBuildScript {}
      Mock Remove-DeployDashE2ESigningCertificates {}
      Mock New-DeployDashE2ESigningCertificate { return "ABC123" }
      { Invoke-DeployDashWindowsStoreE2EPairBuild `
          -AppDir $appDir `
          -BaseVersion "1.0.0" `
          -CandidateVersion "1.0.1" `
          -Arch "x64" } |
        Should -Throw "*Could not create*"
    }
  }
}
