function Resolve-BackendRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  $backendRoot = $env:DEPLOYDASH_ORCHESTRATOR_ROOT
  if ([string]::IsNullOrWhiteSpace($backendRoot)) {
    $backendRoot = Join-Path $RepoRoot "orchestrator"
  }

  if (-not [System.IO.Path]::IsPathRooted($backendRoot)) {
    $backendRoot = Join-Path $RepoRoot $backendRoot
  }

  if (-not (Test-Path $backendRoot)) {
    throw "Backend app root not found: $backendRoot"
  }

  return (Resolve-Path $backendRoot).Path
}

function Resolve-BackendScriptPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$ScriptName
  )

  $backendRoot = Resolve-BackendRoot -RepoRoot $RepoRoot
  $scriptPath = Join-Path $backendRoot ("scripts/" + $ScriptName)

  if (-not (Test-Path $scriptPath)) {
    throw "Backend helper script not found: $scriptPath"
  }

  return (Resolve-Path $scriptPath).Path
}

function Resolve-UvPython313 {
  $override = $env:DEPLOYDASH_WINDOWS_PYTHON313
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    if (-not (Test-Path $override -PathType Leaf)) {
      throw "Configured Python 3.13.14 interpreter not found: $override"
    }
    return (Resolve-Path $override).Path
  }

  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw "Missing required command: uv"
  }

  $pythonInterpreter = (& uv python find 3.13.14).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pythonInterpreter)) {
    throw "uv could not find a Python 3.13.14 interpreter. Run: uv python install 3.13.14"
  }

  return $pythonInterpreter
}
