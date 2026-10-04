#!/usr/bin/env node
// Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
// Licensed GPL-3.0-only with an additional attribution term under
// GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
//
// lib/registry.cjs — registry metadata helpers for the JavaScript cleaners
// (npm, pnpm, bun). Plain Node.js >= 18, CommonJS (.cjs: it stays CommonJS
// even under a package.json that says "type": "module"), no dependencies.
// Every subcommand is a pure function of its input — the cleaners run the
// (read-only) package-manager commands and pipe their output in — and prints
// TAB-separated lines.
//
//   pick NAME CURRENT CUTOFF MODE    stdin: npm view NAME time versions dist-tags --json
//       "pick<TAB>V1[<TAB>V2…]"  mature candidates, best first (at most 4:
//                                 the best plus three step-downs for verify)
//       "held<TAB>V"             newer releases exist, none old enough (V is
//                                 the newest of them)
//       "none"                   nothing newer to move to
//       "foreign"                CURRENT is not a release of NAME on this
//                                 registry (installed from git, a tarball, a
//                                 fork or another registry)
//       "missing"                the registry does not know NAME (E404)
//     The rules: a candidate is newer than CURRENT (never a downgrade), not
//     past the "latest" dist-tag (when that tag is a stable release), and
//     published at or before CUTOFF (an ISO date; releases without a publish
//     time count as too fresh). A prerelease is only a candidate when CURRENT
//     is a prerelease of the same MAJOR.MINOR.PATCH (2.0.0-beta.1 may move to
//     2.0.0-beta.2; to 2.0.0 or 2.0.1 in any case). MODE is "latest" (any
//     newer release), "caret" (what npm's ^CURRENT allows: the same major;
//     for 0.x the same minor; for 0.0.x nothing newer), "tilde" (the same
//     major.minor), or a saved ^/~ range itself — its own upper bound then
//     applies (^0 allows any 0.x, ~1 any 1.x). Candidates rank by semver
//     precedence.
//
//   verify V1,V2… [--current CUR] [--no-engines] [--npm NPM_BIN]
//          [--semver-dir DIR] [--node VERSION]
//       stdin: npm view "NAME@V1 || V2 || … || CUR" name version deprecated engines --json
//       Prints "skip<TAB>V<TAB>REASON" for each candidate passed over, then
//       "ok<TAB>V[<TAB>REMARK]" (the first acceptable one) or "unsuitable".
//       A candidate is passed over when it is deprecated, or when its
//       engines.node range excludes the running Node.js (or VERSION). When
//       every candidate is deprecated and so is CUR — the whole line is —
//       the newest engine-compatible one is accepted anyway (REMARK says so).
//       Ranges are checked with npm's own bundled semver (found from NPM_BIN,
//       or next to node; only in DIR with --semver-dir); when it cannot be
//       loaded, engines are not checked — never a failure. Candidates the
//       metadata does not mention, and unreadable input, are accepted
//       unchecked.
//
//   cutoff [--days N] [--minutes N] [--seconds N] [--before DATE] … [--ceil-days]
//       The earliest of "now minus each age" and each DATE, as an ISO
//       timestamp ("none" when nothing applies; 0, "null" and unparsable
//       values are ignored). DATE may be any Date.parse()-able text (npm
//       prints its `before` setting as Date#toString()). With --ceil-days:
//       how many whole days back that is, rounded up (0 for none).
//
//   npm-outdated [ROOT]
//       stdin: {"outdated": <npm outdated -g --json>, "ls": <npm ls -g --long --json>}
//       (ROOT = npm root -g, used for an extra on-disk check when it exists)
//       "update<TAB>NAME<TAB>CURRENT<TAB>LATEST", or
//       "skip<TAB>NAME<TAB>CURRENT<TAB>REASON" with REASON one of
//         self    npm / corepack — they belong to the Node.js install (D4)
//         linked  installed from a local directory or link (npm link,
//                 npm i -g ./dir: "resolved" is file:…, or a symlink)
//         alias   installed under another name (npm i -g x@npm:y)
//         source  "resolved" names git or another non-registry source
//         unknown not in npm ls, so its source cannot be checked
//         ahead   CURRENT is newer than "latest" (npm update -g would downgrade)
//         version CURRENT is not a semver version
//       npm records no source at all for globals installed from a tarball
//       or a git URL (verified with npm 11/12); `pick` reports those as
//       "foreign" when their version is not a release on the registry.
//
//   pnpm-globals [--major N]         stdin: pnpm ls -g --depth=0 --json
//       "member<TAB>GROUP<TAB>NAME<TAB>VERSION<TAB>MODE<TAB>SPEC" per global
//       package, MODE from the range saved in pnpm's global manifest: caret,
//       tilde, pinned (an exact version), latest (*, latest) or range — any
//       other range, and ^/~ ranges a re-add would narrow (~1, ^0, ^0.0).
//       GROUP is the pnpm >= 11 install group ("pnpm add -g a,b" installs a
//       and b as one group, and re-adding one member alone uninstalls the
//       others): the directory above the package's node_modules/, wherever
//       globalDir puts it. pnpm 10 (N < 11; without --major, a global root
//       not named vN) has one global project: every package is its own
//       group. Or "skip<TAB>NAME<TAB>REASON": self (pnpm itself), alias,
//       local (a link:/file:/git spec), or group:OTHER (shares an install
//       group with a package that cannot be re-added).
//
//   pnpm-legacy DIR                  DIR = pnpm >= 11's global root (vN)
//       The packages still in pnpm 10's global project beside it (DIR/../5,
//       which only `pnpm update -g` migrates), one name per line.
//
//   pnpm-outdated                    stdin: pnpm outdated -g --format json
//       The names whose "latest" release is not the installed one (pnpm's
//       "wanted" for globals is the locked version, not the newest release
//       the range allows, so it cannot tell).
//
//   bun-globals DIR                  DIR = Bun's global directory
//       "pkg<TAB>NAME<TAB>VERSION<TAB>MODE<TAB>SPEC" (MODE from the saved
//       range: ^ is caret, ~ is tilde) or "skip<TAB>NAME<TAB>REASON"
//       (pinned:SPEC; range:SPEC — *, latest and ranges an update would
//       narrow or turn into an exact pin; local; linked; alias; missing).
//       A package Bun's isolated linker links in from node_modules/.bun/ is
//       a registry install, not a link.
//
//   bun-outdated                     stdin: bun outdated -g (its table)
//       The names whose "Latest" is not "Current" (nothing, when Bun printed
//       only its banner: all up to date). Like pnpm's "wanted", Bun's
//       "Update" column follows the lockfile, so it cannot tell.
//
//   bunfig-age FILE…
//       The largest install.minimumReleaseAge (seconds) set in these
//       bunfig.toml files ([install] tables, dotted keys or inline tables;
//       integers, floats, _ separators, hex/octal/binary), or 0.
//
//   bun-release CURRENT CUTOFF       stdin: the GitHub release `bun upgrade`
//       installs (api.github.com/repos/Jarred-Sumner/bun-releases-for-updater
//       /releases/latest). "upgrade<TAB>V" (newer and published at or before
//       CUTOFF), "held<TAB>V" (newer, too fresh), "none" or "canary" (CURRENT
//       is a canary build: `bun upgrade` would install the newest canary).
//
// Exit status: 0; 3 when the input is unreadable or an npm error object.
'use strict'

