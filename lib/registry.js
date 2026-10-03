#!/usr/bin/env node
// Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
// Licensed GPL-3.0-only with an additional attribution term under
// GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
//
// lib/registry.js — registry metadata helpers for the JavaScript cleaners
// (npm, pnpm, bun). Plain Node.js >= 18, CommonJS, no dependencies. Every
// subcommand is a pure function of its input — the cleaners run the (read-
// only) npm commands and pipe their JSON in — and prints TAB-separated lines.
//
//   pick NAME CURRENT CUTOFF MODE    stdin: npm view NAME time versions dist-tags --json
//       "pick<TAB>V1[<TAB>V2…]"  mature candidates, best first (at most 4:
//                                 the best plus three step-downs for verify)
//       "held<TAB>V"             newer releases exist, none old enough (V is
//                                 the newest of them)
//       "none"                   nothing newer to move to
//     The rules: a candidate is newer than CURRENT (never a downgrade), not
//     past the "latest" dist-tag (when that tag is a stable release), and
//     published at or before CUTOFF (an ISO date; releases without a publish
//     time count as too fresh). A prerelease is only a candidate when CURRENT
//     is a prerelease of the same MAJOR.MINOR.PATCH (2.0.0-beta.1 may move to
//     2.0.0-beta.2; to 2.0.0 or 2.0.1 in any case). MODE is "latest" (any
//     newer release), "caret" (what npm's ^CURRENT allows: the same major;
//     for 0.x the same minor; for 0.0.x nothing newer) or "tilde" (the same
//     major.minor). Candidates rank by semver precedence.
//
//   verify V1,V2… [--no-engines] [--npm NPM_BIN] [--semver-dir DIR]
//       stdin: npm view "NAME@V1 || V2 || …" name version deprecated engines --json
//       Prints "skip<TAB>V<TAB>REASON" for each candidate passed over, then
//       "ok<TAB>V" (the first acceptable one) or "unsuitable". A candidate is
//       passed over when it is deprecated, or when its engines.node range
//       excludes the Node.js running this script. The range is checked with
//       npm's own bundled semver (found from NPM_BIN, or next to node; only
//       in DIR with --semver-dir); when it cannot be loaded, engines are not
//       checked — never a failure. Candidates the metadata does not mention,
//       and unreadable input, are accepted unchecked.
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
//         source  installed from git or a non-registry URL
//         unknown not in npm ls, so its source cannot be checked
//         ahead   CURRENT is newer than "latest" (npm update -g would downgrade)
//         version CURRENT is not a semver version
//       npm records no source for globals installed from a tarball or a git
//       URL (verified with npm 11/12): those look like registry installs.
//
//   pnpm-globals                     stdin: pnpm ls -g --depth=0 --json
//       "group<TAB>NAME@VERSION[<TAB>NAME@VERSION…]" — one line per install
//       group (pnpm >= 11 installs "pnpm add -g a,b" as one group, and
//       re-adding one member alone would drop the others; every package of
//       pnpm 10 is its own line), or "skip<TAB>NAME<TAB>REASON" (self, alias,
//       local — a link:/file:/git/aliased spec — or group: shares an install
//       group with a package that cannot be re-added by version).
//
//   bun-globals DIR                  DIR = $BUN_INSTALL/install/global
//       "pkg<TAB>NAME<TAB>VERSION<TAB>MODE" (MODE from the saved range: ^ is
//       caret, ~ is tilde, * / latest is latest) or "skip<TAB>NAME<TAB>REASON"
//       (pinned, local, linked, alias, range, missing).
//
// Exit status: 0, or 3 when the input is unreadable or an npm error object.
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
  // caret: npm's ^CURRENT
  if (cur.major > 0) return v.major === cur.major
  if (cur.minor > 0) return v.major === 0 && v.minor === cur.minor
  return v.major === 0 && v.minor === 0 && v.patch === cur.patch
}

// unwrap — npm 12 wraps `npm view … --json` output in arrays.
function unwrap (d) {
  while (Array.isArray(d) && d.length === 1) d = d[0]
  return d
}

