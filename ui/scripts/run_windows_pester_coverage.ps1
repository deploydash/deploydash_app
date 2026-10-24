$ErrorActionPreference = "Stop"
# Application-owned Windows PowerShell coverage: the release packaging
# helpers under ui/scripts/lib with their Pester suites under
# ui/test/scripts. QA-harness modules are covered from
# deploydash_tests, never here.
$AppDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RequiredVersion = [version]"5.9.0"
$Installed = Get-Module -ListAvailable -Name Pester |
  Where-Object Version -eq $RequiredVersion
if (-not $Installed) {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12
  Install-PackageProvider `
    -Name NuGet `
    -MinimumVersion "2.8.5.201" `
    -Scope CurrentUser `
    -Force `
    -ForceBootstrap | Out-Null
  Install-Module `
    -Name Pester `
    -RequiredVersion $RequiredVersion `
    -Scope CurrentUser `
    -Force `
    -AllowClobber `
    -SkipPublisherCheck `
    -Repository PSGallery `
    -Confirm:$false
}
Import-Module Pester -RequiredVersion $RequiredVersion -Force
# Nested Join-Path stays compatible with Windows PowerShell 5.1 if this
# script is ever invoked via `powershell.exe` instead of `pwsh`.
$OutputRoot = Join-Path (Join-Path (Join-Path $AppDir "build") "coverage") "windows-pester"
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$Configuration = New-PesterConfiguration
$Configuration.Run.Path = @(
  (Join-Path $AppDir "test" "scripts" "backend_paths.Tests.ps1"),
  (Join-Path $AppDir "test" "scripts" "windows_sdk.Tests.ps1"),
  (Join-Path $AppDir "test" "scripts" "windows_store_packaging.Tests.ps1")
)
$Configuration.Run.PassThru = $true
$Configuration.CodeCoverage.Enabled = $true
$Configuration.CodeCoverage.Path = @(
  (Join-Path $AppDir "scripts" "lib" "backend_paths.ps1"),
  (Join-Path $AppDir "scripts" "lib" "windows_sdk.ps1"),
  (Join-Path $AppDir "scripts" "lib" "windows_store_packaging.psm1"),
  (Join-Path $AppDir "scripts" "lib" "windows_store_e2e.psm1")
)
$Configuration.CodeCoverage.CoveragePercentTarget = 100
$Configuration.CodeCoverage.OutputPath = Join-Path $OutputRoot "coverage.xml"
$Configuration.CodeCoverage.OutputFormat = "JaCoCo"
$Configuration.TestResult.Enabled = $true
$Configuration.TestResult.OutputPath = Join-Path $OutputRoot "tests.xml"
$Configuration.TestResult.OutputFormat = "NUnitXml"
$Result = Invoke-Pester -Configuration $Configuration
if ($Result.FailedCount -ne 0) {
  throw "$($Result.FailedCount) Windows Store Pester test(s) failed."
}
if ($Result.CodeCoverage.CoveragePercent -lt 100) {
  throw "Windows Store PowerShell coverage is $($Result.CodeCoverage.CoveragePercent)%."
}