const fs = require('fs')
const path = require('path')

const TAB = '\t'
const MAX_CANDIDATES = 4

function out (fields) {
  process.stdout.write(fields.join(TAB) + '\n')
}

function fail () {
  process.exit(3)
}

function readStdin () {
  try {
    return fs.readFileSync(0, 'utf8').trim()
  } catch (e) {
    return ''
  }
}

function readJson (file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (e) {
    return null
  }
}

function readText (file) {
  try {
    return fs.readFileSync(file, 'utf8')
  } catch (e) {
    return ''
  }
}

// ---------- semver (precedence only; ranges come from npm's own semver) ----------
const SEMVER = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/

function parse (v) {
  const m = SEMVER.exec(String(v))
  if (!m) return null
  return { raw: String(v), major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ? m[4].split('.') : [] }
}

function cmpIdent (a, b) {
  const an = /^\d+$/.test(a)
  const bn = /^\d+$/.test(b)
  if (an && bn) return Number(a) - Number(b)
  if (an) return -1
  if (bn) return 1
  return a < b ? -1 : a > b ? 1 : 0
}

// cmp — semver 2.0.0 precedence (build metadata ignored).
function cmp (a, b) {
  const d = (a.major - b.major) || (a.minor - b.minor) || (a.patch - b.patch)
  if (d) return d
  if (!a.pre.length || !b.pre.length) return b.pre.length - a.pre.length
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    if (i >= a.pre.length) return -1
    if (i >= b.pre.length) return 1
    const c = cmpIdent(a.pre[i], b.pre[i])
    if (c) return c
  }
  return 0
}

