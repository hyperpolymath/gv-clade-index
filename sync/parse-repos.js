// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// hypatia: allow cicd_rules/javascript_detected -- the seed reader calls standards' deed parser (deed_lint.js, an ES module); no AffineScript deed parser exists yet
//
// parse-repos.js — read the registry seed, verisim/seed/chora-registry_praxis.deed.
// Run through sync/parse-repos.sh, which supplies the pinned deed parser
// (standards' 1-formats/deed/tools/deed_lint.js) in DEED_LINT_JS.
//
//   bun parse-repos.js SEED            TSV, one row per repo, in seed order:
//     name primary secondary lineage parent description owner former retired
//   bun parse-repos.js SEED --ids      name uuid minted-in
//   bun parse-repos.js SEED --total    the declared :total-repos
//   bun parse-repos.js SEED --categories   code name, for scheme clade-12
//
// The default rows keep the column contract of the A2ML parser this replaces,
// so sync/export-json.sh is unchanged: secondary is a bracketed list such as
// ["sc", "rm"], and former and retired are bracketed lists of
// "owner/name@YYYY-MM-DD" (former oldest first) or empty.
//
// The seed is checked as it is read, and any departure stops the read: the
// file must lint as a deed; each (repo …) carries exactly the members below;
// every placement names a declared scheme and one of its categories; each repo
// has exactly one primary placement in clade-12; ranks and generations count
// 1..n; :minted-in is gv-clade-index or chora-registry (V9).

const [seedPath, mode = "--rows"] = process.argv.slice(2);
const { validate } = await import(process.env.DEED_LINT_JS);

function die(msg) {
  console.error(`parse-repos: ${msg}`);
  process.exit(1);
}

let head, items;
try {
  [head, items] = validate(await Bun.file(seedPath).text(), seedPath);
} catch (e) {
  die(`${seedPath} is not a valid deed: ${e.message}`);
}
if (head !== "praxis-deed") die(`head is ${head}, want praxis-deed`);

// Split a clause body into its fields (each at most once) and its clauses.
function members(body, where, allowedFields, allowedClauses) {
  const f = {}, c = [];
  for (const [kind, name, val] of body) {
    if (kind === "field") {
      if (!allowedFields.includes(name)) die(`${where}: unexpected field :${name}`);
      if (name in f) die(`${where}: :${name} given twice`);
      f[name] = val;
    } else {
      if (!allowedClauses.includes(name)) die(`${where}: unexpected clause (${name} …)`);
      c.push([name, val]);
    }
  }
  return [f, c];
}
// The value of field `k` if it is of type `t`; die if required and missing.
function want(f, k, t, where, required = true) {
  if (!(k in f)) {
    if (required) die(`${where}: :${k} is missing`);
    return undefined;
  }
  const [vt, v] = f[k];
  if (vt !== t) die(`${where}: :${k} must be a ${t}, got a ${vt}`);
  if (t === "string" && /[\t\n]/.test(v)) die(`${where}: :${k} holds a tab or newline`);
  return v;
}
const PATH = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const DATE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
const LINEAGE = new Set(["standalone", "monorepo", "monorepo-child", "inflated", "deflated"]);
const DOMAINS = new Set(["gv-clade-index", "chora-registry"]);

const [top, clauses] = members(items, "seed",
  ["schema-version", "canonical-name", "beholding-chora", "created", "total-repos"],
  ["scheme", "repo"]);
if (want(top, "canonical-name", "string", "seed") !== "chora-registry-seed") {
  die("seed: :canonical-name must be \"chora-registry-seed\"");
}
want(top, "beholding-chora", "uuid", "seed");
const total = want(top, "total-repos", "integer", "seed");

const schemes = new Map();
for (const [name, body] of clauses) {
  if (name !== "scheme") continue;
  const [f, cats] = members(body, "scheme", ["id", "kind", "membership", "link"], ["category"]);
  const id = want(f, "id", "symbol", "scheme");
  if (schemes.has(id)) die(`scheme ${id} declared twice`);
  const kind = want(f, "kind", "symbol", `scheme ${id}`);
  if (!["strict", "judgement", "none"].includes(kind)) die(`scheme ${id}: :kind ${kind}`);
  const membership = want(f, "membership", "symbol", `scheme ${id}`);
  if (!["single", "multiple"].includes(membership)) die(`scheme ${id}: :membership ${membership}`);
  want(f, "link", "symbol", `scheme ${id}`, membership === "multiple");
  const codes = new Map();
  for (const [, cb] of cats) {
    const [cf] = members(cb, `scheme ${id} category`, ["id", "name"], []);
    const cid = want(cf, "id", "symbol", `scheme ${id} category`);
    if (codes.has(cid)) die(`scheme ${id}: category ${cid} declared twice`);
    codes.set(cid, want(cf, "name", "string", `scheme ${id} category ${cid}`));
  }
  schemes.set(id, { kind, membership, codes });
}
const clade = schemes.get("clade-12");
if (!clade) die("seed: scheme clade-12 is not declared");

