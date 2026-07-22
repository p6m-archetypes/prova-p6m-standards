# p6m Service Standards — the executable bar

This document is the spec the `p6m` prova plugin turns into proofs. Every p6m service archetype
(6 languages × {grpc, rest, graphql, basic, empty}) must render services that pass the same
parameterized suite. The goal: **12-factor services that are nearly indistinguishable from each
other at runtime** — same API for the same inputs, same logging, same health surface, same
metrics/traces, same container story.

Source of truth for the platform contract is `platform-application-manifests-library` (what the
platform actually probes and injects), plus the survey of all 80 repos on 2026-07-22 (summarized
in the matrix below).

## 1. The current drift (why this exists)

Survey highlights, per axis — every one of these is a proof in the suite:

| Axis | State on dev (2026-07-22) |
|---|---|
| CRUD | dotnet + typescript + python(grpc): full 5 ops. rust grpc: no Delete. rust rest: List only. rust graphql: no update/delete. golang: Create/Get/List only — and grpc/graphql APIs are **not even mounted** (commented-out TODO). java: **health-only on all three transports**; java-rest has zero routes. |
| API naming | REST: dotnet/python/typescript hard-code `Item`/`/api/items` (service name never reaches the API); golang uses `/api/v1/{prefix_name}s`; rust uses `/{prefix-name}s`. gRPC rpc names: `Create{PrefixName}` everywhere it exists, but service naming and versioning differ (`package {prefix}_{suffix}` vs `{prefix}.{suffix}.v1`). GraphQL: typescript/dotnet name the type `{PrefixName}{SuffixName}`, rust/python/golang use `{PrefixName}`; typescript keeps `get`/`list` prefixes, dotnet (HotChocolate) strips `get`. |
| Env contract | Manifests inject `SERVER_PORT`/`GRPC_PORT`, `MANAGEMENT_PORT`, `LOGGING_STRUCTURED=true`. golang binds `PORT` (not SERVER_PORT). rust binds `APP_SERVER__PORT` (figment prefix — ignores the platform's vars entirely). java grpc collapses the management server onto the service port. |
| Structured logging | Honored by dotnet/golang/java/python/rust; **typescript defines `LOGGING_STRUCTURED` but never reads it** (pino always JSON). Default off in python. |
| Health | `/health/readiness` + `/health/liveness` on the management port everywhere — the one converged axis. But manifests wire **only readinessProbe**; liveness is implemented and never probed. Readiness is a static `ok` in most (rust grpc has a real gate). |
| Metrics | Real Prometheus output in five languages; **rust `/metrics` is a stub string**. |
| Traces | OTel fail-open in dotnet/python/rust/typescript; java disabled-by-default; **golang pins the OTel deps and never initializes them**. |
| Docker | `.platform/docker/{local,prd}/Dockerfile` is the convention in all 30 service archetypes. But: **no `.dockerignore` anywhere** (+ `COPY . .`); local==prd byte-identical in java/python/rust; golang templates `COPY go.sum` with no go.sum (clean build fails); java Dockerfiles call a `./mvnw` that is never rendered; only dotnet-rest's suite ever builds an image. |
| Prova | golang + rust: **no suites at all**. Everywhere else: `[run] paths = ["tests"]` — a key prova ≥0.7 does not read (dead config); plugins pinned `@main`. dotnet-graphql has a tracked `.last-failed.json` showing red. python-basic has an in-flight branch **replacing prova with the legacy pytest harness** (YP6M-3006 — needs an org decision before the sweep). |
| CI | Rendered-project CI: dotnet/python/typescript get build→docker→push→manifest-dispatch; **golang/java/rust build only** (no image, no CD). golang uses community actions instead of `p6m-actions/*`. |

## 2. The standard

### S1 — Identity and casing
One answer set drives every rendering:
`org_name`, `solution_name`, `prefix_name`, `suffix_name` (default `Service`), ports, resource
selections. From `prefix_name` + `suffix_name` the casing set is fixed:
PascalCase (`UserDetails`), snake (`user_details`), kebab `project-name`
(`user-details-service`). The suite always runs **two name shapes**: a single word
(`Customer`) and a multi-word (`User Details`) — casing bugs only show on the second.

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
With it unset: human-readable. The flag must be *read* (catches typescript's dead field).

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

### S9 — Suite and CI hygiene
`prova.toml` uses `[run] proofs = [...]` (prova ≥0.7), plugins pinned to released tags
(`prova-rs/prova-postgres@v1` etc. — released 2026-07-22), `acceptance.yaml` on
`run-action@v1`, `.last-failed.json` gitignored. Rendered-project CI: all six languages get the
full build→docker→push→manifest-dispatch pipeline on `p6m-actions/*` (golang/java/rust
currently stop at build; golang uses community actions).

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
  identity route). empty: render-verify only. ci-libraries: bring golang/java/rust to the full
  docker+CD pipeline; golang onto `p6m-actions`.
- **Phase 4 — platform manifests.** livenessProbe added; contract keys asserted against
  `p6m.identity` from the same suite.