function sameRelease (a, b) {
  return a.major === b.major && a.minor === b.minor && a.patch === b.patch
}

function withinMode (cur, v, mode) {
  if (mode === 'latest') return true
  if (mode === 'tilde') return v.major === cur.major && v.minor === cur.minor
  if (mode === 'caret') {
    // npm's ^CURRENT
    if (cur.major > 0) return v.major === cur.major
    if (cur.minor > 0) return v.major === 0 && v.minor === cur.minor
    return v.major === 0 && v.minor === 0 && v.patch === cur.patch
  }
  const r = rangeOf(mode) // a saved ^/~ range: its own bounds
  return r !== null && cmp(v, r.lower) >= 0 && cmp(v, r.upper) < 0
}

// rangeOf SPEC — the bounds npm gives ^X[.Y[.Z]] and ~X[.Y[.Z]] (a missing
// part is 0 in the lower bound, and widens the upper one: ^0 is <1.0.0,
// ^0.0 <0.1.0, ~1 <2.0.0), or null for anything else.
function rangeOf (spec) {
  const m = /^(\^|~>?)\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$/.exec(String(spec).trim())
  if (!m) return null
  const [maj, min, pat] = [+m[2], m[3] === undefined ? null : +m[3], m[4] === undefined ? null : +m[4]]
  const lower = { major: maj, minor: min || 0, patch: pat || 0, pre: m[5] ? m[5].split('.') : [] }
  const v = (a, b, c) => ({ major: a, minor: b, patch: c, pre: ['0'] }) // below any a.b.c release
  let upper
  if (m[1] !== '^') {
    upper = min === null ? v(maj + 1, 0, 0) : v(maj, min + 1, 0)
  } else if (maj > 0 || min === null) {
    upper = v(maj + 1, 0, 0)
  } else if (min > 0 || pat === null) {
    upper = v(0, min + 1, 0)
  } else {
    upper = v(0, 0, pat + 1)
  }
  return { op: m[1] === '^' ? '^' : '~', lower, upper, parts: min === null ? 1 : pat === null ? 2 : 3 }
}

// keepable SPEC — rewriting a ^/~ range onto a newer version (an update
// saves "^1.2.4" for "^1.2.3") keeps its upper bound. Not so for ~1 (then
// <1.3.0, not <2.0.0), ^0 or ^0.0: those would narrow.
function keepable (spec) {
  const r = rangeOf(spec)
  if (!r) return false
  if (r.parts === 3) return true
  if (r.op === '~') return r.parts === 2 // ~1.2 keeps <1.3.0; ~1 would narrow
  return r.lower.major > 0 || (r.parts === 2 && r.lower.minor > 0) // ^1, ^0.3 keep; ^0, ^0.0 narrow
}

// unwrap — npm 12 wraps `npm view … --json` output in arrays.
function unwrap (d) {
  while (Array.isArray(d) && d.length === 1) d = d[0]
  return d
}