if (mode === "--total") {
  console.log(total);
  process.exit(0);
}
if (mode === "--categories") {
  for (const [code, name] of clade.codes) console.log(`${code}\t${name}`);
  process.exit(0);
}

const list = (xs) => `[${xs.map((x) => `"${x}"`).join(", ")}]`;
const names = new Set();
const out = [];
for (const [name, body] of clauses) {
  if (name !== "repo") continue;
  const [f, cs] = members(body, "repo",
    ["name", "owner", "uuid", "minted-in", "description"],
    ["lineage", "placement", "former", "retired"]);
  const rn = want(f, "name", "string", "repo");
  const at = `repo ${rn}`;
  if (names.has(rn)) die(`${at}: registered twice`);
  names.add(rn);
  const owner = want(f, "owner", "string", at);
  // As export-json.sh: refuse what could leave a shell quote or expand.
  // ("games & trivia" is a seed problem of its own, kept as it is.)
  if (!/^[^/"$`\\]+$/.test(owner) || !/^[^/"$`\\]+$/.test(rn)) die(`${at}: ${owner}/${rn} is not a safe owner/name`);
  const uuid = want(f, "uuid", "uuid", at);
  const domain = want(f, "minted-in", "symbol", at);
  if (!DOMAINS.has(domain)) die(`${at}: :minted-in ${domain} is not gv-clade-index or chora-registry`);
  const desc = want(f, "description", "string", at);

  const lin = cs.filter(([n]) => n === "lineage");
  if (lin.length !== 1) die(`${at}: needs exactly one (lineage …)`);
  const [lf] = members(lin[0][1], `${at} lineage`, ["type", "parent", "evolved-from"], []);
  const ltype = want(lf, "type", "symbol", `${at} lineage`);
  if (!LINEAGE.has(ltype)) die(`${at}: lineage type ${ltype}`);
  const parent = want(lf, "parent", "string", `${at} lineage`, false) ?? "";
  want(lf, "evolved-from", "string", `${at} lineage`, false);

  let primary = null;
  const ranked = [];
  for (const [, pb] of cs.filter(([n]) => n === "placement")) {
    const [pf] = members(pb, `${at} placement`, ["scheme", "category", "primary", "rank"], []);
    const sid = want(pf, "scheme", "symbol", `${at} placement`);
    const s = schemes.get(sid);
    if (!s) die(`${at}: placement in undeclared scheme ${sid}`);
    const cat = want(pf, "category", "symbol", `${at} placement`);
    if (!s.codes.has(cat)) die(`${at}: category ${cat} is not in scheme ${sid}`);
    const isPrimary = want(pf, "primary", "boolean", `${at} placement`, false) === "#t";
    const rank = want(pf, "rank", "integer", `${at} placement`, false);
    if (isPrimary === (rank !== undefined)) die(`${at}: a placement is either :primary #t or ranked`);
    if (sid !== "clade-12") continue;
    if (isPrimary) {
      if (primary !== null) die(`${at}: two primary placements in clade-12`);
      primary = cat;
    } else ranked.push([Number(rank), cat]);
  }
  if (primary === null) die(`${at}: no primary placement in clade-12`);
  ranked.sort((a, b) => a[0] - b[0]);
  ranked.forEach(([r], i) => { if (r !== i + 1) die(`${at}: placement ranks must count 1..n`); });

  const former = cs.filter(([n]) => n === "former").map(([, fb]) => {
    const [ff] = members(fb, `${at} former`, ["generation", "path", "until"], []);
    const g = Number(want(ff, "generation", "integer", `${at} former`));
    const p = want(ff, "path", "string", `${at} former`);
    const u = want(ff, "until", "string", `${at} former`);
    if (!PATH.test(p) || !DATE.test(u)) die(`${at}: former ${p}@${u} is not owner/name@YYYY-MM-DD`);
    return [g, `${p}@${u}`];
  }).sort((a, b) => a[0] - b[0]);
  former.forEach(([g], i) => { if (g !== i + 1) die(`${at}: former generations must count 1..n`); });

  const retired = cs.filter(([n]) => n === "retired").map(([, rb]) => {
    const [rf] = members(rb, `${at} retired`, ["path", "until"], []);
    const p = want(rf, "path", "string", `${at} retired`);
    const u = want(rf, "until", "string", `${at} retired`);
    if (!PATH.test(p) || !DATE.test(u)) die(`${at}: retired ${p}@${u} is not owner/name@YYYY-MM-DD`);
    return `${p}@${u}`;
  }).sort((a, b) => a.split("@")[1].localeCompare(b.split("@")[1]) || a.localeCompare(b));

  if (mode === "--ids") out.push([rn, uuid, domain].join("\t"));
  else out.push([rn, primary, list(ranked.map(([, c]) => c)), ltype, parent, desc, owner,
    former.length ? list(former.map(([, e]) => e)) : "",
    retired.length ? list(retired) : ""].join("\t"));
}
if (mode !== "--ids" && mode !== "--rows") die(`unknown mode ${mode}`);
if (out.length) console.log(out.join("\n"));
