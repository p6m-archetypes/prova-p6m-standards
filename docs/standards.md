# p6m Service Standards — the executable bar

This document is the spec the `p6m` prova plugin turns into proofs. Every p6m service archetype
(6 languages × {grpc, rest, graphql, basic, retrofit}) must render services that pass the same
parameterized suite. The goal: **12-factor services that are nearly indistinguishable from each
other at runtime** — same API for the same inputs, same logging, same health surface, same
metrics/traces, same container story.

Source of truth for the platform contract is `platform-application-manifests-library` (what the
platform actually probes and injects), plus the survey of all 80 repos on 2026-07-22 (summarized
in the matrix below).

## 1. The original drift (why this exists) — a HISTORICAL SNAPSHOT

> **This table is dated 2026-07-22 and is not maintained.** It records the survey that motivated
> these standards. It is **not** a status board, and several rows are now false.
>
> **For current status, read the S-section for that axis**, or run the suite — which is the whole
> point: the proofs are the live answer, and prose about compliance goes stale by construction.
>
> This is not a hypothetical failure mode. On 2026-07-27 this table's CI row was read as current and
> produced two wrong conclusions in a row: that java and rust still needed CD work (both had been
> converged for days), which led to a duplicate of a fix that had already merged weeks earlier. A
> stale local checkout independently reproduced the same wrong answer. **Verify against the org's
> `dev` branch, or against a suite run — never against this table or a working copy.**

Re-checked 2026-07-27 (`✅` verified resolved, `⚠️` partly resolved, `❔` not re-verified since the
survey — the live suites are the authority for these):