// ---------- pick ----------
function cmdPick (args) {
  const [, current, cutoff, mode = 'latest'] = args
  if (!['latest', 'caret', 'tilde'].includes(mode) && rangeOf(mode) === null) fail()
  const cut = Date.parse(cutoff)
  if (Number.isNaN(cut)) fail()
  const text = readStdin()
  if (!text) fail()
  let d
  try {
    d = JSON.parse(text)
  } catch (e) {
    fail()
  }
  if (Array.isArray(d) && d.length && d[0] && typeof d[0] === 'object' && !Array.isArray(d[0])) d = d[0]
  if (!d || typeof d !== 'object' || Array.isArray(d)) fail()
  if (d.error) {
    if (d.error && d.error.code === 'E404') return out(['missing'])
    fail()
  }
  const time = d.time && typeof d.time === 'object' ? d.time : {}
  let versions = d.versions
  if (typeof versions === 'string') versions = [versions]
  if (!Array.isArray(versions)) versions = []
  if (versions.length && Array.isArray(versions[0])) versions = versions[0]
  let tags = d['dist-tags']
  if (Array.isArray(tags)) tags = tags[0]
  const cur = parse(current)
  if (!cur) return out(['none'])
  if (versions.length && !versions.some((v) => parse(v) && cmp(parse(v), cur) === 0)) return out(['foreign'])
  const latest = tags && typeof tags.latest === 'string' ? parse(tags.latest) : null
  const cap = latest && !latest.pre.length ? latest : null
  const mature = []
  let freshest = null
  for (const raw of versions) {
    const v = parse(raw)
    if (!v || cmp(v, cur) <= 0) continue
    if (v.pre.length && !(cur.pre.length && sameRelease(v, cur))) continue
    if (cap && cmp(v, cap) > 0) continue
    if (!withinMode(cur, v, mode)) continue
    const t = Date.parse(time[raw])
    if (t <= cut) {
      mature.push(v)
    } else if (!freshest || cmp(v, freshest) > 0) {
      freshest = v
    }
  }
  if (mature.length) {
    mature.sort((a, b) => cmp(b, a))
    return out(['pick'].concat(mature.slice(0, MAX_CANDIDATES).map((v) => v.raw)))
  }
  out(freshest ? ['held', freshest.raw] : ['none'])
}

// ---------- verify ----------
function isSemverLib (s) {
  return s && typeof s.satisfies === 'function' && typeof s.validRange === 'function'
}

function tryRequireSemver (npmDir) {
  for (const p of [path.join(npmDir, 'node_modules', 'semver'), path.join(npmDir, 'semver')]) {
    try {
      const s = require(p)
      if (isSemverLib(s)) return s
    } catch (e) {}
  }
  return null
}

function safeRealpath (p) {
  try {
    return fs.realpathSync(p)
  } catch (e) {
    return null
  }
}

// loadSemver — npm's bundled semver: from the npm executable's package, or
// the npm that ships next to this node (lib/ or Homebrew's libexec/lib/).
function loadSemver (npmBin, semverDir) {
  if (semverDir !== undefined) return tryRequireSemver(semverDir)
  const dirs = []
  if (npmBin) {
    try {
      let dir = path.dirname(fs.realpathSync(npmBin))
      for (let i = 0; i < 6 && dir !== path.dirname(dir); i++, dir = path.dirname(dir)) {
        const pkg = readJson(path.join(dir, 'package.json'))
        if (pkg && pkg.name === 'npm') {
          dirs.push(dir)
          break
        }
      }
    } catch (e) {}
  }
  for (const exe of [process.execPath, safeRealpath(process.execPath)]) {
    if (!exe) continue
    const prefix = path.dirname(path.dirname(exe))
    dirs.push(path.join(prefix, 'lib', 'node_modules', 'npm'))
    dirs.push(path.join(prefix, 'libexec', 'lib', 'node_modules', 'npm'))
  }
  for (const dir of dirs) {
    const s = tryRequireSemver(dir)
    if (s) return s
  }
  return null
}

