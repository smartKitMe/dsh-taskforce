<#
.SYNOPSIS
  Static validation of the dsh-taskforce preset bundle: V1..V12.

.DESCRIPTION
  Prints one line per check:  PASS V1 <description>   /   FAIL V1 <description>
  Exit code 1 if any check FAILs, 0 when all checks PASS (or are downgraded to WARN).

  Check list (static criteria, no preset is loaded and no session is started):
    V1  cordis.patch.yml parses as YAML via js-yaml (custom !!js scalar tag accepted)
    V2  top level is an array with exactly one `insert`; exactly one row named
        '@deepseek-ai/dsh-agent-preset'
    V3  that row's config.id / config.name / config.description / config.order exist
        with correct types (string / string / string / number)
    V4  every `id` in the document is globally unique
    V5  every !!js expression compiles (node:vm Script, not executed)
    V6  skills/agent-team-protocol/SKILL.md exists, frontmatter has name+description,
        and name equals the directory name
    V7  mirror is a JUNCTION back to this bundle -- all three required:
        (1) LinkType -eq 'Junction'; (2) the junction target resolves to this bundle
        directory (case-insensitive, trailing separators and \\?\ / \??\ / \\?\UNC\
        prefixes tolerated); (3) the mirrored skills\agent-team-protocol\SKILL.md
        exists. A real COPIED directory FAILs on purpose: a copy satisfies Test-Path
        but silently drifts from the bundle. Remediation: scripts\link-skills.ps1.
    V8  required plugin rows present (persona, agent-instructions, tool-fs,
        tool-fs-search, tool-jobs, skill-filesystem, tool-skill) and at least one of
        tool-pwsh / tool-bash is not disabled
    V9  no duplicate-domain rows: neither `agent-team` nor `tool-agent-team` present
    V10 persona.prefix mentions 'agent-team-protocol' (manual is explicitly referenced)
    V11 documentation consistency across cordis.patch.yml / SKILL.md / README.md:
        (a) capacity key=value claims must use the canon section-1 numbers
            (maxMembers 8|16, maxTasks 256, maxPendingMessagesPerMember 64,
             maxMessageBytes 65536, disposalTimeoutMs 5000);
        (b) '8' must never be presented as the preset's mechanical cap: any line that
            says e.g. "上限 8" / "maxMembers: 8" must also be qualified by one of
            profile / 实现默认 / 以运行时为准 / 16.
        (c) F6 member-limit shorthand: a capacity statement that binds 'maxMembers' or
            '成员上限/最多/至多' directly to a bare 8 -- e.g. "maxMembers 8" -- FAILs
            unless the same line discloses where the 8 comes from (profile / 实现默认 /
            运行时). The match needs a capacity connector between the cap name and the 8
            (separator / ： / = / ( / 上限 / 为 / 默认 ...); plain proximity would
            false-positive on "不占 maxMembers，见第 7、8 节".
            A "8/16" pair names BOTH canonical values, so it is treated as a
            two-value disclosure and PASSes by default; -StrictMemberShorthand makes
            the pair FAIL as well (SKILL.md frontmatter currently uses exactly
            "maxMembers 8/16", so strict mode reports it -- that file is owned by
            another writer, this script never edits it).
    V12 the delivery directory contains no .work/ (checked after integration)

  -WarnOnly V10,V11,V12   convenience for pre-integration runs: those ids are printed
                          as WARN instead of FAIL (default: strict, empty).
  -DshHome <path>         V7 testing hook: check the mirror under this path instead
                          of $env:DSH_HOME.
  -StrictMemberShorthand  V11(c): also flag "maxMembers 8/16" style pairs.

  Compatibility: Windows PowerShell 5.1 and pwsh 7 (no PS7-only syntax).
  This is the Windows implementation. Linux/macOS: run scripts/validate-preset.sh, a
  POSIX launcher for the cross-platform twin scripts/validate-preset.mjs (same checks,
  same verdicts, same exit code); there V7 requires a symlink instead of a junction.
  IMPORTANT: keep this file saved as UTF-8 **with BOM**. The V11 rules contain
  Chinese literals and Windows PowerShell 5.1 decodes BOM-less sources as ANSI,
  which would corrupt them (V11 self-detects that and FAILs instead of passing).

.EXAMPLE
  powershell -NoProfile -File .\scripts\validate-preset.ps1
#>
[CmdletBinding()]
param(
    [string]$BundlePath,
    # node.exe used for V1/V5 (js-yaml + vm). Empty = auto-discover from $env:DSH_HOME
    # (<DSH_HOME>\dsh-runtimes\*\dependencies\node\bin\node.exe), then from PATH.
    [string]$NodePath,
    # js-yaml module directory. Empty = auto-discover from $env:DSH_HOME
    # (<DSH_HOME>\profiles\node_modules\js-yaml or <DSH_HOME>\dsh-runtimes\*\dependencies\node_modules\js-yaml),
    # then ask node itself (require.resolve). Never hardcode one machine's layout.
    [string]$JsYamlPath,
    # V7 testing hook: pretend DSH_HOME is this path (default: $env:DSH_HOME).
    # Lets the junction-vs-real-copy branches be tested without touching the real mirror.
    [string]$DshHome,
    # V11(c): also flag a "maxMembers 8/16" pair that carries no disclosure qualifier.
    [switch]$StrictMemberShorthand,
    # Ids to downgrade from FAIL to WARN (pre-integration convenience).
    [string[]]$WarnOnly = @()
)

$ErrorActionPreference = 'Continue'

$script:Passed = 0
$script:Warned = 0
$script:Failed = 0
$script:FailedIds = New-Object System.Collections.ArrayList
$script:WarnedIds = New-Object System.Collections.ArrayList

function Report {
    param([string]$Id, [string]$Desc, [string]$Status, [string]$Detail)
    $line = "$Status $Id $Desc"
    if (-not [string]::IsNullOrEmpty($Detail)) { $line = $line + ' -- ' + $Detail }
    Write-Host $line
}

function Check {
    param([string]$Id, [string]$Desc, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        $script:Passed = $script:Passed + 1
        Report $Id $Desc 'PASS' $Detail
        return
    }
    if ($WarnOnly -contains $Id) {
        $script:Warned = $script:Warned + 1
        [void]$script:WarnedIds.Add($Id)
        Report $Id $Desc 'WARN' $Detail
        return
    }
    $script:Failed = $script:Failed + 1
    [void]$script:FailedIds.Add($Id)
    Report $Id $Desc 'FAIL' $Detail
}

# ------------------------------------------------------------------ locations
$bundle = $BundlePath
if ([string]::IsNullOrWhiteSpace($bundle)) { $bundle = Split-Path -Parent $PSScriptRoot }
$bundle = [System.IO.Path]::GetFullPath($bundle).TrimEnd('\')
$yamlPath = Join-Path $bundle 'cordis.patch.yml'
$skillMd = Join-Path (Join-Path $bundle 'skills\agent-team-protocol') 'SKILL.md'
$readmePath = Join-Path $bundle 'README.md'

Write-Host "bundle: $bundle"
Write-Host ""

# ------------------------------------------------- V1: YAML parses (js-yaml)
# ------------------------------------- tool discovery (V1): do not hardcode paths
# The DSH runtime ships both node.exe and js-yaml, so resolve them from $env:DSH_HOME
# first and fall back to PATH / require.resolve. Without this, V1 only worked on the
# machine the script was written on.
if ([string]::IsNullOrWhiteSpace($NodePath)) {
    $nodeCandidates = New-Object System.Collections.ArrayList
    $dshHomeForTools = $env:DSH_HOME
    if ([string]::IsNullOrWhiteSpace($dshHomeForTools)) {
        # Discovery-only fallback: the conventional DSH home. V7 still refuses to guess
        # the mirror path, but locating the tools must not require an exported variable.
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $dshHomeForTools = Join-Path $env:USERPROFILE '.dsh' }
        elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $dshHomeForTools = Join-Path $env:HOME '.dsh' }
    }
    if (-not [string]::IsNullOrWhiteSpace($dshHomeForTools)) {
        $rtDir = Join-Path $dshHomeForTools 'dsh-runtimes'
        if (Test-Path -LiteralPath $rtDir) {
            foreach ($rt in @(Get-ChildItem -LiteralPath $rtDir -Directory -ErrorAction SilentlyContinue)) {
                [void]$nodeCandidates.Add((Join-Path $rt.FullName 'dependencies\node\bin\node.exe'))
                [void]$nodeCandidates.Add((Join-Path $rt.FullName 'dependencies\node\node.exe'))
            }
        }
    }
    foreach ($cand in $nodeCandidates) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) { $NodePath = $cand; break }
    }
}
if ([string]::IsNullOrWhiteSpace($JsYamlPath) -and -not [string]::IsNullOrWhiteSpace($env:DSH_JS_YAML)) {
    $JsYamlPath = $env:DSH_JS_YAML
}
if ([string]::IsNullOrWhiteSpace($JsYamlPath)) {
    $jsCandidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($dshHomeForTools)) {
        [void]$jsCandidates.Add((Join-Path $dshHomeForTools 'profiles\node_modules\js-yaml'))
        $rtDir2 = Join-Path $dshHomeForTools 'dsh-runtimes'
        if (Test-Path -LiteralPath $rtDir2) {
            foreach ($rt in @(Get-ChildItem -LiteralPath $rtDir2 -Directory -ErrorAction SilentlyContinue)) {
                [void]$jsCandidates.Add((Join-Path $rt.FullName 'dependencies\node_modules\js-yaml'))
            }
        }
    }
    foreach ($cand in $jsCandidates) {
        if (Test-Path -LiteralPath $cand) { $JsYamlPath = $cand; break }
    }
    if ([string]::IsNullOrWhiteSpace($JsYamlPath)) {
        $probeNode = if ([string]::IsNullOrWhiteSpace($NodePath)) { '' } else { $NodePath }
        if ($probeNode -eq '') { $cmdProbe = Get-Command node -ErrorAction SilentlyContinue; if ($null -ne $cmdProbe) { $probeNode = $cmdProbe.Source } }
        if (-not [string]::IsNullOrWhiteSpace($probeNode) -and (Test-Path -LiteralPath $probeNode -PathType Leaf)) {
            $resolvedJs = & $probeNode -e "try{process.stdout.write(require.resolve('js-yaml'))}catch(e){}" 2>`$null
            if (-not [string]::IsNullOrWhiteSpace($resolvedJs)) {
                # require.resolve gives <...>/js-yaml/index.js -> one level up is the module dir
                $JsYamlPath = Split-Path -Parent ([string]$resolvedJs).Trim()
            }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($NodePath)) { $NodePath = 'node (not found)' }
if ([string]::IsNullOrWhiteSpace($JsYamlPath)) { $JsYamlPath = 'js-yaml (not found: pass -JsYamlPath, set DSH_JS_YAML, or export DSH_HOME)' }

$probeJs = @'
const fs = require('fs');
const vm = require('vm');
const yaml = require(process.env.DSH_VALIDATE_JSYAML);
const JsType = new yaml.Type('tag:yaml.org,2002:js', { kind: 'scalar', construct: d => ({ __jsExpr: String(d) }) });
const schema = yaml.DEFAULT_SCHEMA.extend([JsType]);
const out = { ok: false, error: '', doc: null, js: [] };
try {
  const txt = fs.readFileSync(process.env.DSH_VALIDATE_YAML, 'utf8');
  out.doc = yaml.load(txt, { schema: schema });
  out.ok = true;
  const seen = [];
  const walk = v => {
    if (v && typeof v === 'object') {
      if (Array.isArray(v)) { v.forEach(walk); }
      else {
        if (typeof v.__jsExpr === 'string' && seen.indexOf(v.__jsExpr) < 0) { seen.push(v.__jsExpr); }
        Object.keys(v).forEach(k => walk(v[k]));
      }
    }
  };
  walk(out.doc);
  out.js = seen.map(e => {
    try { new vm.Script('(' + e + ')'); return { expr: e, ok: true, error: '' }; }
    catch (err) { return { expr: e, ok: false, error: String((err && err.message) || err) }; }
  });
} catch (e) {
  out.ok = false;
  out.error = String((e && e.message) || e);
  out.doc = null;
}
process.stdout.write(JSON.stringify(out));
'@

$parseOk = $false
$parseError = ''
$doc = $null
$jsList = @()

$nodeExe = $NodePath
if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $nodeExe = $cmd.Source }
}

if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) {
    Check 'V1' 'cordis.patch.yml parses as YAML (js-yaml)' $false "file not found: $yamlPath"
}
elseif (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf)) {
    Check 'V1' 'cordis.patch.yml parses as YAML (js-yaml)' $false "node.exe not found: $NodePath"
}
elseif (-not (Test-Path -LiteralPath $JsYamlPath)) {
    Check 'V1' 'cordis.patch.yml parses as YAML (js-yaml)' $false "js-yaml not found: $JsYamlPath"
}
else {
    $env:DSH_VALIDATE_YAML = $yamlPath
    $env:DSH_VALIDATE_JSYAML = $JsYamlPath
    $raw = (& $nodeExe -e $probeJs) -join ''
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    }
    if ($null -eq $parsed) {
        $parseError = "no JSON from node (exit=$LASTEXITCODE)"
    }
    elseif ($parsed.ok -ne $true) {
        $parseError = [string]$parsed.error
    }
    else {
        $parseOk = $true
        $doc = $parsed.doc
        $jsList = @($parsed.js)
    }
    if ($parseOk) {
        Check 'V1' 'cordis.patch.yml parses as YAML (js-yaml)' $true "node=$nodeExe; !!js tags accepted as scalars"
    }
    else {
        Check 'V1' 'cordis.patch.yml parses as YAML (js-yaml)' $false $parseError
    }
}

# --------------------------------------------------- collect plugin ids (once)
$script:IdNodes = @{}
$script:AllIds = New-Object System.Collections.ArrayList

function Walk-Ids {
    param($Node)
    if ($null -eq $Node) { return }
    if ($Node -is [string]) { return }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($child in $Node) { Walk-Ids $child }
        return
    }
    $idProp = $Node.PSObject.Properties['id']
    if ($null -ne $idProp -and $null -ne $idProp.Value) {
        $idValue = [string]$idProp.Value
        [void]$script:AllIds.Add($idValue)
        if (-not $script:IdNodes.ContainsKey($idValue)) { $script:IdNodes[$idValue] = $Node }
    }
    foreach ($p in $Node.PSObject.Properties) { Walk-Ids $p.Value }
}

if ($parseOk) { Walk-Ids $doc }

# ------------------------------------------- V2: one insert, one preset row
$insert = $null
$presetRow = $null
$v2ok = $false
$v2detail = 'skipped: V1 failed'
if ($parseOk) {
    $top = @($doc)
    $insertItems = @($top | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['insert'] })
    if ($top.Count -ne 1) {
        $v2detail = "top-level array has $($top.Count) entries (expected 1)"
    }
    elseif ($insertItems.Count -ne 1) {
        $v2detail = "found $($insertItems.Count) 'insert' keys at top level (expected 1)"
    }
    else {
        $insert = @($insertItems[0].insert)
        $rows = @($insert | Where-Object { $_ -ne $null -and $_.name -eq '@deepseek-ai/dsh-agent-preset' })
        if ($rows.Count -ne 1) {
            $v2detail = "found $($rows.Count) rows named '@deepseek-ai/dsh-agent-preset' (expected 1)"
        }
        else {
            $presetRow = $rows[0]
            $v2ok = $true
            $v2detail = "1 insert, $($insert.Count) rows, 1 preset row"
        }
    }
}
Check 'V2' "top level: exactly one insert with one '@deepseek-ai/dsh-agent-preset' row" $v2ok $v2detail

# ------------------------------------------------------- V3: preset config keys
$v3ok = $false
$v3detail = 'skipped: V1/V2 failed'
if ($null -ne $presetRow) {
    $cfgProp = $presetRow.PSObject.Properties['config']
    if ($null -eq $cfgProp -or $null -eq $cfgProp.Value) {
        $v3detail = 'config object missing'
    }
    else {
        $cfg = $cfgProp.Value
        $bad = New-Object System.Collections.ArrayList
        $idV = $cfg.PSObject.Properties['id']
        if ($null -eq $idV -or -not ($idV.Value -is [string]) -or [string]::IsNullOrEmpty([string]$idV.Value)) { [void]$bad.Add('config.id') }
        $nameV = $cfg.PSObject.Properties['name']
        if ($null -eq $nameV -or -not ($nameV.Value -is [string]) -or [string]::IsNullOrEmpty([string]$nameV.Value)) { [void]$bad.Add('config.name') }
        $descV = $cfg.PSObject.Properties['description']
        if ($null -eq $descV -or -not ($descV.Value -is [string]) -or [string]::IsNullOrEmpty([string]$descV.Value)) { [void]$bad.Add('config.description') }
        $orderV = $cfg.PSObject.Properties['order']
        $orderOk = $false
        if ($null -ne $orderV -and $null -ne $orderV.Value) {
            $ov = $orderV.Value
            if (($ov -is [int]) -or ($ov -is [long]) -or ($ov -is [double]) -or ($ov -is [decimal])) { $orderOk = $true }
        }
        if (-not $orderOk) { [void]$bad.Add('config.order') }
        if ($bad.Count -eq 0) {
            $v3ok = $true
            $v3detail = "id=$($cfg.id) order=$($cfg.order) name/description present"
        }
        else {
            $v3detail = 'missing/mistyped: ' + ($bad -join ', ')
        }
    }
}
Check 'V3' 'preset config.id/name/description/order present with correct types' $v3ok $v3detail

# ------------------------------------------------------- V4: globally unique ids
$v4ok = $false
$v4detail = 'skipped: V1 failed'
if ($parseOk) {
    $dups = @($script:AllIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dups.Count -eq 0) {
        $v4ok = $true
        $v4detail = "$($script:AllIds.Count) ids, all unique"
    }
    else {
        $v4detail = 'duplicate ids: ' + ($dups -join ', ')
    }
}
Check 'V4' 'every id in the document is globally unique' $v4ok $v4detail

# --------------------------------------------------- V5: !!js expressions compile
$v5ok = $false
$v5detail = 'skipped: V1 failed'
if ($parseOk) {
    $badJs = @($jsList | Where-Object { $_.ok -ne $true })
    if ($badJs.Count -eq 0) {
        $v5ok = $true
        $v5detail = "$($jsList.Count) !!js expressions compile (vm.Script, not executed)"
    }
    else {
        $parts = @()
        foreach ($b in $badJs) { $parts += ("[" + $b.expr + "] " + $b.error) }
        $v5detail = ($parts -join ' | ')
    }
}
Check 'V5' 'every !!js expression is syntactically valid JS' $v5ok $v5detail

# --------------------------------------------- V6: SKILL.md exists + frontmatter
$v6ok = $false
$v6detail = ''
$skillDirName = 'agent-team-protocol'
if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
    $v6detail = "file not found: $skillMd"
}
else {
    $fmLines = [System.IO.File]::ReadAllLines($skillMd, [System.Text.Encoding]::UTF8)
    $fmName = ''
    $fmDesc = ''
    $closed = $false
    if ($fmLines.Length -lt 3 -or $fmLines[0].Trim() -ne '---') {
        $v6detail = 'frontmatter does not start at line 1 with ---'
    }
    else {
        for ($i = 1; $i -lt $fmLines.Length; $i++) {
            if ($fmLines[$i].Trim() -eq '---') { $closed = $true; break }
            if ([string]::IsNullOrEmpty($fmName)) {
                $m = [regex]::Match($fmLines[$i], '^name:\s*(.+)$')
                if ($m.Success) { $fmName = $m.Groups[1].Value.Trim().Trim('"').Trim("'") }
            }
            if ([string]::IsNullOrEmpty($fmDesc)) {
                $m2 = [regex]::Match($fmLines[$i], '^description:\s*(.+)$')
                if ($m2.Success) { $fmDesc = $m2.Groups[1].Value.Trim() }
            }
        }
        if (-not $closed) {
            $v6detail = 'frontmatter is not closed with ---'
        }
        elseif ([string]::IsNullOrEmpty($fmName)) {
            $v6detail = 'frontmatter has no name'
        }
        elseif ([string]::IsNullOrEmpty($fmDesc)) {
            $v6detail = 'frontmatter has no description'
        }
        elseif ($fmName -ne $skillDirName) {
            $v6detail = "frontmatter name '$fmName' != directory name '$skillDirName'"
        }
        else {
            $v6ok = $true
            $v6detail = "name=$fmName, description=$($fmDesc.Length) chars"
        }
    }
}
Check 'V6' 'SKILL.md exists with frontmatter name/description and name == dir name' $v6ok $v6detail

# ------------------------------------------------------- V7: mirror resolves
# WHAT is checked and WHY:
#   DSH resolves this preset's skill dir as
#     dshHomePath('agent-preset-bundles/dsh-taskforce/skills')
#   so the mirror under %DSH_HOME% must be a JUNCTION back to this bundle. A real
#   copied directory also satisfies Test-Path, but it is a second source of truth
#   that silently drifts from the bundle -- exactly what this check must block.
#   All three are required: LinkType -eq 'Junction'; the junction target resolves to
#   this bundle dir; the mirrored SKILL.md exists.
function Normalize-LinkPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ($p.StartsWith('\\?\UNC\')) { $p = '\\' + $p.Substring(8) }
    elseif ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    elseif ($p.StartsWith('\??\')) { $p = $p.Substring(4) }
    $p = $p.TrimEnd('\').TrimEnd('/')
    if ([string]::IsNullOrEmpty($p)) { return '' }
    try { $p = [System.IO.Path]::GetFullPath($p).TrimEnd('\') } catch { }
    return $p
}

$v7ok = $false
$v7detail = ''
$dshHome = $DshHome
if ([string]::IsNullOrWhiteSpace($dshHome)) { $dshHome = $env:DSH_HOME }
if ([string]::IsNullOrWhiteSpace($dshHome)) {
    $v7detail = 'DSH_HOME is not set (and no -DshHome override was given)'
}
elseif (-not [System.IO.Path]::IsPathRooted($dshHome)) {
    $v7detail = "DSH_HOME is not an absolute path: $dshHome"
}
else {
    $mirrorRoot = Join-Path (Join-Path $dshHome.TrimEnd('\') 'agent-preset-bundles') 'dsh-taskforce'
    $mirrorSkill = Join-Path $mirrorRoot 'skills\agent-team-protocol\SKILL.md'
    $skillExists = Test-Path -LiteralPath $mirrorSkill -PathType Leaf
    $mItem = Get-Item -LiteralPath $mirrorRoot -Force -ErrorAction SilentlyContinue
    $mLinkType = ''
    $mTargetRaw = ''
    if ($null -ne $mItem) {
        $lt = $mItem.PSObject.Properties['LinkType']
        if ($null -ne $lt -and -not [string]::IsNullOrEmpty([string]$lt.Value)) { $mLinkType = [string]$lt.Value }
        $tg = $mItem.PSObject.Properties['Target']
        if ($null -ne $tg -and $null -ne $tg.Value) {
            $tv = @($tg.Value)
            if ($tv.Count -gt 0 -and -not [string]::IsNullOrEmpty([string]$tv[0])) { $mTargetRaw = [string]$tv[0] }
        }
    }
    $isJunction = ($mLinkType -eq 'Junction')
    $targetNorm = Normalize-LinkPath $mTargetRaw
    $bundleNorm = [System.IO.Path]::GetFullPath($bundle).TrimEnd('\')
    $targetMatches = (-not [string]::IsNullOrEmpty($targetNorm)) -and ([string]::Equals($targetNorm, $bundleNorm, [System.StringComparison]::OrdinalIgnoreCase))
    $v7ok = $isJunction -and $targetMatches -and $skillExists
    $v7detail = "checked: mirror must be a junction back to this bundle (a real copy passes Test-Path but silently drifts); " +
        "path=$mirrorSkill exists=$skillExists LinkType=$mLinkType Target=$mTargetRaw targetResolvesToBundle=$targetMatches expected=$bundleNorm"
    if (-not $skillExists) {
        $v7detail = $v7detail + '; mirrored SKILL.md not found -> run scripts\link-skills.ps1'
    }
    elseif (-not $isJunction) {
        $v7detail = $v7detail + '; mirror is NOT a junction (it is a real directory/copy) -> back it up, remove it, then run scripts\link-skills.ps1 (it refuses to overwrite a real dir)'
    }
    elseif (-not $targetMatches) {
        $v7detail = $v7detail + "; junction target '$mTargetRaw' does not resolve to this bundle -> run scripts\link-skills.ps1 (it reports the wrong target instead of overwriting)"
    }
}
Check 'V7' 'mirror is a Junction pointing back to this bundle (skill path resolves)' $v7ok $v7detail

# --------------------------------------------------- V8: required plugin rows
$v8ok = $false
$v8detail = 'skipped: V1 failed'
if ($parseOk) {
    $required = @('persona', 'agent-instructions', 'tool-fs', 'tool-fs-search', 'tool-jobs', 'skill-filesystem', 'tool-skill')
    $missing = @($required | Where-Object { -not $script:IdNodes.ContainsKey($_) })
    $shellEnabled = @()
    foreach ($shellRowId in @('tool-pwsh', 'tool-bash')) {
        if ($script:IdNodes.ContainsKey($shellRowId)) {
            $entry = $script:IdNodes[$shellRowId]
            $disProp = $entry.PSObject.Properties['disabled']
            $isDisabled = ($null -ne $disProp -and $disProp.Value -eq $true)
            if (-not $isDisabled) { $shellEnabled += $shellRowId }
        }
    }
    if ($missing.Count -eq 0 -and $shellEnabled.Count -gt 0) {
        $v8ok = $true
        $v8detail = "all 7 required rows present; enabled shell: $($shellEnabled -join ',')"
    }
    else {
        $bits = @()
        if ($missing.Count -gt 0) { $bits += ('missing ids: ' + ($missing -join ', ')) }
        if ($shellEnabled.Count -eq 0) { $bits += 'neither tool-pwsh nor tool-bash is enabled' }
        $v8detail = $bits -join '; '
    }
}
Check 'V8' 'required plugin rows present and a shell row enabled' $v8ok $v8detail

# -------------------------------------------------- V9: no duplicate-domain rows
$v9ok = $false
$v9detail = 'skipped: V1 failed'
if ($parseOk) {
    $forbidden = @('agent-team', 'tool-agent-team')
    $present = @($forbidden | Where-Object { $script:IdNodes.ContainsKey($_) })
    if ($present.Count -eq 0) {
        $v9ok = $true
        $v9detail = 'neither agent-team nor tool-agent-team is declared'
    }
    else {
        $v9detail = 'forbidden rows declared: ' + ($present -join ', ')
    }
}
Check 'V9' 'no agent-team / tool-agent-team rows (avoid duplicate domain service)' $v9ok $v9detail

# ------------------------------------------------ V10: persona references manual
$v10ok = $false
$v10detail = 'skipped: V1 failed'
if ($parseOk) {
    if (-not $script:IdNodes.ContainsKey('persona')) {
        $v10detail = 'persona row not found'
    }
    else {
        $persona = $script:IdNodes['persona']
        $cfgProp = $persona.PSObject.Properties['config']
        $prefix = ''
        if ($null -ne $cfgProp -and $null -ne $cfgProp.Value) {
            $prefProp = $cfgProp.Value.PSObject.Properties['prefix']
            if ($null -ne $prefProp -and $null -ne $prefProp.Value) { $prefix = [string]$prefProp.Value }
        }
        if ([string]::IsNullOrEmpty($prefix)) {
            $v10detail = 'persona.config.prefix is missing or empty'
        }
        elseif ($prefix -like '*agent-team-protocol*') {
            $v10ok = $true
            $v10detail = "persona.prefix ($($prefix.Length) chars) references agent-team-protocol"
        }
        else {
            $v10detail = "persona.prefix ($($prefix.Length) chars) never mentions agent-team-protocol"
        }
    }
}
Check 'V10' "persona.prefix references 'agent-team-protocol'" $v10ok $v10detail

# ------------------------------------------- V11: documentation consistency
$capRules = @(
    @{ key = 'maxMembers'; re = 'maxMembers\s*[:：=]\s*(\d+)'; allowed = @('8', '16') },
    @{ key = 'maxTasks'; re = 'maxTasks\s*[:：=]\s*(\d+)'; allowed = @('256') },
    @{ key = 'maxPendingMessagesPerMember'; re = 'maxPendingMessagesPerMember\s*[:：=]\s*(\d+)'; allowed = @('64') },
    @{ key = 'maxMessageBytes'; re = 'maxMessageBytes\s*[:：=]\s*(\d+)'; allowed = @('65536') },
    @{ key = 'disposalTimeoutMs'; re = 'disposalTimeoutMs\s*[:：=]\s*(\d+)'; allowed = @('5000') }
)
$badCapRe = '((上限|最多|至多)\s*(为|是)?\s*8(?![0-9]))|(maxMembers\s*[:：=]\s*8(?![0-9]))'
$qualifierRe = '(profile|实现默认|以运行时为准|16)'
# V11(c) F6 -- member-limit shorthand. WHAT: a capacity statement that binds a member
# limit directly to a bare 8 ('maxMembers 8' / 'maxMembers：8' / '成员上限 8'), while the
# same line never discloses where the 8 comes from. WHY: canon section 1 says 8 is only
# the local profile value, never the preset's mechanical cap, so "maxMembers 8" alone is
# misleading. The rule requires a capacity CONNECTOR between the cap name and the 8
# (separators / ： / = / ( / 上限 / 最多 / 为 / 默认 ...), NOT plain proximity: plain
# proximity false-positives on lines like "不占 maxMembers，见第 7、8 节", where the 8 is an
# unrelated section number (observed and fixed during development).
$memberCapRe = 'maxMembers[\s`*:：=＝≤<>（）()\[\]，、''"「」\-–—]{0,6}(上限|最多|至多|为|是|默认|配置|约)?[\s`*:：=＝≤<>（）()\[\]，、''"「」\-–—]{0,6}8(?![0-9])|成员[^\r\n]{0,6}?(上限|最多|至多|总数|数量)[^\r\n]{0,6}?8(?![0-9])'
$memberPairRe = '8\s*[/或]\s*16'
$memberQualifierRe = '(profile|实现默认|运行时)'
$v11files = @(
    @{ n = 'cordis.patch.yml'; p = $yamlPath },
    @{ n = 'skills/agent-team-protocol/SKILL.md'; p = $skillMd },
    @{ n = 'README.md'; p = $readmePath }
)
$v11problems = New-Object System.Collections.ArrayList
$v11scanned = 0
# Failure visibility: if this file ever loses its UTF-8 BOM, PowerShell 5.1 decodes
# the source as ANSI and the Chinese literals above turn into mojibake, which would
# make the regexes match nothing and silently PASS. Detect that and FAIL loudly.
$v11EncodingOk = ($badCapRe.IndexOf([char]0x4E0A) -ge 0) -and ($qualifierRe.IndexOf([char]0x5B9E) -ge 0) -and ($memberCapRe.IndexOf([char]0x6210) -ge 0) -and ($memberQualifierRe.IndexOf([char]0x5B9E) -ge 0)
if (-not $v11EncodingOk) {
    [void]$v11problems.Add('script source encoding broken: Chinese literals were not decoded; save validate-preset.ps1 as UTF-8 WITH BOM')
}
else {
foreach ($f in $v11files) {
    if (-not (Test-Path -LiteralPath $f.p -PathType Leaf)) {
        [void]$v11problems.Add("$($f.n): file missing")
        continue
    }
    $text = [System.IO.File]::ReadAllText($f.p, [System.Text.Encoding]::UTF8)
    $flines = $text -split "`r?`n"
    $v11scanned = $v11scanned + 1
    for ($i = 0; $i -lt $flines.Length; $i++) {
        $line = $flines[$i]
        $snippet = $line.Trim()
        if ($snippet.Length -gt 90) { $snippet = $snippet.Substring(0, 90) + '...' }
        $lineFlagged = $false
        foreach ($rule in $capRules) {
            $ms = [regex]::Matches($line, $rule.re)
            foreach ($m in $ms) {
                $val = $m.Groups[1].Value
                if ($rule.allowed -notcontains $val) {
                    [void]$v11problems.Add("$($f.n):$($i + 1) capacity claim $($rule.key)=$val is not one of canon section 1 [$($rule.allowed -join '/')]")
                    $lineFlagged = $true
                }
            }
        }
        # (b) 8 presented as the mechanical cap without any qualifier
        if (-not $lineFlagged -and [regex]::IsMatch($line, $badCapRe) -and -not [regex]::IsMatch($line, $qualifierRe)) {
            [void]$v11problems.Add("$($f.n):$($i + 1) unqualified '8' member-limit wording: $snippet (expected phrasing: 本机 profile 为 8 / 实现默认 16 / 以运行时为准)")
            $lineFlagged = $true
        }
        # (c) F6: member-limit shorthand with a bare 8 and no disclosure qualifier
        if (-not $lineFlagged -and [regex]::IsMatch($line, $memberCapRe) -and -not [regex]::IsMatch($line, $memberQualifierRe)) {
            $pairDisclosesBoth = [regex]::IsMatch($line, $memberPairRe)
            if (-not ($pairDisclosesBoth -and (-not $StrictMemberShorthand))) {
                $reason = 'member-limit shorthand with a bare 8 and no disclosure qualifier (need profile / 实现默认 / 运行时)'
                if ($pairDisclosesBoth) { $reason = $reason + ' [-StrictMemberShorthand: the 8/16 pair is not accepted as disclosure]' }
                [void]$v11problems.Add("$($f.n):$($i + 1) " + $reason + ': ' + $snippet)
            }
        }
    }
}
}
$v11ok = ($v11problems.Count -eq 0)
$v11detail = ''
if ($v11ok) {
    $v11detail = "$v11scanned files scanned; checked: capacity-key values match canon section 1, no bare 8 sold as the mechanical member cap, no member-limit shorthand without a disclosure qualifier"
}
else {
    $v11detail = ($v11problems -join ' ; ')
}
Check 'V11' 'docs consistent with canon section 1 (capacity numbers, no unqualified bare 8 member cap)' $v11ok $v11detail

# ------------------------------------------------- V12: no .work in delivery dir
$workPath = Join-Path $bundle '.work'
$workExists = Test-Path -LiteralPath $workPath -PathType Container
$v12ok = -not $workExists
$v12detail = 'no .work/ in the delivery directory'
if ($workExists) {
    $v12detail = "found $workPath; must be removed before acceptance (canon 5/T1 V12)"
}
Check 'V12' 'no .work/ left in the delivery directory' $v12ok $v12detail

# -------------------------------------------------------------------- summary
Write-Host ''
Write-Host "SUMMARY: PASS=$script:Passed FAIL=$script:Failed WARN=$script:Warned total=12"
if ($script:Failed -gt 0) {
    Write-Host ("FAILED: " + ($script:FailedIds -join ', '))
    exit 1
}
Write-Host 'ALL CHECKS PASSED'
exit 0
