#!/usr/bin/env node
/**
 * Static validation of the dsh-taskforce preset bundle: V1..V12.
 *
 * Cross-platform twin of scripts/validate-preset.ps1 (Windows / PowerShell).
 * This file is the implementation used on Linux and macOS; on Windows either
 * this script or the .ps1 works. Both must report the same verdicts and the
 * same exit code for the same bundle -- see README "跨平台" section.
 *
 * No preset is loaded and no session is started: every check is static.
 *
 *   V1  cordis.patch.yml parses as YAML via js-yaml (custom !!js scalar tag accepted)
 *   V2  top level has exactly one `insert`; exactly one row named
 *       '@deepseek-ai/dsh-agent-preset'
 *   V3  that row's config.id / config.name / config.description / config.order exist
 *       with correct types (string / string / string / number)
 *   V4  every `id` in the document is globally unique
 *   V5  every !!js expression compiles (vm.Script, not executed)
 *   V6  skills/agent-team-protocol/SKILL.md exists, frontmatter has name + description,
 *       and name equals the directory name
 *   V7  the DSH_HOME mirror is a LINK (junction on Windows, symlink on POSIX) back to
 *       this bundle -- all three required: (1) it is a link, not a real directory;
 *       (2) its target resolves to this bundle directory; (3) the mirrored
 *       skills/agent-team-protocol/SKILL.md exists. A real COPIED directory FAILs on
 *       purpose: a copy satisfies a plain existence test but silently drifts from the
 *       bundle. Remediation: scripts/link-skills.sh (POSIX) / link-skills.ps1 (Windows).
 *   V8  required plugin rows present (persona, agent-instructions, tool-fs,
 *       tool-fs-search, tool-jobs, skill-filesystem, tool-skill) and at least one of
 *       tool-pwsh / tool-bash is not disabled
 *   V9  no duplicate-domain rows: neither `agent-team` nor `tool-agent-team` present
 *   V10 persona.prefix mentions 'agent-team-protocol' (the manual is referenced)
 *   V11 documentation consistency across cordis.patch.yml / SKILL.md / README.md:
 *       (a) capacity key=value claims must use the canon section-1 numbers;
 *       (b) '8' must never be presented as the preset's mechanical cap without a
 *           qualifier (profile / 实现默认 / 以运行时为准 / 16);
 *       (c) member-limit shorthand (a bare 8 bound to maxMembers / 成员上限) FAILs
 *           unless the same line discloses where the 8 comes from; a "8/16" pair names
 *           both canonical values and passes unless --strict-member-shorthand is set.
 *   V12 the delivery directory contains no .work/ (checked after integration)
 *
 * The DSH home is resolved exactly like DSH's own @deepseek-ai/dsh-home-paths:
 *     --dsh-home  >  $DSH_HOME (blank counts as unset)  >  ~/.dsh
 * The resolved home and its source are printed, because V7 checks a path under it and a
 * wrong home would silently check the wrong directory.
 *
 * Usage:
 *   node scripts/validate-preset.mjs [--bundle DIR] [--dsh-home DIR]
 *                                    [--js-yaml DIR] [--warn-only V10,V11,V12]
 *                                    [--strict-member-shorthand]
 *
 * Exit codes: 0 = all checks PASS (or downgraded to WARN), 1 = at least one FAIL.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

// js-yaml is CommonJS: load it through a require() bound to this ESM module.
const require = createRequire(import.meta.url);

// ------------------------------------------------------------------ arguments
const argv = process.argv.slice(2);
let optBundle = '';
let optDshHome = '';
let optJsYaml = '';
let optWarnOnly = [];
let strictMemberShorthand = false;

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const need = () => {
    if (i + 1 >= argv.length) {
      console.error('ERROR: ' + a + ' requires a value');
      process.exit(2);
    }
    return argv[++i];
  };
  if (a === '--bundle' || a === '-b') { optBundle = need(); }
  else if (a === '--dsh-home') { optDshHome = need(); }
  else if (a === '--js-yaml') { optJsYaml = need(); }
  else if (a === '--warn-only') { optWarnOnly = need().split(',').map(s => s.trim()).filter(Boolean); }
  else if (a === '--strict-member-shorthand') { strictMemberShorthand = true; }
  else if (a === '--help' || a === '-h') {
    console.log('usage: node scripts/validate-preset.mjs [--bundle DIR] [--dsh-home DIR] [--js-yaml DIR] [--warn-only V10,V11,V12] [--strict-member-shorthand]');
    process.exit(0);
  }
  else { console.error('ERROR: unknown argument: ' + a); process.exit(2); }
}

// ------------------------------------------------------------------ locations
const scriptDir = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url)));
let bundle = optBundle ? path.resolve(optBundle) : path.resolve(scriptDir, '..');
bundle = bundle.replace(/[\\/]+$/, '');
const yamlPath = path.join(bundle, 'cordis.patch.yml');
const skillMd = path.join(bundle, 'skills', 'agent-team-protocol', 'SKILL.md');
const readmePath = path.join(bundle, 'README.md');
const isWindows = process.platform === 'win32';

// ---- DSH home resolution: mirrors @deepseek-ai/dsh-home-paths -----------------------
// Precedence: explicit override > $DSH_HOME > ~/.dsh. An empty or whitespace-only
// $DSH_HOME counts as unset (a blank override must never resolve the home to the cwd),
// and a leading `~`, `~/` or `~\` expands against the OS home. Read from the shipped DSH
// source, so this is DSH's own rule rather than a guess -- requiring an exported
// DSH_HOME would break every default Linux/macOS install, where DSH uses ~/.dsh.
function resolveDshHome(explicitPath) {
  const envHome = typeof process.env.DSH_HOME === 'string' && process.env.DSH_HOME.trim().length > 0
    ? process.env.DSH_HOME
    : '';
  let chosen = path.join(os.homedir(), '.dsh');
  let source = 'DSH default (~/.dsh)';
  if (envHome) { chosen = envHome; source = '$DSH_HOME'; }
  if (explicitPath) { chosen = explicitPath; source = '--dsh-home'; }
  if (chosen === '~') { chosen = os.homedir(); }
  else if (chosen.startsWith('~/') || chosen.startsWith('~\\')) { chosen = path.join(os.homedir(), chosen.slice(2)); }
  // DSH itself would resolve a relative home against the cwd; a validator must not silently
  // check some other directory, so report it and let V7 fail loudly (same as the .ps1/.sh).
  return { home: path.resolve(chosen), source: source, absolute: path.isAbsolute(chosen) };
}

// ------------------------------------------------------- counters and reporting
let passed = 0;
let warned = 0;
let failed = 0;
const failedIds = [];
const warnedIds = [];

function report(id, desc, status, detail) {
  let line = status + ' ' + id + ' ' + desc;
  if (detail) { line += ' -- ' + detail; }
  console.log(line);
}

function check(id, desc, ok, detail) {
  if (ok) {
    passed++;
    report(id, desc, 'PASS', detail);
    return;
  }
  if (optWarnOnly.indexOf(id) >= 0) {
    warned++;
    warnedIds.push(id);
    report(id, desc, 'WARN', detail);
    return;
  }
  failed++;
  failedIds.push(id);
  report(id, desc, 'FAIL', detail);
}

const dshHomeResolved = resolveDshHome(optDshHome);
console.log('bundle: ' + bundle);
console.log('dsh home: ' + dshHomeResolved.home + ' (' + dshHomeResolved.source + ')');
console.log('');

// ----------------------------------------------------- js-yaml discovery (V1)
function findJsYaml() {
  const candidates = [];
  if (optJsYaml) { candidates.push(optJsYaml); }
  if (process.env.DSH_JS_YAML) { candidates.push(process.env.DSH_JS_YAML); }
  // Tool discovery probes the resolved DSH home first, then the platform default (js-yaml
  // and node ship with the DSH runtime). V7 resolves the mirror path through the same
  // function, so discovery and the check never disagree about where the home is.
  const homeCandidates = [];
  for (const h of [resolveDshHome(optDshHome).home, path.join(os.homedir(), '.dsh')]) {
    if (h && homeCandidates.indexOf(h) < 0) { homeCandidates.push(h); }
  }
  for (const h of homeCandidates) {
    candidates.push(path.join(h, 'profiles', 'node_modules', 'js-yaml'));
    const rtdir = path.join(h, 'dsh-runtimes');
    if (fs.existsSync(rtdir)) {
      for (const rt of safeReaddir(rtdir)) {
        candidates.push(path.join(rtdir, rt, 'dependencies', 'node_modules', 'js-yaml'));
      }
    }
  }
  for (const c of candidates) {
    try { return require.resolve(c); } catch (e) { /* keep looking */ }
  }
  try { return require.resolve('js-yaml'); } catch (e) { /* not installed */ }
  return '';
}

