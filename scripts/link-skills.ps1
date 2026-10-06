<#
.SYNOPSIS
  Ensure the DSH_HOME mirror
    <DSH_HOME>\agent-preset-bundles\dsh-taskforce
  is a directory JUNCTION pointing back to this bundle (single source of truth,
  no second copy to drift).

.DESCRIPTION
  cordis.patch.yml resolves the skill dir as
    dshHomePath('agent-preset-bundles/dsh-taskforce/skills')
  so the mirror path must resolve to the bundle on disk. This script makes that
  mirror a junction instead of a hand-made copy.

  Idempotent: running it twice is a no-op the second time.

  Exit codes
    0  mirror is (or now is) a junction pointing at this bundle
    1  conflict, or -Check found the mirror missing/wrong (nothing was modified)
    2  environment / usage error (DSH_HOME unset or relative, bundle root missing)

  Behavior matrix
    missing                    -> create parent dir + junction
    junction, correct target   -> no-op, print OK
    junction, wrong target     -> CONFLICT, print remediation, do not touch it
    real directory (not link)  -> CONFLICT (looks like a stale copy), do not overwrite
    file / other reparse point -> CONFLICT, print remediation

  Switches
    -Check   verify only, never modify (0 = linked, 1 = not linked)
    -WhatIf  print the plan, never touch the disk

  Compatibility: Windows PowerShell 5.1 and pwsh 7. Only cmdlets / .NET APIs
  available in 5.1; no PS7-only syntax (no ??, no ternary, no 3-arg Join-Path).

.EXAMPLE
  powershell -NoProfile -File .\scripts\link-skills.ps1
.EXAMPLE
  powershell -NoProfile -File .\scripts\link-skills.ps1 -Check
.EXAMPLE
  powershell -NoProfile -File .\scripts\link-skills.ps1 -WhatIf
