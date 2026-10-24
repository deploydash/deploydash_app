Describe "Windows SDK tool resolution" {
  BeforeAll {
    # Resolve from $PSScriptRoot and define helpers here: file-top
    # $script: variables and functions are not visible inside Describe
    # blocks under Pester 5.9 (null RepoRoot failed all four tests; the
    # helper below failed the two that call it).
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
    . (Join-Path $repoRoot "ui/scripts/lib/windows_sdk.ps1")

    function New-FakeSdkTool {
      param(
        [Parameter(Mandatory = $true)][string]$ProgramFilesRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Name
      )

      $dir = Join-Path $ProgramFilesRoot "Windows Kits\10\bin\$Version\x64"
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $tool = Join-Path $dir $Name
      "fake" | Set-Content -Path $tool -Encoding ascii
      return $tool
    }
  }

  BeforeEach {
    $script:savedSdkBin = $env:DEPLOYDASH_WINDOWS_SDK_BIN
    $script:savedPfX86 = ${env:ProgramFiles(x86)}
    $script:savedPf = $env:ProgramFiles
    $script:savedPath = $env:PATH
  }

  AfterEach {
    $env:DEPLOYDASH_WINDOWS_SDK_BIN = $script:savedSdkBin
    ${env:ProgramFiles(x86)} = $script:savedPfX86
    $env:ProgramFiles = $script:savedPf
    $env:PATH = $script:savedPath
  }

  It "resolves tools from the newest Kits version directory" {
    ${env:ProgramFiles(x86)} = Join-Path $TestDrive "pf86"
    $env:ProgramFiles = Join-Path $TestDrive "pf64-missing"
    $env:DEPLOYDASH_WINDOWS_SDK_BIN = $null
    New-FakeSdkTool ${env:ProgramFiles(x86)} "10.0.22621.0" "widget.exe" | Out-Null
    $expected = New-FakeSdkTool ${env:ProgramFiles(x86)} "10.0.26100.0" "widget.exe"
    Resolve-WindowsSdkTool -Name "widget.exe" |
      Should -Be ((Resolve-Path $expected).Path)
  }

  It "prefers the explicit SDK bin override" {
    $bin = Join-Path $TestDrive "override"
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $tool = Join-Path $bin "widget.exe"
    "fake" | Set-Content -Path $tool -Encoding ascii
    $env:DEPLOYDASH_WINDOWS_SDK_BIN = $bin
    ${env:ProgramFiles(x86)} = Join-Path $TestDrive "pf86-missing"
    $env:ProgramFiles = Join-Path $TestDrive "pf64-missing"
    Resolve-WindowsSdkTool -Name "widget.exe" |
      Should -Be ((Resolve-Path $tool).Path)
  }

  It "ignores copies on PATH in favour of the Kits layout" {
    $shadow = Join-Path $TestDrive "shadow"
    New-Item -ItemType Directory -Force -Path $shadow | Out-Null
    "fake" | Set-Content -Path (Join-Path $shadow "widget.exe") -Encoding ascii
    $env:PATH = "$shadow;$env:PATH"
    ${env:ProgramFiles(x86)} = Join-Path $TestDrive "pf86"
    $env:ProgramFiles = Join-Path $TestDrive "pf64-missing"
    $env:DEPLOYDASH_WINDOWS_SDK_BIN = $null
    $expected = New-FakeSdkTool ${env:ProgramFiles(x86)} "10.0.26100.0" "widget.exe"
    Resolve-WindowsSdkTool -Name "widget.exe" |
      Should -Be ((Resolve-Path $expected).Path)
  }

  It "throws a clear error when the tool is nowhere" {
    $env:DEPLOYDASH_WINDOWS_SDK_BIN = $null
    ${env:ProgramFiles(x86)} = Join-Path $TestDrive "pf86-missing"
    $env:ProgramFiles = Join-Path $TestDrive "pf64-missing"
    { Resolve-WindowsSdkTool -Name "widget.exe" } |
      Should -Throw "*not installed*"
  }
}