function safeReaddir(dir) {
  try { return fs.readdirSync(dir); } catch (e) { return []; }
}

// ---------------------------------------------------- V1: YAML parses (js-yaml)
let parseOk = false;
let parseError = '';
let doc = null;
let jsList = [];

const yamlModulePath = findJsYaml();

if (!fs.existsSync(yamlPath)) {
  parseError = 'file not found: ' + yamlPath;
} else if (!yamlModulePath) {
  parseError = 'js-yaml not found: pass --js-yaml DIR, set DSH_JS_YAML, or install js-yaml (it ships with the DSH runtime at <DSH_HOME>/profiles/node_modules/js-yaml)';
} else {
  try {
    const yaml = require(yamlModulePath);
    const JsType = new yaml.Type('tag:yaml.org,2002:js', {
      kind: 'scalar',
      construct: d => ({ __jsExpr: String(d) }),
    });
    const schema = yaml.DEFAULT_SCHEMA.extend([JsType]);
    const txt = fs.readFileSync(yamlPath, 'utf8');
    doc = yaml.load(txt, { schema: schema });
    parseOk = true;
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
    walk(doc);
    jsList = seen.map(e => {
      try { new vm.Script('(' + e + ')'); return { expr: e, ok: true, error: '' }; }
      catch (err) { return { expr: e, ok: false, error: String((err && err.message) || err) }; }
    });
  } catch (e) {
    parseOk = false;
    parseError = String((e && e.message) || e);
    doc = null;
  }
}