// ---------- pick ----------
function cmdPick (args) {
  const [, current, cutoff, mode = 'latest'] = args
  if (!['latest', 'caret', 'tilde'].includes(mode)) fail()
  const cut = Date.parse(cutoff)
  if (Number.isNaN(cut)) fail()
  let d
  try {
    d = JSON.parse(readStdin() || '{}')
  } catch (e) {
    fail()
  }
  if (Array.isArray(d) && d.length && d[0] && typeof d[0] === 'object' && !Array.isArray(d[0])) d = d[0]
  if (!d || typeof d !== 'object' || Array.isArray(d) || d.error) fail()
  const time = d.time && typeof d.time === 'object' ? d.time : {}
  let versions = d.versions
  if (typeof versions === 'string') versions = [versions]
  if (!Array.isArray(versions)) versions = []
  if (versions.length && Array.isArray(versions[0])) versions = versions[0]
  let tags = d['dist-tags']
  if (Array.isArray(tags)) tags = tags[0]
  const cur = parse(current)
  if (!cur) return out(['none'])
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

function safeRealpath (p) {
  try {
    return fs.realpathSync(p)
  } catch (e) {
    return null
  }
}

function cmdVerify (args) {
  const cands = String(args[0] || '').split(',').filter(Boolean)
  if (!cands.length) return out(['unsuitable'])
  let engines = true
  let npmBin = ''
  let semverDir
  for (let i = 1; i < args.length; i++) {
    if (args[i] === '--no-engines') engines = false
    else if (args[i] === '--npm') npmBin = args[++i] || ''
    else if (args[i] === '--semver-dir') semverDir = args[++i] || ''
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
  for (const v of cands) {
    const m = meta[v]
    if (!m) return out(['ok', v])
    if (m.deprecated) {
      out(['skip', v, 'deprecated: ' + String(m.deprecated).replace(/\s+/g, ' ').slice(0, 120)])
      continue
    }
    const range = m.engines && typeof m.engines === 'object' ? m.engines.node : undefined
    if (semver && typeof range === 'string' && semver.validRange(range)) {
      if (!semver.satisfies(process.version, range, { includePrerelease: true })) {
        out(['skip', v, 'needs node ' + range + ' (this is ' + process.version + ')'])
        continue
      }
    }
    return out(['ok', v])
  }
  out(['unsuitable'])
}

// ---------- npm-outdated ----------
const SELF = new Set(['npm', 'corepack'])

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
    } else if (typeof entry.resolved === 'string' && !registryTarball(entry.resolved, name)) {
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

// ---------- pnpm-globals ----------
function isPnpmSelf (name) {
  return name === 'pnpm' || name === '@pnpm/exe' || name.startsWith('@pnpm/exe.')
}

function registryTarball (resolved, name) {
  return /^https?:\/\//.test(resolved) && resolved.includes('/' + name + '/-/')
}

function cmdPnpmGlobals () {
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
    for (const [name, info] of Object.entries(project.dependencies || {})) {
      if (!info || typeof info !== 'object') continue
      const version = typeof info.version === 'string' ? info.version : ''
      const p = typeof info.path === 'string' ? info.path : ''
      // pnpm >= 11: <global>/v11/<group>/node_modules/<name>; pnpm 10:
      // <global>/5/.pnpm/<id>/node_modules/<name> (one shared project).
      const m = /^(.*)\/node_modules\/(?:@[^/]+\/)?[^/]+$/.exec(p)
      let key = 'solo:' + name
      let manifestDir = ''
      if (m && !m[1].includes('/.pnpm/')) {
        key = m[1]
        manifestDir = m[1]
      } else if (m) {
        manifestDir = m[1].slice(0, m[1].indexOf('/.pnpm/'))
      }
      let reason = ''
      if (isPnpmSelf(name)) {
        reason = 'self'
      } else if (typeof info.from === 'string' && info.from !== name) {
        reason = 'alias'
      } else if (!parse(version)) {
        reason = 'local'
      } else if (typeof info.resolved === 'string' && !registryTarball(info.resolved, name)) {
        reason = 'local'
      } else if (manifestDir) {
        const pkg = readJson(path.join(manifestDir, 'package.json'))
        const spec = pkg && pkg.dependencies && pkg.dependencies[name]
        if (typeof spec === 'string' && spec.includes(':')) reason = spec.startsWith('npm:') ? 'alias' : 'local'
      }
      if (!groups.has(key)) groups.set(key, { members: [], bad: '' })
      const g = groups.get(key)
      if (reason) {
        skips.push([name, reason])
        if (!g.bad) g.bad = name
      } else {
        g.members.push([name, version])
      }
    }
  }
  for (const [name, reason] of skips) out(['skip', name, reason])
  for (const g of groups.values()) {
    if (!g.members.length) continue
    if (g.bad) {
      for (const [name] of g.members) out(['skip', name, 'group:' + g.bad])
    } else {
      out(['group'].concat(g.members.map(([n, v]) => n + '@' + v)))
    }
  }
}

// ---------- bun-globals ----------
// registrySpec — a range or dist-tag resolved from the registry (not a
// path, URL, git/GitHub, alias, workspace, link: or file: spec).
function registrySpec (spec) {
  if (typeof spec !== 'string') return false
  const s = spec.trim()
  if (/^[a-z][a-z0-9+.-]*:/i.test(s)) return false
  if (/^[./~]/.test(s) && !/^~\s*v?\d/.test(s)) return false
  return !s.includes('/')
}

// specMode — how far the saved range lets `bun update -g` move a package.
const ONE_VERSION = 'v?\\d+(?:\\.\\d+){0,2}(?:-[0-9A-Za-z.-]+)?'
function specMode (spec) {
  const s = spec.trim()
  if (new RegExp('^\\^\\s*' + ONE_VERSION + '$').test(s)) return 'caret'
  if (new RegExp('^~>?\\s*' + ONE_VERSION + '$').test(s)) return 'tilde'
  if (parse(s.replace(/^=\s*/, ''))) return 'pinned'
  if (s === '' || s === '*' || s === 'x' || s === 'X' || s === 'latest') return 'latest'
  return 'range'
}

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
    if (isSymlink(where)) {
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
    const mode = specMode(spec)
    if (mode === 'pinned' || mode === 'range') {
      out(['skip', name, mode + ':' + String(spec).trim()])
      continue
    }
    out(['pkg', name, pkg.version, mode])
  }
}

const commands = {
  pick: cmdPick,
  verify: cmdVerify,
  'npm-outdated': cmdNpmOutdated,
  'pnpm-globals': cmdPnpmGlobals,
  'bun-globals': cmdBunGlobals
}

const [cmd, ...rest] = process.argv.slice(2)
if (!Object.prototype.hasOwnProperty.call(commands, cmd)) {
  process.stderr.write('usage: registry.js pick|verify|npm-outdated|pnpm-globals|bun-globals …\n')
  process.exit(2)
}
commands[cmd](rest)