function cmdVerify (args) {
  const cands = String(args[0] || '').split(',').filter(Boolean)
  if (!cands.length) return out(['unsuitable'])
  let engines = true
  let npmBin = ''
  let semverDir
  let current = ''
  let nodeVersion = process.version
  for (let i = 1; i < args.length; i++) {
    if (args[i] === '--no-engines') engines = false
    else if (args[i] === '--npm') npmBin = args[++i] || ''
    else if (args[i] === '--semver-dir') semverDir = args[++i] || ''
    else if (args[i] === '--current') current = args[++i] || ''
    else if (args[i] === '--node') nodeVersion = args[++i] || nodeVersion
  }
  const meta = {}
  try {
    let d = JSON.parse(readStdin() || 'null')
    d = unwrap(d)
    const items = Array.isArray(d) ? d : [d]
    for (let it of items) {
      it = unwrap(it)
      if (it && typeof it === 'object' && !Array.isArray(it) && typeof it.version === 'string') meta[it.version] = it
    }
  } catch (e) {}
  const semver = engines ? loadSemver(npmBin, semverDir) : null
  const engineProblem = (m) => {
    const range = m && m.engines && typeof m.engines === 'object' ? m.engines.node : undefined
    if (!semver || typeof range !== 'string' || !semver.validRange(range)) return ''
    if (semver.satisfies(nodeVersion, range, { includePrerelease: true })) return ''
    return 'needs node ' + range + ' (this is ' + nodeVersion + ')'
  }
  const skips = []
  for (const v of cands) {
    const m = meta[v]
    if (!m) {
      skips.forEach((s) => out(s))
      return out(['ok', v])
    }
    if (m.deprecated) {
      skips.push(['skip', v, 'deprecated: ' + String(m.deprecated).replace(/\s+/g, ' ').slice(0, 120)])
      continue
    }
    const why = engineProblem(m)
    if (why) {
      skips.push(['skip', v, why])
      continue
    }
    skips.forEach((s) => out(s))
    return out(['ok', v])
  }
  // Nothing acceptable. When the installed release is deprecated as well,
  // the whole line is: moving to its newest engine-compatible release still
  // brings its fixes.
  const curMeta = current ? meta[current] : null
  if (curMeta && curMeta.deprecated) {
    for (const v of cands) {
      if (engineProblem(meta[v])) continue
      return out(['ok', v, 'deprecated, like the installed ' + current])
    }
  }
  skips.forEach((s) => out(s))
  out(['unsuitable'])
}

// ---------- cutoff ----------
function cmdCutoff (args) {
  const now = Date.now()
  let best = null
  let ceilDays = false
  const take = (t) => {
    if (!Number.isNaN(t) && (best === null || t < best)) best = t
  }
  for (let i = 0; i < args.length; i++) {
    const flag = args[i]
    if (flag === '--ceil-days') {
      ceilDays = true
      continue
    }
    const val = args[++i]
    if (val === undefined || val === '' || val === 'null' || val === 'undefined') continue
    if (flag === '--before') {
      take(Date.parse(val))
      continue
    }
    const unit = { '--days': 86400e3, '--minutes': 60e3, '--seconds': 1e3 }[flag]
    if (!unit || !/^\d+(\.\d+)?$/.test(val) || Number(val) <= 0) continue
    take(now - Number(val) * unit)
  }
  if (ceilDays) return out([String(best === null ? 0 : Math.max(0, Math.ceil((now - best) / 86400e3 - 1e-9)))])
  out([best === null ? 'none' : new Date(best).toISOString().replace(/\.\d{3}Z$/, 'Z')])
}

// ---------- npm-outdated ----------
const SELF = new Set(['npm', 'corepack'])

// localResolved — a "resolved" that names a local path, a link or git (any
// other http(s) URL is a registry tarball, whatever its layout: GitHub
// Packages' …/download/@o/p/<ver>/<hash> has no "/-/").
function localResolved (resolved) {
  return /^(file|link|git(\+[a-z]+)?|github|gitlab|bitbucket):/i.test(resolved) ||
    /^https?:\/\/(codeload\.github\.com|gitlab\.com\/[^?]*\/-\/archive|bitbucket\.org\/[^?]*\/get)\//i.test(resolved)
}

function cmdNpmOutdated (args) {
  const root = args[0] || ''
  let doc
  try {
    doc = JSON.parse(readStdin() || '{}')
  } catch (e) {
    fail()
  }
  const d = doc && doc.outdated
  if (!d || typeof d !== 'object' || Array.isArray(d) || d.error) fail()
  const lsDeps = doc.ls && typeof doc.ls === 'object' && doc.ls.dependencies && typeof doc.ls.dependencies === 'object'
    ? doc.ls.dependencies
    : {}
  const rootOk = root !== '' && fs.existsSync(root)
  for (const [name, info] of Object.entries(d)) {
    if (!name || name[0] === '-') continue
    const list = Array.isArray(info) ? info : [info]
    const i = list.find((x) => x && typeof x.current === 'string')
    if (!i) continue
    const cur = i.current
    const latest = typeof i.latest === 'string' ? i.latest : ''
    const entry = lsDeps[name]
    const where = rootOk ? path.join(root, name) : ''
    const real = where ? installedName(where) : null
    let reason = ''
    if (SELF.has(name)) {
      reason = 'self'
    } else if (!entry || typeof entry !== 'object') {
      reason = 'unknown'
    } else if ((typeof entry.name === 'string' && entry.name !== name) || (real !== null && real !== name)) {
      reason = 'alias'
    } else if ((where && isSymlink(where)) || (typeof entry.resolved === 'string' && /^(file|link):/.test(entry.resolved))) {
      reason = 'linked'
    } else if (typeof entry.resolved === 'string' && localResolved(entry.resolved)) {
      reason = 'source'
    } else if (!parse(cur)) {
      reason = 'version'
    } else if (parse(latest) && cmp(parse(cur), parse(latest)) > 0) {
      reason = 'ahead'
    }
    out(reason ? ['skip', name, cur, reason] : ['update', name, cur, latest])
  }
}