if (parseOk) {
  check('V1', 'cordis.patch.yml parses as YAML (js-yaml)', true,
    'js-yaml=' + yamlModulePath + '; !!js tags accepted as scalars');
} else {
  check('V1', 'cordis.patch.yml parses as YAML (js-yaml)', false, parseError);
}

// ---------------------------------------------------- collect plugin ids (once)
const idNodes = new Map();
const allIds = [];

function walkIds(node) {
  if (node === null || typeof node !== 'object') { return; }
  if (Array.isArray(node)) { node.forEach(walkIds); return; }
  if (Object.prototype.hasOwnProperty.call(node, 'id') && node.id !== null && node.id !== undefined) {
    const idValue = String(node.id);
    allIds.push(idValue);
    if (!idNodes.has(idValue)) { idNodes.set(idValue, node); }
  }
  for (const k of Object.keys(node)) { walkIds(node[k]); }
}

if (parseOk) { walkIds(doc); }

// ------------------------------------------- V2: one insert, one preset row
let insert = null;
let presetRow = null;
let v2ok = false;
let v2detail = 'skipped: V1 failed';
if (parseOk) {
  const top = Array.isArray(doc) ? doc : [doc];
  const insertItems = top.filter(e => e && typeof e === 'object' && Object.prototype.hasOwnProperty.call(e, 'insert'));
  if (top.length !== 1) {
    v2detail = 'top-level array has ' + top.length + ' entries (expected 1)';
  } else if (insertItems.length !== 1) {
    v2detail = "found " + insertItems.length + " 'insert' keys at top level (expected 1)";
  } else {
    insert = Array.isArray(insertItems[0].insert) ? insertItems[0].insert : [insertItems[0].insert];
    const rows = insert.filter(r => r && typeof r === 'object' && r.name === '@deepseek-ai/dsh-agent-preset');
    if (rows.length !== 1) {
      v2detail = "found " + rows.length + " rows named '@deepseek-ai/dsh-agent-preset' (expected 1)";
    } else {
      presetRow = rows[0];
      v2ok = true;
      v2detail = '1 insert, ' + insert.length + ' rows, 1 preset row';
    }
  }
}
check('V2', "top level: exactly one insert with one '@deepseek-ai/dsh-agent-preset' row", v2ok, v2detail);

