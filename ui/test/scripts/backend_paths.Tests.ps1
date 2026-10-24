Describe "backend path helpers" {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot "../../scripts/lib/backend_paths.ps1"
    . $scriptPath
  }

  BeforeEach {
    $script:previousBackendRoot = $env:DEPLOYDASH_ORCHESTRATOR_ROOT
    $script:previousPython = $env:DEPLOYDASH_WINDOWS_PYTHON313
    $env:DEPLOYDASH_ORCHESTRATOR_ROOT = $null
    $env:DEPLOYDASH_WINDOWS_PYTHON313 = $null
  }

  AfterEach {
    $env:DEPLOYDASH_ORCHESTRATOR_ROOT = $script:previousBackendRoot
    $env:DEPLOYDASH_WINDOWS_PYTHON313 = $script:previousPython
  }

  It "resolves default relative and absolute backend roots" {
    $root = Join-Path $TestDrive "repo"
    $backend = Join-Path $root "orchestrator"
    New-Item -ItemType Directory -Force -Path $backend | Out-Null
    Resolve-BackendRoot -RepoRoot $root | Should -Be (Resolve-Path $backend).Path
    $env:DEPLOYDASH_ORCHESTRATOR_ROOT = "orchestrator"
    Resolve-BackendRoot -RepoRoot $root | Should -Be (Resolve-Path $backend).Path
    $env:DEPLOYDASH_ORCHESTRATOR_ROOT = $backend
    Resolve-BackendRoot -RepoRoot $root | Should -Be (Resolve-Path $backend).Path
  }

  It "rejects missing backend roots and scripts" {
    { Resolve-BackendRoot -RepoRoot $TestDrive } | Should -Throw "*not found*"
    $backend = Join-Path $TestDrive "orchestrator"
    New-Item -ItemType Directory -Force -Path $backend | Out-Null
    {
      Resolve-BackendScriptPath -RepoRoot $TestDrive -ScriptName "missing.py"
    } | Should -Throw "*helper script not found*"
  }

  It "resolves an existing backend script" {
    $scripts = Join-Path $TestDrive "orchestrator/scripts"
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    $script = Join-Path $scripts "helper.py"
    Set-Content -Path $script -Value "pass"
    Resolve-BackendScriptPath -RepoRoot $TestDrive -ScriptName "helper.py" |
      Should -Be (Resolve-Path $script).Path
  }

  It "uses a validated explicit Python override" {
    $python = Join-Path $TestDrive "python.exe"
    Set-Content -Path $python -Value "python"
    $env:DEPLOYDASH_WINDOWS_PYTHON313 = $python
    Resolve-UvPython313 | Should -Be (Resolve-Path $python).Path
    $env:DEPLOYDASH_WINDOWS_PYTHON313 = (Join-Path $TestDrive "missing.exe")
    { Resolve-UvPython313 } | Should -Throw "*interpreter not found*"
  }

  It "requires uv when no explicit Python override exists" {
    Mock Get-Command { $null } -ParameterFilter { $Name -eq "uv" }
    { Resolve-UvPython313 } | Should -Throw "*Missing required command: uv*"
  }

  It "returns the Python interpreter reported by uv" {
    function global:uv { $global:LASTEXITCODE = 0; "C:\Python313\python.exe" }
    Mock Get-Command { [pscustomobject]@{Source = "uv.exe"} } `
      -ParameterFilter { $Name -eq "uv" }
    try {
      Resolve-UvPython313 | Should -Be "C:\Python313\python.exe"
    } finally {
      Remove-Item Function:\global:uv
    }
  }

  It "rejects failed and empty uv resolution" {
    Mock Get-Command { [pscustomobject]@{Source = "uv.exe"} } `
      -ParameterFilter { $Name -eq "uv" }
    function global:uv { $global:LASTEXITCODE = 1; "" }
    try {
      { Resolve-UvPython313 } | Should -Throw "*could not find*"
    } finally {
      Remove-Item Function:\global:uv
    }
  }
}
