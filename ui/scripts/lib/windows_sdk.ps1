function Resolve-WindowsSdkTool {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  # Never resolve through PATH: hosted runners carry a ClickOnce-era
  # signtool.exe on PATH (file version 4.00) that cannot sign MSIX
  # packages, and taking it while makeappx.exe comes from the newest
  # Kits directory fails signing with 0x800700C1. Both tools always
  # come from one Kits layout so the pair cannot split.
  $roots = @()
  if (-not [string]::IsNullOrWhiteSpace($env:DEPLOYDASH_WINDOWS_SDK_BIN)) {
    $roots += $env:DEPLOYDASH_WINDOWS_SDK_BIN
  }
  foreach ($programFiles in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
      $roots += Join-Path $programFiles "Windows Kits\10\bin"
    }
  }

  foreach ($root in $roots | Select-Object -Unique) {
    $direct = Join-Path $root $Name
    if (Test-Path $direct -PathType Leaf) {
      return (Resolve-Path $direct).Path
    }
    if (-not (Test-Path $root -PathType Container)) {
      continue
    }
    foreach ($versionDir in Get-ChildItem $root -Directory |
      Sort-Object Name -Descending) {
      $candidate = Join-Path $versionDir.FullName ("x64\" + $Name)
      if (Test-Path $candidate -PathType Leaf) {
        return (Resolve-Path $candidate).Path
      }
    }
  }

  throw "Windows SDK tool is not installed: $Name"
}