// ------------------------------------------------------- V3: preset config keys
let v3ok = false;
let v3detail = 'skipped: V1/V2 failed';
if (presetRow) {
  const cfg = presetRow.config;
  if (!cfg || typeof cfg !== 'object') {
    v3detail = 'config object missing';
  } else {
    const bad = [];
    if (typeof cfg.id !== 'string' || !cfg.id) { bad.push('config.id'); }
    if (typeof cfg.name !== 'string' || !cfg.name) { bad.push('config.name'); }
    if (typeof cfg.description !== 'string' || !cfg.description) { bad.push('config.description'); }
    if (typeof cfg.order !== 'number') { bad.push('config.order'); }
    if (bad.length === 0) {
      v3ok = true;
      v3detail = 'id=' + cfg.id + ' order=' + cfg.order + ' name/description present';
    } else {
      v3detail = 'missing/mistyped: ' + bad.join(', ');
    }
  }
}
check('V3', 'preset config.id/name/description/order present with correct types', v3ok, v3detail);

// ------------------------------------------------------- V4: globally unique ids
let v4ok = false;
let v4detail = 'skipped: V1 failed';
if (parseOk) {
  const counts = new Map();
  allIds.forEach(id => counts.set(id, (counts.get(id) || 0) + 1));
  const dups = [...counts.entries()].filter(([, n]) => n > 1).map(([id]) => id);
  if (dups.length === 0) {
    v4ok = true;
    v4detail = allIds.length + ' ids, all unique';
  } else {
    v4detail = 'duplicate ids: ' + dups.join(', ');
  }
}
check('V4', 'every id in the document is globally unique', v4ok, v4detail);

// --------------------------------------------------- V5: !!js expressions compile
let v5ok = false;
let v5detail = 'skipped: V1 failed';
if (parseOk) {
  const badJs = jsList.filter(j => j.ok !== true);
  if (badJs.length === 0) {
    v5ok = true;
    v5detail = jsList.length + ' !!js expressions compile (vm.Script, not executed)';
  } else {
    v5detail = badJs.map(b => '[' + b.expr + '] ' + b.error).join(' | ');
  }
}
check('V5', 'every !!js expression is syntactically valid JS', v5ok, v5detail);

// --------------------------------------------- V6: SKILL.md exists + frontmatter
let v6ok = false;
let v6detail = '';
const skillDirName = 'agent-team-protocol';
if (!fs.existsSync(skillMd)) {
  v6detail = 'file not found: ' + skillMd;
} else {
  const lines = fs.readFileSync(skillMd, 'utf8').split(/\r?\n/);
  let fmName = '';
  let fmDesc = '';
  let closed = false;
  if (lines.length < 3 || lines[0].trim() !== '---') {
    v6detail = 'frontmatter does not start at line 1 with ---';
  } else {
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].trim() === '---') { closed = true; break; }
      if (!fmName) {
        const m = /^name:\s*(.+)$/.exec(lines[i]);
        if (m) { fmName = m[1].trim().replace(/^["']|["']$/g, ''); }
      }
      if (!fmDesc) {
        const m2 = /^description:\s*(.+)$/.exec(lines[i]);
        if (m2) { fmDesc = m2[1].trim(); }
      }
    }
    if (!closed) { v6detail = 'frontmatter is not closed with ---'; }
    else if (!fmName) { v6detail = 'frontmatter has no name'; }
    else if (!fmDesc) { v6detail = 'frontmatter has no description'; }
    else if (fmName !== skillDirName) { v6detail = "frontmatter name '" + fmName + "' != directory name '" + skillDirName + "'"; }
    else { v6ok = true; v6detail = 'name=' + fmName + ', description=' + fmDesc.length + ' chars'; }
  }
}
check('V6', 'SKILL.md exists with frontmatter name/description and name == dir name', v6ok, v6detail);

// ------------------------------------------------------- V7: mirror resolves
// All three are required: it is a LINK (junction on Windows, symlink on POSIX) rather
// than a real directory; the link target resolves to this bundle; the mirrored
// SKILL.md exists. A real copied directory also satisfies a plain existence test, but
// it is a second source of truth that silently drifts -- exactly what this blocks.
let v7ok = false;
let v7detail = '';
const dshHome = dshHomeResolved.home;
// Only the fallback to ~/.dsh carries residual risk (a DSH launched with an explicit
// configured home uses that instead), so state it in the detail instead of hiding it.
const dshHomeNote = dshHomeResolved.source === 'DSH default (~/.dsh)'
  ? ' [DSH_HOME unset -> resolved to the DSH default ~/.dsh; pass --dsh-home if this DSH instance uses another home]'
  : '';