function isSymlink (p) {
  try {
    return fs.lstatSync(p).isSymbolicLink()
  } catch (e) {
    return false
  }
}

// installedName DIR — the "name" in DIR/package.json; null when unreadable.
function installedName (dir) {
  const pkg = readJson(path.join(dir, 'package.json'))
  return pkg && typeof pkg.name === 'string' ? pkg.name : null
}

// ---------- saved specs (pnpm, bun) ----------
// registrySpec — a range or dist-tag resolved from the registry (not a
// path, URL, git/GitHub, alias, workspace, link: or file: spec).
function registrySpec (spec) {
  if (typeof spec !== 'string') return false
  const s = spec.trim()
  if (/^[a-z][a-z0-9+.-]*:/i.test(s)) return false
  if (/^[./~]/.test(s) && !/^~\s*v?\d/.test(s)) return false
  return !s.includes('/')
}

// specMode — how far the saved range lets an update move a package, and
// whether re-adding it with that operator keeps the range (see keepable):
// caret, tilde, pinned (an exact version), latest (*, x, latest) or range.
function specMode (spec) {
  const s = spec.trim()
  const r = rangeOf(s)
  if (r) return keepable(s) ? (r.op === '^' ? 'caret' : 'tilde') : 'range'
  if (parse(s.replace(/^=\s*/, ''))) return 'pinned'
  if (s === '' || s === '*' || s === 'x' || s === 'X' || s === 'latest') return 'latest'
  return 'range'
}

// ---------- pnpm-globals ----------
function isPnpmSelf (name) {
  return name === 'pnpm' || name === '@pnpm/exe' || name.startsWith('@pnpm/exe.')
}

// groupDir PATH NAME — pnpm >= 11's install group: the directory holding
// node_modules/NAME (for any globalDir: <globalDir>/vN/<group>/…).
function groupDir (p, name) {
  const tail = '/node_modules/' + name
  return p.endsWith(tail) ? p.slice(0, -tail.length) : ''
}

function cmdPnpmGlobals (args) {
  let major = null
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--major' && /^\d+$/.test(args[i + 1] || '')) major = Number(args[++i])
  }
  let d
  try {
    d = JSON.parse(readStdin() || '[]')
  } catch (e) {
    fail()
  }
  if (d && typeof d === 'object' && !Array.isArray(d)) {
    if (d.error) fail()
    d = [d]
  }
  if (!Array.isArray(d)) fail()
  const groups = new Map() // key -> { members: [], bad: '' }
  const skips = []
  for (const project of d) {
    if (!project || typeof project !== 'object') continue
    const projectDir = typeof project.path === 'string' ? project.path : ''
    // pnpm >= 11: <globalDir>/vN/<group>/node_modules/<name>, one install
    // group per directory. pnpm 10: one global project (<globalDir>/5) —
    // packages under .pnpm/ (isolated) or node_modules/ (hoisted).
    const grouped = major !== null ? major >= 11 : /\/v\d+$/.test(projectDir)
    for (const [name, info] of Object.entries(project.dependencies || {})) {
      if (!info || typeof info !== 'object') continue
      const version = typeof info.version === 'string' ? info.version : ''
      const p = typeof info.path === 'string' ? info.path : ''
      const g = grouped ? groupDir(p, name) : ''
      const key = g || 'solo:' + name
      const manifestDir = g || projectDir
      const pkg = manifestDir ? readJson(path.join(manifestDir, 'package.json')) : null
      const spec = pkg && pkg.dependencies && typeof pkg.dependencies[name] === 'string' ? pkg.dependencies[name] : ''
      let reason = ''
      if (isPnpmSelf(name)) {
        reason = 'self'
      } else if ((typeof info.from === 'string' && info.from !== name) || spec.startsWith('npm:')) {
        reason = 'alias'
      } else if (!parse(version) || (spec && !registrySpec(spec))) {
        reason = 'local'
      } else if (typeof info.resolved === 'string' && localResolved(info.resolved)) {
        reason = 'local'
      }
      if (!groups.has(key)) groups.set(key, { members: [], bad: '' })
      const grp = groups.get(key)
      if (reason) {
        skips.push([name, reason])
        if (!grp.bad) grp.bad = name
      } else {
        const s = spec || '^' + version // pnpm saves ^ unless told otherwise
        grp.members.push([name, version, specMode(s), s.trim()])
      }
    }
  }
  for (const [name, reason] of skips) out(['skip', name, reason])
  for (const [key, grp] of groups) {
    if (grp.bad) {
      for (const [name] of grp.members) out(['skip', name, 'group:' + grp.bad])
      continue
    }
    for (const [name, version, mode, spec] of grp.members) out(['member', key, name, version, mode, spec])
  }
}