#>
[CmdletBinding()]
param(
    # Bundle root; defaults to the parent of this script's folder.
    [string]$BundlePath,
    # Mirror path; defaults to <DSH_HOME>\agent-preset-bundles\dsh-taskforce.
    [string]$MirrorPath,
    # Verify only, do not modify anything.
    [switch]$Check,
    # Print the plan, do not write anything.
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Fail {
    param([string]$Message, [int]$Code)
    Write-Host "ERROR: $Message"
    exit $Code
}

# ---------------------------------------------------------------- bundle root
$bundle = $BundlePath
if ([string]::IsNullOrWhiteSpace($bundle)) { $bundle = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($bundle)) {
    Fail 'cannot determine the bundle root (no -BundlePath and no $PSScriptRoot)' 2
}
$bundle = [System.IO.Path]::GetFullPath($bundle).TrimEnd('\')

if (-not (Test-Path -LiteralPath $bundle -PathType Container)) {
    Fail "bundle root does not exist: $bundle" 2
}
if (-not (Test-Path -LiteralPath (Join-Path $bundle 'cordis.patch.yml') -PathType Leaf)) {
    Fail "not a preset bundle (cordis.patch.yml not found): $bundle" 2
}

# ------------------------------------------------------------------ DSH_HOME
$dshHome = $env:DSH_HOME
if ([string]::IsNullOrWhiteSpace($dshHome)) {
    Fail 'DSH_HOME is not set. Refusing to guess: an unset DSH_HOME would degrade the mirror path to a root-relative path. Set $env:DSH_HOME and re-run.' 2
}
if (-not [System.IO.Path]::IsPathRooted($dshHome)) {
    Fail "DSH_HOME is not an absolute path: $dshHome" 2
}
$dshHome = [System.IO.Path]::GetFullPath($dshHome).TrimEnd('\')

# ---------------------------------------------------------------- mirror path
$mirror = $MirrorPath
if ([string]::IsNullOrWhiteSpace($mirror)) {
    $mirror = Join-Path (Join-Path $dshHome 'agent-preset-bundles') 'dsh-taskforce'
}
elseif (-not [System.IO.Path]::IsPathRooted($mirror)) {
    $mirror = Join-Path $dshHome $mirror
}
$mirror = [System.IO.Path]::GetFullPath($mirror).TrimEnd('\')
$mirrorParent = Split-Path -Parent $mirror

Write-Host "bundle source : $bundle"
Write-Host "mirror target : $mirror"

# ------------------------------------------------------------- current state
$item = Get-Item -LiteralPath $mirror -Force -ErrorAction SilentlyContinue
$mode = 'missing'
$linkType = ''
$linkTarget = ''
if ($null -ne $item) {
    $isReparse = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    $ltProp = $item.PSObject.Properties['LinkType']
    if ($null -ne $ltProp -and -not [string]::IsNullOrEmpty([string]$ltProp.Value)) {
        $linkType = [string]$ltProp.Value
    }
    $tgProp = $item.PSObject.Properties['Target']
    if ($null -ne $tgProp -and $null -ne $tgProp.Value) {
        $targets = @($tgProp.Value)
        if ($targets.Count -gt 0 -and -not [string]::IsNullOrEmpty([string]$targets[0])) {
            $linkTarget = [string]$targets[0]
        }
    }
    if ($linkType -eq 'Junction') { $mode = 'junction' }
    elseif ($isReparse) { $mode = 'reparse-other' }
    elseif ($item.PSIsContainer) { $mode = 'dir' }
    else { $mode = 'file' }
}

$targetNorm = ''
if (-not [string]::IsNullOrEmpty($linkTarget)) {
    $targetNorm = $linkTarget.TrimEnd('\')
    try { $targetNorm = [System.IO.Path]::GetFullPath($targetNorm).TrimEnd('\') } catch { }
}
$linkedOk = ($mode -eq 'junction') -and ([string]::Equals($targetNorm, $bundle, [System.StringComparison]::OrdinalIgnoreCase))

Write-Host "current state : mode=$mode LinkType=$linkType Target=$linkTarget"

# ------------------------------------------------------------------ decisions
if ($linkedOk) {
    Write-Host "OK: $mirror is a junction -> $bundle (no-op)"
    exit 0
}

if ($WhatIf) {
    if ($mode -eq 'missing') {
        Write-Host "PLAN (WhatIf): New-Item -ItemType Directory -Force -Path '$mirrorParent'"
        Write-Host "PLAN (WhatIf): New-Item -ItemType Junction -Path '$mirror' -Target '$bundle'"
        Write-Host 'PLAN (WhatIf): nothing was written'
        exit 0
    }
    Write-Host "PLAN (WhatIf): would REFUSE to modify the existing $mode at $mirror (conflict), nothing was written"
    exit 1
}

if ($Check) {
    if ($mode -eq 'missing') {
        Write-Host "CHECK FAILED: mirror does not exist: $mirror"
        Write-Host '  remediation: run scripts\link-skills.ps1 (without -Check)'
        exit 1
    }
    if ($mode -eq 'junction') {
        Write-Host "CHECK FAILED: junction points to the wrong target: $linkTarget"
        Write-Host "  expected: $bundle"
        exit 1
    }
    Write-Host "CHECK FAILED: existing $mode at $mirror is not a junction to this bundle"
    exit 1
}

if ($mode -eq 'missing') {
    if (-not (Test-Path -LiteralPath $mirrorParent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $mirrorParent | Out-Null
        Write-Host "created directory: $mirrorParent"
    }
    New-Item -ItemType Junction -Path $mirror -Target $bundle | Out-Null
    $created = Get-Item -LiteralPath $mirror -Force
    Write-Host "OK: created junction $mirror -> $bundle"
    Write-Host "  verified LinkType=$($created.LinkType) Target=$($created.Target)"
    exit 0
}

if ($mode -eq 'junction') {
    Write-Host "CONFLICT: $mirror is a junction but points to a different target."
    Write-Host "  actual  : $linkTarget"
    Write-Host "  expected: $bundle"
    Write-Host '  Refusing to modify it. Remediation (removes the link only, never the target data):'
    Write-Host "    Remove-Item -LiteralPath '$mirror' -Force"
    Write-Host "    & '$PSCommandPath'"
    exit 1
}

if ($mode -eq 'dir') {
    Write-Host "CONFLICT: $mirror exists and is a REAL directory, not a junction."
    Write-Host '  This looks like a hand-made copy: it will drift from the bundle. Not overwriting it.'
    Write-Host '  Remediation (backup + relink, then diff the backup before deleting it):'
    Write-Host "    Move-Item -LiteralPath '$mirror' -Destination '$mirror.bak-<timestamp>'"
    Write-Host "    & '$PSCommandPath'"
    exit 1
}

Write-Host "CONFLICT: $mirror exists as a $mode (LinkType=$linkType), which is not the expected junction."
Write-Host '  Refusing to overwrite. Remediation:'
Write-Host "    Remove-Item -LiteralPath '$mirror' -Force"
Write-Host "    & '$PSCommandPath'"
exit 1