if (!dshHomeResolved.absolute) {
  v7detail = 'resolved DSH home is not an absolute path: ' + dshHome + ' (from ' + dshHomeResolved.source + '; pass an absolute --dsh-home)';
} else {
  const mirrorRoot = path.join(dshHome.replace(/[\\/]+$/, ''), 'agent-preset-bundles', 'dsh-taskforce');
  const mirrorSkill = path.join(mirrorRoot, 'skills', 'agent-team-protocol', 'SKILL.md');
  const skillExists = fs.existsSync(mirrorSkill);
  let lstat = null;
  let isLink = false;
  let linkKind = '';
  let targetRaw = '';
  let realTarget = '';
  try {
    lstat = fs.lstatSync(mirrorRoot);
    if (lstat.isSymbolicLink()) {
      isLink = true;
      linkKind = isWindows ? 'symlink-or-junction' : 'symlink';
      try { targetRaw = fs.readlinkSync(mirrorRoot); } catch (e) { targetRaw = ''; }
    } else if (isWindows) {
      // A directory junction is not always reported as a symlink by lstat; if the
      // realpath differs from the literal path it is still a reparse point we accept.
      try {
        const rp = fs.realpathSync(mirrorRoot);
        if (path.resolve(rp).toLowerCase() !== path.resolve(mirrorRoot).toLowerCase()) {
          isLink = true;
          linkKind = 'junction';
          targetRaw = rp;
        }
      } catch (e) { /* not a link */ }
    }
  } catch (e) {
    lstat = null;
  }
  if (!lstat) {
    v7ok = false;
    v7detail = 'checked: mirror must be a link back to this bundle; path=' + mirrorRoot +
      ' does not exist -> run scripts/link-skills.sh (POSIX) or scripts/link-skills.ps1 (Windows)';
  } else {
    try { realTarget = fs.realpathSync(mirrorRoot); } catch (e) { realTarget = targetRaw; }
    const targetMatches = realTarget !== '' &&
      path.resolve(realTarget).toLowerCase() === path.resolve(bundle).toLowerCase();
    v7ok = isLink && targetMatches && skillExists;
    v7detail = 'checked: mirror must be a ' + (isWindows ? 'junction' : 'symlink') +
      ' back to this bundle (a real copy passes a plain existence test but silently drifts); ' +
      'path=' + mirrorSkill + ' exists=' + skillExists + ' link=' + isLink +
      (linkKind ? ' linkKind=' + linkKind : '') + ' target=' + (targetRaw || realTarget) +
      ' targetResolvesToBundle=' + targetMatches + ' expected=' + bundle;
    if (!skillExists) {
      v7detail += '; mirrored SKILL.md not found -> run scripts/link-skills.sh (POSIX) or scripts/link-skills.ps1 (Windows)';
    } else if (!isLink) {
      v7detail += '; mirror is NOT a link (it is a real directory/copy) -> back it up, remove it, then run the link script (it refuses to overwrite a real dir)';
    } else if (!targetMatches) {
      v7detail += "; link target '" + (targetRaw || realTarget) + "' does not resolve to this bundle -> run the link script (it reports a wrong target instead of overwriting)";
    }
  }
}
if (dshHomeNote && v7detail.indexOf('[DSH_HOME unset') < 0) { v7detail = v7detail + dshHomeNote; }
check('V7', 'mirror is a link pointing back to this bundle (skill path resolves)', v7ok, v7detail);