// ---------- pnpm-legacy ----------
function cmdPnpmLegacy (args) {
  const root = args[0] || ''
  if (!root) return
  const pkg = readJson(path.join(path.dirname(root), '5', 'package.json'))
  const deps = pkg && pkg.dependencies && typeof pkg.dependencies === 'object' ? pkg.dependencies : {}
  for (const name of Object.keys(deps)) out([name])
}

// ---------- pnpm-outdated ----------
function cmdPnpmOutdated () {
  let d
  try {
    d = JSON.parse(readStdin())
  } catch (e) {
    fail()
  }
  if (!d || typeof d !== 'object' || Array.isArray(d) || d.error) fail()
  for (const [name, i] of Object.entries(d)) {
    if (i && typeof i === 'object' && typeof i.current === 'string' && i.latest !== i.current) out([name])
  }
}

// ---------- bun-globals ----------
function cmdBunGlobals (args) {
  const dir = args[0] || ''
  const manifest = readJson(path.join(dir, 'package.json'))
  if (!manifest) return
  const deps = Object.assign({}, manifest.optionalDependencies, manifest.dependencies)
  for (const [name, spec] of Object.entries(deps)) {
    const where = path.join(dir, 'node_modules', name)
    if (!registrySpec(spec)) {
      out(['skip', name, String(spec).startsWith('npm:') ? 'alias' : 'local'])
      continue
    }
    if (isSymlink(where) && !isolatedInstall(dir, where)) {
      out(['skip', name, 'linked'])
      continue
    }
    const pkg = readJson(path.join(where, 'package.json'))
    if (!pkg || typeof pkg.version !== 'string') {
      out(['skip', name, 'missing'])
      continue
    }
    if (pkg.name !== name) {
      out(['skip', name, 'alias'])
      continue
    }
    if (!parse(pkg.version)) {
      out(['skip', name, 'local'])
      continue
    }
    // `bun update -g NAME@VERSION` rewrites *, latest and ranges such as ~2
    // into an exact pin, and narrows ^0/^0.0: only keepable ^/~ ranges move
    const mode = specMode(spec)
    if (mode === 'pinned') {
      out(['skip', name, 'pinned:' + String(spec).trim()])
      continue
    }
    if (mode === 'latest' || mode === 'range') {
      out(['skip', name, 'range:' + String(spec).trim()])
      continue
    }
    out(['pkg', name, pkg.version, mode, String(spec).trim()])
  }
}

// isolatedInstall DIR WHERE — WHERE (a symlink in DIR/node_modules) is how
// Bun's isolated linker installs registry packages: into node_modules/.bun/.
function isolatedInstall (dir, where) {
  const store = safeRealpath(path.join(dir, 'node_modules', '.bun'))
  const real = safeRealpath(where)
  return Boolean(store && real && real.startsWith(store + path.sep))
}