| Axis | State on dev (2026-07-22) | 2026-07-27 |
|---|---|---|
| CRUD | dotnet + typescript + python(grpc): full 5 ops. rust grpc: no Delete. rust rest: List only. rust graphql: no update/delete. golang: Create/Get/List only — and grpc/graphql APIs are **not even mounted** (commented-out TODO). java: **health-only on all three transports**; java-rest has zero routes. | ❔ S2 is the authority now |
| API naming | REST: dotnet/python/typescript hard-code `Item`/`/api/items` (service name never reaches the API); golang uses `/api/v1/{prefix_name}s`; rust uses `/{prefix-name}s`. gRPC rpc names: `Create{PrefixName}` everywhere it exists, but service naming and versioning differ (`package {prefix}_{suffix}` vs `{prefix}.{suffix}.v1`). GraphQL: typescript/dotnet name the type `{PrefixName}{SuffixName}`, rust/python/golang use `{PrefixName}`; typescript keeps `get`/`list` prefixes, dotnet (HotChocolate) strips `get`. | ❔ S2 is the authority now |
| Env contract | Manifests inject `SERVER_PORT`/`GRPC_PORT`, `MANAGEMENT_PORT`, `LOGGING_STRUCTURED=true`. golang binds `PORT` (not SERVER_PORT). rust binds `APP_SERVER__PORT` (figment prefix — ignores the platform's vars entirely). java grpc collapses the management server onto the service port. | ❔ S3 is the authority now |
| Structured logging | Honored by dotnet/golang/java/python/rust; **typescript defines `LOGGING_STRUCTURED` but never reads it** (pino always JSON). Default off in python. | ✅ typescript reads the flag (`logging.ts` switches to pino-pretty when false) and passes the S4 ratchet on both variants. Note the ratchet itself only began holding at v1.8 — see S4. |
| Health | `/health/readiness` + `/health/liveness` on the management port everywhere — the one converged axis. But manifests wire **only readinessProbe**; liveness is implemented and never probed. Readiness is a static `ok` in most (rust grpc has a real gate). | ❔ S5 is the authority now; the manifests still wire only readinessProbe |
| Metrics | Real Prometheus output in five languages; **rust `/metrics` is a stub string**. | ✅ rust's `/metrics` is real: `metrics_exporter_prometheus::PrometheusBuilder` with a `PrometheusHandle` renderer, not a stub string |
| Traces | OTel fail-open in dotnet/python/rust/typescript; java disabled-by-default; **golang pins the OTel deps and never initializes them**. | ❔ S7 is the authority now |
| Docker | `.platform/docker/{local,prd}/Dockerfile` is the convention in all 30 service archetypes. But: **no `.dockerignore` anywhere** (+ `COPY . .`); local==prd byte-identical in java/python/rust; golang templates `COPY go.sum` with no go.sum (clean build fails); java Dockerfiles call a `./mvnw` that is never rendered; only dotnet-rest's suite ever builds an image. | ⚠️ `.dockerignore` now renders in 18 content trees; golang uses `COPY go.* ./`, which tolerates the absent go.sum; the `./mvnw` calls are gone (java-service-basic was the last, fixed 2026-07-27 — its image could not build at all). Still open: local==prd duplication, pending the S8 multi-stage end-state. No longer true that only dotnet-rest builds an image — the standards SUT builds the production image for every archetype carrying a suite. |
| Prova | golang + rust: **no suites at all**. Everywhere else: `[run] paths = ["tests"]` — a key prova ≥0.7 does not read (dead config); plugins pinned `@main`. dotnet-graphql has a tracked `.last-failed.json` showing red. python-basic has an in-flight branch **replacing prova with the legacy pytest harness** (YP6M-3006 — needs an org decision before the sweep). | ✅ fully resolved: golang and rust have 4 prova packages each (28 fleet-wide), zero `[run] paths`, zero `@main` pins, zero tracked `.last-failed.json`. Generated LuaLS artifacts are now gitignored and asserted (S9). The YP6M-3006 pytest-harness question is unrelated and still open. |
| CI | Rendered-project CI: dotnet/python/typescript get build→docker→push→manifest-dispatch; **golang/java/rust build only** (no image, no CD). golang uses community actions instead of `p6m-actions/*`. | ✅ all six render the full build→docker→push→manifest-dispatch pipeline on `p6m-actions/*`, audited against each ci-library's `dev`. golang was the last gap and needed three new actions — see S9. **This row is the one that misled; do not read it as current.** |

## 2. The standard

**Principle — idiomatic inside, identical at the boundary.** Every requirement below is stated in
terms a black-box caller can observe: names on the wire, env vars honored, endpoints answered,
status semantics, log shape on stdout. That is deliberate: the suite never dictates frameworks,
internal naming, or config plumbing — each language satisfies the contract the way its ecosystem
would (Spring relaxed binding, a figment env layer, strawberry's auto-camelCasing, pino vs
Serilog vs slog). Where idiom and contract tension, the contract wins at the boundary and the
bridge stays as small and native as the language allows. Compliance is sameness of behavior,
not sameness of code.

### S1 — Identity and casing

<!-- claim: simplified-identity -->
One answer set drives every rendering, and it names **two things, not four**:

| Answer | What it is |
|---|---|
| `project_name` | the repository and project directory, the container image, the `PlatformApplication`, the Tilt resource, `OTEL_SERVICE_NAME`, and the gRPC service name |
| `entity_name` | the CRUD subject the generated API exposes — **defaulted** from `project_name`, and a real answer |
| `solution_name` | the namespace prefix; the platform operator reads solution and environment back out of `{solution}-{application}-{env}` |

plus ports and resource selections. From each name the casing set is fixed — PascalCase
(`UserDetailsService`), snake (`user_details_service`), kebab (`user-details-service`) — and the
suite always runs **two name shapes**, a single word and a multi-word, because casing bugs only
show on the second.

**The two names are separate because they were always two jobs.** `prefix_name` used to be both
half of the project name and the CRUD entity, which is why `billing-service` could not say
whether its REST collection was `/api/v1/billings` or `/api/v1/billing-services`. It is
`/api/v1/billings`: S2's "entity-named, not service-named", now sayable because the entity has
its own answer.

**Exactly one implementation derives; the oracle takes.**
[`p6m-identity-library`](https://github.com/p6m-archetypes/p6m-identity-library) owns the single
p6m-specific name derivation in the fleet — the entity defaulted off the project name by
stripping a trailing type qualifier (`service`, `gateway`, `adapter`, …) — and proves it in its
own suite against a table of name shapes. `p6m.identity{ project = …, entity = … }` accepts both
as explicit inputs and computes no names of its own beyond casing. A prompt library and an oracle
that each derive the same names is a drift machine; an omitted `entity` therefore means *this
shape has no domain entity* (overlay, basic), never *guess what the library would have done*.

Casing needs no such care: `prova.str` calls archetect's own inflections, so a name cased by the
oracle and a name cased by a template agree by construction.

**Retired (YP6M-3424):** `org_name` × `solution_name` as two prompts (nothing read either — only
their combination), `prefix_name` × `suffix_name`, and author identity (`author_name` /
`author_email` reached four files fleet-wide, and archetect pre-answers them from `~/.gitconfig`).
`p6m.identity` rejects `prefix`/`suffix` with the migration in the error message rather than
returning a nil that surfaces as an empty class name three layers downstream.

Conventions are not lost by asking less. Archetect resolves answers `config → -A files → -a
flags` and an answered key suppresses its prompt entirely, so an org convention supplied by
`p6m-catalog` or injected by Ybor Studio costs zero prompts and **cannot be typed wrong** — which
a free-text prefix never guaranteed.

### S2 — One API, three transports (full CRUD)
Every transport of a full-flavor archetype exposes the same five operations over the entity
`{ id, display_name }`, named from the answers:

- **gRPC** — `package {prefix}_{suffix}` (flat, DECIDED 2026-07-22: no `.v1` segment);
  `service {PrefixName}{SuffixName}`; rpcs `Create{PrefixName}`, `Get{PrefixName}`,
  `List{PrefixName}s`, `Update{PrefixName}`, `Delete{PrefixName}`; server reflection +
  `grpc.health.v1.Health` = SERVING on the service port.
- **REST** — `/api/v1/{prefix-name}s` (kebab, plural — DECIDED: name-derived, versioned
  prefix; no hard-coded `items`): POST(201) / GET list / GET id / PUT / DELETE(204) + 404
  semantics.
- **GraphQL** — type `{PrefixName}` (DECIDED: entity-named, not service-named); query
  `{prefixName}(id)` and `{prefixName}s` (no `get`/`list` prefixes); mutation
  `create/update/delete{PrefixName}`; served at `/graphql` on the service port.

**The persistence model is `{EntityName}Entity`; the wire type is `{EntityName}`.** (DECIDED
2026-08-18.) Naming the CRUD surface after the entity puts the stored type and the transported
type in the same scope, and in three languages they collided outright — `CS0104: 'Customer' is an
ambiguous reference between CustomerService.Domain.Customer and CustomerService.Proto.Customer`;
java's generated protobuf message against its JPA `@Entity`; python's strawberry type shadowing
the SQLAlchemy model it imports. The boundary name is the one the standard fixes, so the
*internal* type is what moves: the suffix goes on the persistence model, never on the wire type.

Applied uniformly rather than only where a compiler complains — golang's two `{EntityName}`
structs in different packages and rust's store record collide for a reader even where they do not
collide for a compiler, and a rule with a "when it clashes" clause is a rule each language decides
for itself. The table name is unaffected (`@Table`, `__tablename__` and EF's DbSet property all
name it independently), so `p6m.spec`'s persistence oracle does not move.

Pluralization is a naive appended `s` (what ATL templates can produce): `customers`,
`userDetailss`. Ugly on some words, but uniform and mechanical — the oracle mirrors it.

CRUD round-trips into the selected persistence (rows verified via SQL), identically across
languages: the suite drives all three transports with the same semantic script.

### S3 — Environment contract (12-factor)
Exactly what the manifests inject, honored by every service:
`SERVER_PORT` (HTTP transports) / `GRPC_PORT` (gRPC), `MANAGEMENT_PORT`,
`LOGGING_STRUCTURED`, `DB_HOST` `DB_PORT` `DB_USERNAME` `DB_PASSWORD` `DB_DBNAME`,
`CACHE_*`, `MESSAGING_*`, `OTEL_SERVICE_NAME` (default `{project-name}`),
`OTEL_EXPORTER_OTLP_ENDPOINT` (fail-open). Proof: boot with overridden ports and observe the
service actually listening there — this catches rust's `APP_SERVER__PORT` and golang's `PORT`.

### S4 — Structured logging
With `LOGGING_STRUCTURED=true`: stdout is JSON-lines; every record parses; minimum keys
`timestamp`/`level`/`message` (mapped per ecosystem but present); service identity appears.
With it unset/false: human-readable. The flag must be *read*, and the suite proves it from
both directions: the primary SUT (flag on) must emit JSON lines, and a sibling boot of the
same image with the flag off must emit at least one non-JSON line (an always-JSON service
that merely defines the flag fails — the ratchet's first click, added after three independent
agents flagged the one-sided assertion).

### S5 — Health
`GET /health/readiness` and `/health/liveness` on **MANAGEMENT_PORT**, 200 + JSON status.
gRPC additionally `grpc.health.v1.Health` SERVING. Readiness must reflect dependency truth
when persistence is selected (not a static `ok` before the DB is reachable).
*(Also: manifests should gain the livenessProbe — today only readiness is probed.)*

### S6 — Metrics
`GET /metrics` on MANAGEMENT_PORT, Prometheus text format, at least one real metric family
(fails rust's stub).

### S7 — Traces
OTel wired fail-open: exporting iff `OTEL_EXPORTER_OTLP_ENDPOINT` set. Phase-2 proof: an OTLP
sink container on the topology network receives ≥1 span from a traced request.

### S8 — Container-first, production-image-first
The **production** Dockerfile builds from a **clean render** and that container is the SUT for
the whole suite — the machine needs Docker and nothing else (no SDKs on the host), and what is
proven is the artifact CI publishes and the platform deploys, under the exact env contract it
will receive. `.dockerignore` present; non-root user; `EXPOSE {service,management}`.

End-state (DECIDED direction 2026-07-22): **one multi-stage Dockerfile** per service —
`builder → dev → runtime` — replacing the `{local,prd}` pair. The final stage is the default
build (CI publishes it); Tilt builds `--target dev` for the inner loop. Today the pair is
byte-identical in java/python/rust, trivially divergent in typescript/golang, and *harmfully*
divergent in dotnet (ca-certificates only in prd) — a named target makes drift structurally
impossible. Until an archetype unifies, the bar is: prd must build and pass from a clean
render; `local` is unheld (inner-loop only).

### S8b — No host tooling in archetype suites (DECIDED 2026-07-23)
An archetype's suite may not invoke local toolchains at all — not even capability-gated
`build_steps`. Docker is the single requirement; a suite must behave identically on a laptop
and a CI runner. Compile coverage is containerized: the standards SUT builds every persistence
variant's production image, and the hollow (None) rendering is proven by a docker-gated
`docker.build` of its production Dockerfile. A rendered project's own unit tests belong to the
rendered project's CI, not to the archetype's suite.

### S1c — The prompt surface has one layout vocabulary

<!-- claim: layout-vocabulary -->
Every archetype lays its prompts out in **pages and sections** (`context:page` / `ctx:section`,
archetect >= 3.4.3), and they all use the **same keys**, so a form reads identically whatever the
language or shape:

| Page | Sections | Shapes |
|---|---|---|
| `project` | `platform`, `service` | all |
| `container_build` | — | overlay only |
| `resources` | `persistence`, `cache`, `messaging`, `object_storage` | full (overlay carries the page without sections) |
| `source_control` | — | all, unless the caller passes `-s no-scm` (S1d) |

Grouping intent is the one thing a derived interface cannot infer from the script — only the
author has it — so the script says it, once, in a vocabulary the fleet shares. **A shape omits a
page or section it has no prompts for; it never invents one.** basic drops `resources` and the
entity; overlays drop the entity and add `container_build`.

**Keys are pinned, never derived from a title.** Ybor Studio drives this as a *hybrid* wizard —
describe with the answers so far, render the first page that still has prompts, collect, describe
again — and pages appear and disappear between rounds as branches open. A client therefore routes
on `key`; titles are display text and may change. Every `page` and `section` in the fleet passes an
explicit `key`, and the bare-string form (`context:page("Project", …)`, which lets archetect
derive a key from the title) is not used.

**A prompt that depends on an earlier answer sits in the SAME page as what it depends on.**
`messaging_access` lives inside the `messaging` section, not on a later page; the GitHub repository
details live inside `source_control`. That page simply comes back with one more field and the
client stays on the step — progressive disclosure, rather than a step that vanishes and reappears
elsewhere. Measured on java-rest: full shapes converge in 5 rounds, overlays 6, basic 3.

**What this standard does NOT restate.** That a declaration becomes a layout in the derived
interface is archetect's bar, held by its own suite; asserting it here would be a second statement
of one thing. What is held here is that our archetypes declare the vocabulary above — the part
only we can get wrong.

### S1d — The caller may own source control (2026-08-21)

<!-- claim: scm-handoff -->
Every archetype takes a `no-scm` switch. With it, the `source_control` page is not declared and
`scm.finalize` never runs; without it — the CLI, which supplies no switches — both happen
exactly as before. The switch changes **the prompt surface and the git side effects, never the
rendered files**.

Ybor Studio's `generator-service` creates the repository and packages the output itself, so the
archetype has to be able to stand down. Answering `scm_provider = "None"` is not that: the page
still derives, and a client that renders the interface as a form shows a step that asks nothing.

```
$ archetect interface <archetype>              $ archetect interface <archetype> -s no-scm
  ▸ PAGE Project                                 ▸ PAGE Project
  ▸ PAGE Container Build                         ▸ PAGE Container Build
  ▸ PAGE Resources                               ▸ PAGE Resources
  ▸ PAGE Source Control
```

**Negative polarity is the whole design.** Switches are never prompted, so whichever behavior the
switch selects is unreachable from an interactive run. The default therefore has to be the
interactive path, and the programmatic caller is the one that opts out. It is named for the
effect rather than for Studio, so a CI job that wants no repository created can pass it without
pretending to be a client it isn't. `archetect interface` lists it alongside `zip`, `tarball`
and `debug-context`, which is how a client discovers it.

**The zip half of the same hand-off needs no switch of its own.** `archive-library` has no
prompts and is already opt-in (`-s zip` / `-s tarball`, both off by default), so a caller that
packages the output itself simply does not pass them.

**How it is held.** Two tests, because the switch has two failure modes:

- *The guard is dropped* — held on the SCRIPT, the same way S1c is: strip every
  `if not <guard> then … end` block and assert that neither `scm.prompt`, `scm.finalize`, nor
  the `source_control` declaration survives in what runs unconditionally. A guard written some
  other shape simply is not stripped and reads as unguarded, so the check fails closed.
- *The guard is wired around content* — held BLACK-BOX: render with the switch and without it,
  and assert both write the identical file set. Without this, a guard that also skipped a
  `directory.render` would ship a second, quieter render shape to whoever passes the switch.

Both were mutation-tested on 2026-08-21: unguarding `scm.finalize` fails the first, moving
`directory.render("contents/base", …)` inside the guard fails the second.

### S1b — The prompt surface is a declared interface

<!-- claim: prompt-surface-conformance -->
Every archetype **complies with one declared interface**, and the interface is stated in the
plugin rather than in thirty repos. This is §2b's E2 generalized off the overlay shape: the same
two halves, because a render can only observe one of them.

- **What is REQUIRED** is observed by rendering headlessly with only the declared answer key and
  **no defaults fallback**. Archetect makes an unanswered prompt that has no default a hard error
  naming its key, so a required answer the archetype's output never reads cannot hide behind `-D`.
- **What is merely DEFAULTED** renders perfectly and is invisible to that check — a suffix
  selector, a debug port nothing publishes. That half is held on the **composed catalog**: an
  archetype may compose only libraries whose prompts survive the declared vocabulary
  (`p6m.PROMPT_LIBRARIES`), must compose `p6m-identity`, and may compose none of the three
  retired identity libraries (`author`, `org`, `project` — each refused with the measurement that
  retired it, so the failure says *why*).

**One harness per shape is what makes compliance structural rather than clerical.** A p6m
archetype has one of three shapes — **full** (rest/grpc/graphql), **basic**, **overlay**
(§2b) — and the shape, not the language, decides which standards have a subject. Each shape
carries a `spec{}` / `render` / `standards.*` triple, so a language's suite is a thin invocation
and every language is held identically by construction.

The cost of not having this was measured on 2026-08-17, before the triple existed for the full
and basic shapes: **21 of 30 suites called `archetect.render` themselves**, and the entity's
persistence table — one standard, name-derived per S2 — had **four** answers across the fleet
(`items`, `Items`/`DisplayName`, `` `items` ``, `{prefix_name}s`). The hardcoded-`items` suites
asserted a weaker bar than the name-derived ones and every one of them passed, because a suite
that hardcodes `items` cannot fail against a service that hardcodes `items` too. **A suite that
encodes the drift it exists to catch is worse than no suite: it reports green.**

`p6m.spec{}` closes it structurally — the identity, the render answers and the SQL oracle all come
from one object, so a suite cannot answer the archetype one thing and assert another.

### S9 — Suite and CI hygiene
`prova.toml` uses `[run] proofs = [...]` (prova ≥0.7), plugins pinned to released tags
(`prova-rs/prova-postgres@v1` etc. — released 2026-07-22), `acceptance.yaml` on
`prova-rs/run-action@v1` **with no local `version:`** (§2b E7), `.last-failed.json` gitignored.
Rendered-project CI: all six languages get the full build→docker→push→manifest-dispatch pipeline
on `p6m-actions/*`, plus the promotion tail (2026-08-31): a rendered `promote.yaml` that moves a
release to stg/prd by manual dispatch of `p6m-actions/release-promote-to-environment@v1` — held
at the E5 seams, since the same ci-libraries render CI for every shape.

> **Corrected 2026-08-17 (YP6M-3424).** This line used to require the opposite — an *explicit*
> `version:` — while E7's proof has forbidden one since v1.10. The proof was right and the prose
> was stale, so a reader following S9 would have written a workflow its own suite rejects. The
> engine version belongs in `run-action`, which is bumped on every prova release; a local pin
> freezes the suite while looking current, which is exactly how six overlay repos sat on v0.11.0
> while the fleet ran v0.14.0.

Status (2026-07-27): **this axis is closed — all six languages render the full pipeline.** Audited
directly against each `*-ci-library`'s `dev` on that date: every one has cut-tag, image publish and
manifest dispatch.

**golang was the last gap**, and the only one needing new actions:
`p6m-actions/golang-{setup,build,cut-tag}` were created and released at `@v1`, and
`golang-ci-library` converged onto them (§2b E5 has the details, including why golang's cut-tag is
tag-driven where every other ecosystem's rewrites a manifest field).

**java and rust were already done** before this sweep — java by
`YP6M-3071/align-build-workflow-with-docker-release`, rust during the S10 work. The §1 survey line
saying otherwise is dated 2026-07-22 and simply predates both. Flagging that explicitly because it
is a trap: that row still reads "golang/java/rust build only", and a local checkout that predates
those merges reproduces the same wrong conclusion. **Check the org's `dev`, not §1 and not a working
copy**, before deciding this work is outstanding.

### S10 — CI parity (DRAFT 2026-07-23)
**Every command the rendered project's own CI invokes must succeed on a fresh clone with only
the stack's toolchain present.** The production Dockerfile (S8) and the CI build workflow are
two independent build paths, and only the first was held by a proof — the drift bit on
2026-07-23: typescript-grpc's `pnpm build` needed proto codegen that only its Dockerfile ran,
so every rendered repo's CI failed at the first e2e push while the archetype suite stayed
green. The corollary standard on the archetype itself: **a script CI invokes may not depend on
untracked generated files** — codegen belongs inside the script that needs it.

Proof mechanism (S8b-conformant — docker stays the only host requirement): a generated
throwaway Dockerfile whose base is the stack's toolchain image, whose context is the clean
render, and whose `RUN` steps are the exact command sequence the `p6m-actions` setup/build
steps execute (`p6m.ci.stacks` is the one place that sequence is mirrored; conditional steps
keep the action's own guard, e.g. `if grep -q '"lint":' package.json`). `docker.build` success
IS the proof. One hollow (`[None]`) render per archetype suffices — resource variants change
dependencies, not the command path.

Scope note: S10 proves the *always-run* command path (lint/test/build from a clean checkout).
The main-branch-only path (docker publish, cut-tag, manifest dispatch, real org secrets/vars,
`p6m-actions` internals) is deliberately out of scope — that is the e2e harness's tier
(`p6m-archetypes/archetype-e2e-tests`), which renders into a real org and watches the real
workflow. The two tiers meet at this seam and must not duplicate each other.

## 2b. The retrofit overlay archetypes — E1–E7 (2026-07-27)

The six `*-service-empty-archetype` repos are a different kind of thing from the eighteen service
archetypes, and holding them to S1–S10 mostly asks the wrong questions. A **retrofit overlay**
archetype targets an **existing** application: it renders only the platform servicing layer —
CI/CD workflows, container builds, platform manifests, repo hygiene — **in place at the
destination root**, and never a line of project scaffolding. Nothing is generated that could be
booted, so S2 (API), S4–S7 (logging/health/metrics/traces) and S10 (CI parity — there is no
rendered project whose CI could be run) have no subject here.

Naming note (2026-08-20): the catalog displays these as `<Lang> Retrofit Overlay`, and the leaf
key is `p6m/<lang>/services/retrofit` — renamed from `empty`, which read as "blank project", the
opposite of what these archetypes do. Everything a user sees now says retrofit.

The identifiers deliberately do not follow, and that is a **closed decision, not a backlog item**:
the repos stay `*-service-empty-archetype` and the plugin namespace stays `p6m.empty.*`. Neither
is user-visible; renaming the repos would move every `source:` URL and break the 30-repo inventory
that keys on the string `service-empty-archetype`; and S1c's shape vocabulary already says
`overlay` (`p6m.LAYOUT.required.overlay`), so the standard carries the modern term where it
matters. Prose in this document says "retrofit overlay"; identifiers say `empty`.

What replaces them is stricter on the axes that *do* exist. The failure modes of a retrofit are
not "the service answers the wrong route"; they are "the generator wrote a `pom.xml` into
someone's Gradle app", "it clobbered the app's `.gitignore`", "it asked the platform team to
invent an org and a solution before it would emit a workflow", and "the image name in the
workflow doesn't match the one in the manifest, so CD silently never updates". E1–E7 are those
seams.

### E1 — One tactical answer, everything else derived
The overlay asks for **deployment facts, not identity opinions**. The application name is the
only name it asks: it is simultaneously the container image name, the `PlatformApplication`
name, the CD manifest directory (`directory-name`), and the Tilt resource. From it and the
solution slug everything else is derived:

- image repository — `{registry}/{solution}/{application}`
- namespace, per environment — `{solution}-{application}-{env}` (the platform operator derives
  solution + environment back out of this, which is what lets `Shared` resources be shared)
- repo name / GitHub owner for the optional SCM step

There is deliberately **no** `prefix_name`/`suffix_name` decomposition, no `org_name` ×
`solution_name` split, and no author identity: a service archetype needs those to name packages,
namespaces and modules in code it is generating, and an overlay generates none of that.

### E2 — The prompt surface IS the tactical minimum
**An overlay may require no answer that its rendered output does not consume.** The bar is
mechanical and black-box: rendering headlessly with only the tactical answer key and **no
defaults fallback** must succeed. Archetect makes an unanswered prompt that has no default a hard
error naming the key, so a stray required prompt cannot hide — and a prompt whose answer nothing
reads cannot justify itself.

The tactical key, in full — three facts with no sane default, plus defaulted selections:

| Answer | Consumed by |
|---|---|
| `project_name` (the application/image name) | workflow `IMAGE_NAME`/`APPLICATION_NAME`, manifest name + namespace + labels, image path, Tiltfile |
| `org_solution_name` (the solution slug) | image path, `{solution}-{app}-{env}` namespaces |
| `image_registry` | image path |
| `protocol` (default REST) | `SERVER_PORT` vs `GRPC_PORT`, the manifest's port protocol |
| `service_port`, `management_port` | manifest ports + config, `EXPOSE`, readiness probe |
| `persistence`, `cache`, `messaging` (+ access) | manifest `resourceRequirements` |
| `build_command` (defaulted) | the builder stage of both Dockerfiles |
| `runtime_artifact` (defaulted) | what the runtime stage copies and runs |
| `scm_provider` (default None) | the optional publish-the-repo step |

### E1b — The container build is answered, never assumed (2026-07-27)
An overlay retrofits an **existing** application, so its Dockerfile may not assume the application's
internal shape. Every one of the six originally did: rust built `-p {app}_bin`, java `-pl
{app}-server`, dotnet `{Pascal}/{Pascal}.csproj`, python a `src/` layout plus a console script,
typescript `pnpm-workspace.yaml` and `dist/index.js`, golang `./cmd/server`. That containerizes
applications already shaped like *our own archetypes* — the one thing a retrofit tool cannot take
for granted.

Two rules replace it:

- **The builder copies the repo wholesale** (`COPY . .`) rather than naming parts of it, so no
  layout is implied.
- **`build_command` and `runtime_artifact` are answers**, defaulted to what that language's own p6m
  service archetype produces. A greenfield-shaped repo therefore answers neither, and a legacy repo
  overrides one line instead of rewriting a Dockerfile.

Held by rendering with values unlike both the defaults and the greenfield output (`make build` →
`bin/legacy-daemon`) and asserting they reach both Dockerfiles — the defaults equal the greenfield
shape, so a coincidence-proof variant is the only honest way to test this.

Corollary held by the same suite: the archetype's `archetype.yaml` catalog may compose only
libraries whose prompts survive that table — which is how a *defaulted* vestigial prompt
(a suffix selector, a debug port nothing publishes) is caught, since a render can't observe one.

### E3 — Nothing but the platform layer (allowlist, not denylist)
The proof is that the set of paths the render **writes** is a subset of the platform servicing
layer, plus whatever extras that archetype declares (e.g. a `Tiltfile`). An allowlist rather
than a denylist of guessed scaffolding filenames: `writes ⊆ allowed` cannot be satisfied by a
language the oracle never heard of, it needs no per-language list to maintain, and its failure
message names the offending file. `prova.RenderResult.writes` is the authoritative input — the
render's own intended writes, independent of whatever was already on disk.

A consequence worth stating on its own: **the overlay writes nothing at the repo root except
dotfiles it owns.** A generated top-level `Dockerfile`, `Makefile` or `README.md` is project
scaffolding by another name, and in a retrofit it lands next to (or instead of) the app's own.

### E4 — Retrofit is additive
Rendered over a directory that already holds an application, the overlay must add its platform
layer and **change nothing that was already there**. Proof: seed a fake legacy project, render
into it, diff the tree.

This splits in two, and only one half is the archetype's to satisfy:

- **The application's project files** (`README.md`, `Dockerfile`, `Makefile`, its source tree)
  must survive. That is E3's containment restated on a dirty tree — a property of the archetype,
  held as a full proof.
- **The application's hygiene files** (`.gitignore`, `.editorconfig`, `.gitattributes`) should
  survive too: its ignores and formatting rules outrank ours. But whether they do is the *render
  engine's* overwrite policy, not the archetype's — and **the two engines disagree.** Measured
  2026-07-27 (archetect 3.4.0, prova 0.11.0): the archetect CLI skips a path that already exists,
  so a real retrofit preserves them; prova's in-process engine overwrites every path it writes,
  so a proof run through it sees them replaced. Held as an open **spec** until the engines agree,
  or until the `gitignore`/`editor-config` libraries merge into an existing file rather than
  replacing it. Do not "fix" this by weakening the assertion — the standard is right, the
  measurement path is what is missing.

The same divergence is why E3's containment matters independently: under prova's engine, anything
the overlay writes *would* clobber, so keeping its writes inside the platform layer is the actual
safety property.

### E5 — The CI/CD wiring agrees with itself
The seam that actually breaks a first deploy is cross-artifact disagreement, so the identity is
asserted **across** artifacts, not within one:

- `build.yaml`'s `IMAGE_NAME` and `APPLICATION_NAME` == the application name
- the `docker-buildx-build-publish` step's `dockerfile-path` names a Dockerfile that the render
  actually produced
- the manifest-dispatch step's `directory-name` == the application name (this is the path CD
  writes into in the manifests repo)
- `PlatformApplication.spec.deployment.image` == `{registry}/{solution}/{application}:latest`
- the dev overlay's kustomize image rename targets that same repository
- `promote.yaml` (added 2026-08-31) dispatches over the manual promotion environments — stg and
  prd, dev being automatic on merge — and its `release-promote-to-environment` step promotes the
  same `IMAGE_NAME`/`APPLICATION_NAME` that `build.yaml` published; a mismatch is a promotion
  that runs green and updates a manifest directory CD never populated
- the build's release attaches `digest.txt` — the artifact name
  `release-promote-to-environment` downloads when a tag is promoted, so a build that renames or
  drops it leaves every tag it cut unpromotable

**Closed on golang (2026-07-27).** golang used to be the exception here: `golang-ci-library`'s
`build.yaml` stopped at `go build` / `go test` — no `env:` block, no image publish, no release, no
manifest dispatch — so the three assertions above had nothing to be consistent *with*, and they
were authored as specs. The blocker was that **no `p6m-actions/golang-*` action existed at all**,
which is why the library ran community actions.

The three were built and released (`golang-setup`, `golang-build`, `golang-cut-tag`, all `@v1`) and
`golang-ci-library` now renders the same publish → release → dispatch tail as rust and dotnet, so
the specs graduated to proofs. Two things about golang stayed different, and both are load-bearing:

- **`golang-cut-tag` is tag-driven, not manifest-driven.** Every other ecosystem's cut-tag rewrites
  a version field (`Cargo.toml`, `package.json`, the `.csproj`, the `pom`); a Go module has none —
  `go.mod` states the module path and language version, never the module's own version. For Go the
  git tag *is* the version. So it bumps nothing and commits nothing, and its version-line file is
  optional, which is what lets it run on a legacy repository that has no version file to add.
- **The rendered checkout needs `fetch-depth: 0`**, since the tags are the version history. rust
  reads `Cargo.toml` and needs no history, which is why its workflow omits this.

The codegen steps also moved out of the rendered workflow and into `golang-build`, per S10: a script
CI invokes may not depend on untracked generated files, and having them in the workflow made every
consumer re-declare them.

### E6 — The platform manifests are correct for the answers
`PlatformApplication` parses and carries: the protocol's port key (`SERVER_PORT` xor
`GRPC_PORT`) at the service port, `MANAGEMENT_PORT`, `LOGGING_STRUCTURED: "true"`, a readiness
probe on the management port, both ports declared with the right protocol, and
`resourceRequirements` exactly matching the selected persistence/cache/messaging. Every
environment overlay parses and namespaces `{solution}-{application}-{env}`.

### E7 — Suite and CI hygiene
As S9, for these repos: `[run] proofs = [...]`, the `p6m` plugin declared and pinned to a
released tag, `.last-failed.json` gitignored, `acceptance.yaml` on `prova-rs/run-action@v1`, and
no language toolchain step in that workflow — an overlay suite renders and inspects, so a
runner needs nothing but prova.

**Tracking `run-action@v1` is the rule, not a default to override.** The step carries no local
`version:`: the engine version lives in the action, which is bumped on every prova release, so
tracking the tag is what keeps a suite on the engine the fleet runs. A local pin freezes it while
looking up to date — measured, these six sat on v0.11.0 across three engine releases while
`run-action@v1` already served v0.14.0. Held by a proof (v1.10+), which is why S9's contradicting
line was corrected rather than the workflows.

## 3. The plugin: `prova-p6m-standards` (require name `p6m`)

Everything is **parameterized by the same answers given to the archetype** — expectations are a
pure function of the answer key, never of the language:

```lua
local p6m = require("p6m")

local id = p6m.identity{ prefix = "User Details", suffix = "Service",
                         org = "acme", solution = "platform" }
-- id.PrefixName == "UserDetails", id.project_name == "user-details-service", ...

local sut = p6m.sut{ dir = rendered.path, transport = "grpc", id = id,
                     db = postgres.container(ctx) }   -- docker.build .platform/docker/local,
                                                      -- runs on the topology network, env per S3

p6m.standards.api(t, sut, id)      -- S2: reflection/route/introspection surface == expected,
                                   --     then the SAME semantic CRUD script over the transport
p6m.standards.runtime(t, sut, id)  -- S3-S7: env honored, logs, health, metrics, traces
```

- `p6m.identity(answers)` — the casing oracle (single source of truth; tested against both name
  shapes).
- `p6m.api.{grpc,rest,graphql}_surface(id)` — expected descriptors; asserted via gRPC
  reflection, HTTP probing, GraphQL introspection against the live container.
- `p6m.sut{}` — the containerized-SUT fixture (build → network → boot → wait on readiness),
  built on prova's topology network + `docker.build` primitives.
- `p6m.standards.*` — the shared suites (api, runtime, docker, hygiene) each archetype's thin
  proof file invokes per variant (transport × persistence × name-shape).
- `p6m.empty.*` — the overlay layer (E1–E7): `p6m.empty.spec{}` is the tactical-answer oracle,
  `p6m.empty.render` the shared render fixture, and `p6m.empty.standards.*` the suites the six
  `*-service-empty-archetype` repos invoke. Same discipline: expectations are a pure function of
  the answer key, so a language's overlay is held to the identical bar.

```lua
local p6m = require("p6m")

local overlay = p6m.empty.spec{
  language = "rust", application = "Example Service", solution = "acme-platform",
  registry = "ghcr.io/acme", persistence = "PostgreSQL", extras = { "Tiltfile" },
}
local project = p6m.empty.render(overlay)

prova.group(overlay.label, function(g)
  p6m.empty.standards.rendering(g, project, overlay)   -- E3–E6: a function of one answer set
end)

prova.group("rust-empty overlay: the archetype itself", function(g)
  p6m.empty.standards.archetype(g, overlay)            -- E2, E7: properties of the repo
end)
```
- **Cross-language meta-proof (this repo's own suite):** render *N languages* of the same
  transport with the same answers and diff the reflected API surfaces against each other — the
  literal "indistinguishable" proof, held here so it can't drift per-repo.

Consumption (each archetype repo):

```toml
[plugins]
p6m = { git = "https://github.com/p6m-archetypes/prova-p6m-standards", tag = "v1" }
```

## 4. Retrofit plan (PDD, repo by repo)

- **Phase 0 — decisions** (DECIDE-1/2/3 above, plus: does java adopt the full contract as-is;
  fate of the YP6M-3006 pytest-harness branch on python-basic).
- **Phase 1 — plugin + reference archetype.** Implement `p6m.identity` + `api` oracles +
  containerized `sut`; wire into **dotnet-rest** (most advanced today: only repo with a
  container-SUT proof) until green. The suite is the spec; red is the gap list.
- **Phase 2 — sweep by axis, not by repo.** Hygiene first (proofs key, pins, .dockerignore,
  gitignore — mechanical, all 30 repos in one pass). Then per language: transports red→green
  against the standards suite. golang and rust start from zero suites — they get the thin
  standard proof file directly, no legacy to migrate.
- **Phase 3 — basic/empty + CI parity.** basic: runtime standards only (S3-S8, stub `GET /`
  identity route). empty: E1–E7 (§2b) — **done 2026-07-27**: all six overlays hold the shared
  `p6m.empty` suites; the three hand-rolled suites (java/python/typescript) that had drifted onto
  a removed `yaml.parse` API are replaced by it, and rust/golang/dotnet gain suites from zero.
  ci-libraries: bring golang/java/rust to the full docker+CD pipeline; golang onto `p6m-actions`.
- **Phase 4 — platform manifests.** livenessProbe added; contract keys asserted against
  `p6m.identity` from the same suite.

<!-- claim: retrofit-toolchain-answered recorded=2026-09-03 -->
The toolchain version is answered or read from the app, never assumed — E1b generalized off the container build onto CI. Measured 2026-09-03 on the first external retrofit tests: dotnet-service-empty pinned .NET 9 against a .NET 10 app (Maks, max-dotnet-app); js-pnpm-setup@v1 installed Node 18 under a Next.js 16 app that requires >=20.9, so lint/test/build all die instantly (Jose, jose-next-app); pnpm >=10 refused esbuild postinstall scripts the app never allowlisted (max-ts-app, ERR_PNPM_IGNORED_BUILDS). The bar: setup actions honor the repo's own declarations (global.json / TargetFramework, .nvmrc / engines / packageManager, pnpm.onlyBuiltDependencies) with the archetype's default only as fallback, and the overlay renders the version answer into both CI and Dockerfiles from one source.

<!-- backlog: cut-tag-runs-on-legacy recorded=2026-09-03 -->
Every language's version machinery runs on a repository the archetype did not scaffold. golang-cut-tag already holds the shape (tag-driven; its version file is optional — E5 records why). dotnet-cut-tag hard-fails on a missing Directory.Build.props ('not found at Directory.Build.props', measured 2026-09-03 on max-dotnet-app) — and Directory.Build.props is OUR convention, not a .NET given, so every brownfield dotnet retrofit's main build dies at the cut-patch step. The bar: cut-tag actions fall back to tag-driven versioning when the conventional version file is absent, in every language whose file is convention rather than ecosystem-mandatory.

<!-- claim: ci-single-trigger recorded=2026-09-03 -->
A rendered build workflow runs ONCE per change: today build.yaml triggers on push branches:[**] AND pull_request, so every PR from an in-repo branch builds twice (reported by Maks 2026-09-03). Decide the shape (push:[main] + pull_request is the platform norm; direct-to-main pushes and PR heads each build exactly once) and hold it across all six ci-libraries with an E5-style assertion on the trigger block.

<!-- claim: cut-tags-are-promotable recorded=2026-09-03 -->
Any tag the machinery cuts is promotable: promote replays digest.txt from the GitHub release named by the tag, and a tag-cutting path with no release/digest mints unpromotable versions (the retired cut-tag.yaml did exactly that — Maks, 2026-09-03). DECIDED 2026-09-03: the version level is an INPUT of the one pipeline rather than a second workflow with its own tail — build.yaml's workflow_dispatch carries version-level (patch|minor|major, default patch), the cut step wires it, and a manual minor/major is the identical run every merge produces (cut → build → image → release with digest.txt → dev dispatch), promotable by construction. cut-tag.yaml is retired from renders and from the E3 platform layer, so a render that still ships it fails containment. The GitHub Release stays deliberately: it is the promotion ledger — a content-pinned digest (registry tags are mutable), a credential-minimal promote (no registry creds in the promote job), and the audit trail promotions append to.

<!-- backlog: retrofit-health-not-assumed recorded=2026-09-03 -->
The overlay must not make the platform probe an endpoint the application does not serve: manifests wire readiness to /health/readiness on MANAGEMENT_PORT, but a legacy app has no management server (Maks's test app deployed and sat unready, 2026-09-03; his fix commit was 'fix readiness'). Decide the retrofit posture — a health answer (endpoint+port, defaulted to the platform contract), a generated sidecar/shim, or documented app-side adoption as a retrofit prerequisite — and hold E6 to whichever is chosen so a mismatch fails the suite, not the first deploy.

<!-- claim: rendered-actions-resolve recorded=2026-09-03 -->
Every action reference a ci-library renders must resolve: promote.yaml shipped fleet-wide calling p6m-actions/release-promote-to-environment@v1 while that repo had ZERO tags — every promotion failed at action resolution (Maks, 2026-09-03; fixed by releasing the action). The bar: for each uses: in every rendered workflow, the referenced repo has the referenced tag AND is visible to an UNAUTHENTICATED consumer — rendered projects run in customer orgs holding no p6m credentials, so a repo that resolves only with our credentials is equally broken for the fleet (the same incident's second face: release-promote-to-environment sat `internal` while every sibling action was public, and dev machines' ambient credentials hid it). Held by an unauthenticated ls-remote per unique org-owned ref, wherever github.com is reachable; a suite that only checks the @pin's SPELLING passes against a tag that does not exist.

<!-- claim: overlay-dockerignore recorded=2026-09-03 -->
The overlay renders a .dockerignore beside its Dockerfiles: both say COPY . ., so a retrofit of a real app drags its working tree into the build context — node_modules for typescript (reported by Maks 2026-09-03 on max-ts-app PR #2), target/ for rust, bin/obj for dotnet, __pycache__/.venv for python, vendor for golang, target for java — plus .git in every language. The greenfield archetypes render one in 18 content trees (S8); the six overlays render none, and E3's PLATFORM_LAYER does not even allow one. The bar: .dockerignore joins the platform layer with per-language entries, and an E-test asserts the ignores cover the language's dependency/build trees and .git.