// --------------------------------------------------- V8: required plugin rows
let v8ok = false;
let v8detail = 'skipped: V1 failed';
if (parseOk) {
  const required = ['persona', 'agent-instructions', 'tool-fs', 'tool-fs-search', 'tool-jobs', 'skill-filesystem', 'tool-skill'];
  const missing = required.filter(id => !idNodes.has(id));
  const shellEnabled = [];
  for (const shellRowId of ['tool-pwsh', 'tool-bash']) {
    if (idNodes.has(shellRowId)) {
      const entry = idNodes.get(shellRowId);
      if (entry.disabled !== true) { shellEnabled.push(shellRowId); }
    }
  }
  if (missing.length === 0 && shellEnabled.length > 0) {
    v8ok = true;
    v8detail = 'all 7 required rows present; enabled shell: ' + shellEnabled.join(',');
  } else {
    const bits = [];
    if (missing.length > 0) { bits.push('missing ids: ' + missing.join(', ')); }
    if (shellEnabled.length === 0) { bits.push('neither tool-pwsh nor tool-bash is enabled'); }
    v8detail = bits.join('; ');
  }
}
check('V8', 'required plugin rows present and a shell row enabled', v8ok, v8detail);

// -------------------------------------------------- V9: no duplicate-domain rows
let v9ok = false;
let v9detail = 'skipped: V1 failed';
if (parseOk) {
  const present = ['agent-team', 'tool-agent-team'].filter(id => idNodes.has(id));
  if (present.length === 0) {
    v9ok = true;
    v9detail = 'neither agent-team nor tool-agent-team is declared';
  } else {
    v9detail = 'forbidden rows declared: ' + present.join(', ');
  }
}
check('V9', 'no agent-team / tool-agent-team rows (avoid duplicate domain service)', v9ok, v9detail);

// ------------------------------------------------ V10: persona references manual
let v10ok = false;
let v10detail = 'skipped: V1 failed';
if (parseOk) {
  if (!idNodes.has('persona')) {
    v10detail = 'persona row not found';
  } else {
    const personaCfg = idNodes.get('persona').config;
    const prefix = (personaCfg && typeof personaCfg.prefix === 'string') ? personaCfg.prefix : '';
    if (!prefix) {
      v10detail = 'persona.config.prefix is missing or empty';
    } else if (prefix.indexOf('agent-team-protocol') >= 0) {
      v10ok = true;
      v10detail = 'persona.prefix (' + prefix.length + ' chars) references agent-team-protocol';
    } else {
      v10detail = 'persona.prefix (' + prefix.length + ' chars) never mentions agent-team-protocol';
    }
  }
}
check('V10', "persona.prefix references 'agent-team-protocol'", v10ok, v10detail);

// ------------------------------------------- V11: documentation consistency
const capRules = [
  { key: 'maxMembers', re: 'maxMembers\\s*[:：=]\\s*(\\d+)', allowed: ['8', '16'] },
  { key: 'maxTasks', re: 'maxTasks\\s*[:：=]\\s*(\\d+)', allowed: ['256'] },
  { key: 'maxPendingMessagesPerMember', re: 'maxPendingMessagesPerMember\\s*[:：=]\\s*(\\d+)', allowed: ['64'] },
  { key: 'maxMessageBytes', re: 'maxMessageBytes\\s*[:：=]\\s*(\\d+)', allowed: ['65536'] },
  { key: 'disposalTimeoutMs', re: 'disposalTimeoutMs\\s*[:：=]\\s*(\\d+)', allowed: ['5000'] },
];
const badCapRe = '((上限|最多|至多)\\s*(为|是)?\\s*8(?![0-9]))|(maxMembers\\s*[:：=]\\s*8(?![0-9]))';
const qualifierRe = '(profile|实现默认|以运行时为准|16)';
// V11(c) member-limit shorthand: a capacity statement that binds a member limit
// directly to a bare 8 ('maxMembers 8' / '成员上限 8') while the same line never
// discloses where the 8 comes from. Only the LOCAL profile value is 8, never the
// preset's mechanical cap, so the bare form is misleading. The rule needs a capacity
// CONNECTOR between the cap name and the 8 (not plain proximity): plain proximity
// false-positives on lines like "不占 maxMembers，见第 7、8 节", where 8 is a section number.
const memberCapRe = "maxMembers[\\s`*:：=＝≤<>（）()\\[\\]，、'\"「」\\-–—]{0,6}(上限|最多|至多|为|是|默认|配置|约)?[\\s`*:：=＝≤<>（）()\\[\\]，、'\"「」\\-–—]{0,6}8(?![0-9])|成员[^\\r\\n]{0,6}?(上限|最多|至多|总数|数量)[^\\r\\n]{0,6}?8(?![0-9])";
const memberPairRe = '8\\s*[/或]\\s*16';
const memberQualifierRe = '(profile|实现默认|运行时)';
const v11files = [
  { n: 'cordis.patch.yml', p: yamlPath },
  { n: 'skills/agent-team-protocol/SKILL.md', p: skillMd },
  { n: 'README.md', p: readmePath },
];
const v11problems = [];
let v11scanned = 0;
// Failure visibility: if this source file is ever re-saved in a non-UTF-8 encoding the
// Chinese literals above turn into mojibake, the regexes match nothing, and V11 would
// silently PASS. Detect that and FAIL loudly instead.
const v11EncodingOk = badCapRe.indexOf('\u4E0A') >= 0 && qualifierRe.indexOf('\u5B9E') >= 0 &&
  memberCapRe.indexOf('\u6210') >= 0 && memberQualifierRe.indexOf('\u5B9E') >= 0;