// ---------- bun-outdated ----------
function cmdBunOutdated () {
  let table = false
  let other = false
  for (const line of readStdin().split('\n')) {
    const m = /^\|\s*(\S+)(?:\s+\([a-z]+\))?\s*\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*$/.exec(line)
    if (m && /^-+$/.test(m[1])) continue
    if (m && m[1] === 'Package') {
      table = true
      continue
    }
    if (m && table) {
      if (m[2] !== m[4]) out([m[1]])
      continue
    }
    if (line.trim() && !/^bun outdated v/.test(line.trim()) && !/^\|[-|]+\|$/.test(line.trim())) other = true
  }
  // no table and nothing but the banner: everything is up to date
  if (!table && other) fail()
}

// ---------- bunfig-age ----------
// tomlNumber TEXT — a TOML integer or float (_ separators; 0x/0o/0b), or NaN.
function tomlNumber (text) {
  const t = String(text).trim().replace(/_/g, '')
  if (/^[+]?0x[0-9a-f]+$/i.test(t)) return parseInt(t.replace(/^\+?0x/i, ''), 16)
  if (/^[+]?0o[0-7]+$/i.test(t)) return parseInt(t.replace(/^\+?0o/i, ''), 8)
  if (/^[+]?0b[01]+$/i.test(t)) return parseInt(t.replace(/^\+?0b/i, ''), 2)
  if (/^[+-]?(\d+(\.\d+)?([eE][+-]?\d+)?|inf|nan)$/.test(t)) return Number(t.replace(/^\+/, ''))
  return NaN
}

function cmdBunfigAge (args) {
  let best = 0
  const seen = (key, value) => {
    if (key.replace(/["'\s]/g, '') !== 'install.minimumReleaseAge') return
    const n = tomlNumber(value)
    if (Number.isFinite(n) && n > best) best = n
  }
  for (const file of args) {
    let section = ''
    for (let line of readText(file).split('\n')) {
      line = line.replace(/#.*$/, '').trim()
      const h = /^\[\s*([A-Za-z0-9_."' -]+?)\s*\]$/.exec(line)
      if (h) {
        section = h[1].replace(/["'\s]/g, '')
        continue
      }
      const kv = /^([A-Za-z0-9_."' -]+?)\s*=\s*(.+)$/.exec(line)
      if (!kv) continue
      const key = (section ? section + '.' : '') + kv[1].replace(/["'\s]/g, '')
      const inline = /^\{(.*)\}$/.exec(kv[2].trim())
      if (inline) {
        for (const part of inline[1].split(',')) {
          const ikv = /^\s*([A-Za-z0-9_."' -]+?)\s*=\s*(.+?)\s*$/.exec(part)
          if (ikv) seen(key + '.' + ikv[1].replace(/["'\s]/g, ''), ikv[2])
        }
        continue
      }
      seen(key, kv[2])
    }
  }
  out([String(Math.ceil(best))])
}

// ---------- bun-release ----------
function cmdBunRelease (args) {
  const [current, cutoff] = args
  const cut = Date.parse(cutoff)
  const cur = parse(current)
  if (Number.isNaN(cut) || !cur) fail()
  if (cur.pre.length) return out(['canary'])
  let d
  try {
    d = JSON.parse(readStdin())
  } catch (e) {
    fail()
  }
  const tag = d && typeof d.tag_name === 'string' ? d.tag_name : ''
  const v = parse(tag.replace(/^bun-v/, ''))
  if (!v || !tag.startsWith('bun-v')) fail()
  if (cmp(v, cur) <= 0) return out(['none'])
  out([Date.parse(d.published_at) <= cut ? 'upgrade' : 'held', v.raw])
}

const commands = {
  pick: cmdPick,
  verify: cmdVerify,
  cutoff: cmdCutoff,
  'npm-outdated': cmdNpmOutdated,
  'pnpm-globals': cmdPnpmGlobals,
  'pnpm-legacy': cmdPnpmLegacy,
  'pnpm-outdated': cmdPnpmOutdated,
  'bun-globals': cmdBunGlobals,
  'bun-outdated': cmdBunOutdated,
  'bunfig-age': cmdBunfigAge,
  'bun-release': cmdBunRelease
}

const [cmd, ...rest] = process.argv.slice(2)
if (!Object.prototype.hasOwnProperty.call(commands, cmd)) {
  process.stderr.write('usage: registry.cjs ' + Object.keys(commands).join('|') + ' …\n')
  process.exit(2)
}
commands[cmd](rest)