if (!v11EncodingOk) {
  v11problems.push('script source encoding broken: Chinese literals were not decoded; save validate-preset.mjs as UTF-8');
} else {
  for (const f of v11files) {
    if (!fs.existsSync(f.p)) {
      v11problems.push(f.n + ': file missing');
      continue;
    }
    const text = fs.readFileSync(f.p, 'utf8');
    const flines = text.split(/\r?\n/);
    v11scanned++;
    for (let i = 0; i < flines.length; i++) {
      const line = flines[i];
      let snippet = line.trim();
      if (snippet.length > 90) { snippet = snippet.substring(0, 90) + '...'; }
      let lineFlagged = false;
      for (const rule of capRules) {
        const re = new RegExp(rule.re, 'g');
        let m;
        while ((m = re.exec(line)) !== null) {
          const val = m[1];
          if (rule.allowed.indexOf(val) < 0) {
            v11problems.push(f.n + ':' + (i + 1) + ' capacity claim ' + rule.key + '=' + val +
              ' is not one of canon section 1 [' + rule.allowed.join('/') + ']');
            lineFlagged = true;
          }
        }
      }
      if (!lineFlagged && new RegExp(badCapRe).test(line) && !new RegExp(qualifierRe).test(line)) {
        v11problems.push(f.n + ':' + (i + 1) + " unqualified '8' member-limit wording: " + snippet +
          ' (expected phrasing: 本机 profile 为 8 / 实现默认 16 / 以运行时为准)');
        lineFlagged = true;
      }
      if (!lineFlagged && new RegExp(memberCapRe).test(line) && !new RegExp(memberQualifierRe).test(line)) {
        const pairDisclosesBoth = new RegExp(memberPairRe).test(line);
        if (!(pairDisclosesBoth && !strictMemberShorthand)) {
          let reason = 'member-limit shorthand with a bare 8 and no disclosure qualifier (need profile / 实现默认 / 运行时)';
          if (pairDisclosesBoth) { reason += ' [--strict-member-shorthand: the 8/16 pair is not accepted as disclosure]'; }
          v11problems.push(f.n + ':' + (i + 1) + ' ' + reason + ': ' + snippet);
        }
      }
    }
  }
}
const v11ok = v11problems.length === 0;
const v11detail = v11ok
  ? v11scanned + ' files scanned; checked: capacity-key values match canon section 1, no bare 8 sold as the mechanical member cap, no member-limit shorthand without a disclosure qualifier'
  : v11problems.join(' ; ');
check('V11', 'docs consistent with canon section 1 (capacity numbers, no unqualified bare 8 member cap)', v11ok, v11detail);

// ------------------------------------------------- V12: no .work in delivery dir
const workPath = path.join(bundle, '.work');
const workExists = fs.existsSync(workPath) && fs.statSync(workPath).isDirectory();
const v12ok = !workExists;
let v12detail = 'no .work/ in the delivery directory';
if (workExists) { v12detail = 'found ' + workPath + '; must be removed before acceptance'; }
check('V12', 'no .work/ left in the delivery directory', v12ok, v12detail);

// -------------------------------------------------------------------- summary
console.log('');
console.log('SUMMARY: PASS=' + passed + ' FAIL=' + failed + ' WARN=' + warned + ' total=12');
if (failed > 0) {
  console.log('FAILED: ' + failedIds.join(', '));
  process.exit(1);
}
console.log('ALL CHECKS PASSED');
process.exit(0);
