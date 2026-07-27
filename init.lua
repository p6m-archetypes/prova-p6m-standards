-- prova-p6m-standards — p6m platform standards as executable proofs.
--
-- One parameterized suite every p6m service archetype must pass, so that services rendered from
-- the same answers are indistinguishable at the API and at runtime, regardless of language. The
-- spec is docs/standards.md (S1–S10); this module is its oracle: every expectation is a pure
-- function of the ANSWER KEY given to the archetype — never of the language.
--
--   local p6m = require("p6m")
--   local id  = p6m.identity{ prefix = "User Details", suffix = "Service" }
--   id.PrefixName        -- "UserDetails"
--   p6m.api.rest_surface(id).base   -- "/api/v1/user-detailss"
--
-- Layered so the hermetic core (identity + api surfaces) needs nothing but Lua; the live layers
-- (sut fixture, standards suites) come in on top and need only Docker.

local p6m = {}

-- ── S1: identity — the casing oracle ────────────────────────────────────────────────────────────

--- Split a human name into lowercase word tokens. Accepts any of the shapes a prompt answer or a
--- derived key can arrive in: "User Details", "user-details", "user_details", "UserDetails".
local function tokens(s)
  s = tostring(s)
  local words = {}
  -- Separate camel humps first so "UserDetails" tokenizes like "User Details".
  s = s:gsub("(%l)(%u)", "%1 %2")
  for w in s:gmatch("%w+") do
    words[#words + 1] = w:lower()
  end
  return words
end

local function cap(w)
  return (w:gsub("^%l", string.upper))
end

local function pascal(ws)
  local out = {}
  for _, w in ipairs(ws) do
    out[#out + 1] = cap(w)
  end
  return table.concat(out)
end

local function camel(ws)
  local p = pascal(ws)
  return (p:gsub("^%u", string.lower))
end

local function joined(ws, sep)
  return table.concat(ws, sep)
end

--- The full identity derived from an answer key: every cased variant the standards reference.
--- `spec.prefix` is required; `spec.suffix` defaults to "Service" (the archetypes' default).
---@param spec { prefix: string, suffix: string?, org: string?, solution: string? }
function p6m.identity(spec)
  assert(type(spec) == "table" and spec.prefix, "p6m.identity requires { prefix = ... }")
  local pre, suf = tokens(spec.prefix), tokens(spec.suffix or "Service")

  local id = {
    -- the raw answers, echoed for round-tripping into archetect renders
    answers = { prefix_name = spec.prefix, suffix_name = spec.suffix or "Service" },

    PrefixName = pascal(pre),
    SuffixName = pascal(suf),
    prefix_name = joined(pre, "_"),
    suffix_name = joined(suf, "_"),
    prefixName = camel(pre),

    -- kebab forms; project_name is `<prefix>-<suffix>` — the repo/dir/image/OTel name
    prefix_kebab = joined(pre, "-"),
    suffix_kebab = joined(suf, "-"),
  }
  id.PascalFull = id.PrefixName .. id.SuffixName
  id.snake_full = id.prefix_name .. "_" .. id.suffix_name
  id.project_name = id.prefix_kebab .. "-" .. id.suffix_kebab

  if spec.org and spec.solution then
    id.org_solution = joined(tokens(spec.org), "-") .. "-" .. joined(tokens(spec.solution), "-")
  end
  return id
end

-- ── S2: the API surfaces — expectations per transport ───────────────────────────────────────────

p6m.api = {}

--- Expected gRPC surface: flat package `{prefix}_{suffix}`, service `{PrefixName}{SuffixName}`,
--- full CRUD rpcs named from the entity (`{PrefixName}`), naive-plural List. `messages` pins the
--- request/response shapes — the drift the survey found lives there as much as in rpc names.
function p6m.api.grpc_surface(id)
  local P = id.PrefixName
  return {
    package = id.snake_full,
    service = id.PascalFull,
    -- fully-qualified name as reflection reports it
    full_service = id.snake_full .. "." .. id.PascalFull,
    rpcs = {
      "Create" .. P,
      "Get" .. P,
      "List" .. P .. "s",
      "Update" .. P,
      "Delete" .. P,
    },
    messages = {
      entity = { name = P, fields = { "id", "display_name" } },
      create_request = { name = "Create" .. P .. "Request", fields = { "display_name" } },
      get_request = { name = "Get" .. P .. "Request", fields = { "id" } },
      list_request = { name = "List" .. P .. "sRequest", fields = {} },
      list_response = { name = "List" .. P .. "sResponse", fields = { "items" } },
      update_request = { name = "Update" .. P .. "Request", fields = { "id", "display_name" } },
      delete_request = { name = "Delete" .. P .. "Request", fields = { "id" } },
      delete_response = { name = "Delete" .. P .. "Response", fields = {} },
    },
    entity = P,
    entity_fields = { "id", "display_name" },
  }
end

--- Expected REST surface: `/api/v1/{prefix-name}s`, five routes with standard status semantics.
function p6m.api.rest_surface(id)
  local base = "/api/v1/" .. id.prefix_kebab .. "s"
  return {
    base = base,
    routes = {
      { method = "POST", path = base, status = 201 },
      { method = "GET", path = base, status = 200 },
      { method = "GET", path = base .. "/{id}", status = 200 },
      { method = "PUT", path = base .. "/{id}", status = 200 },
      { method = "DELETE", path = base .. "/{id}", status = 204 },
    },
    entity_fields = { "id", "display_name" },
  }
end

--- Expected GraphQL surface: entity-named type `{PrefixName}`, prefix-free query fields,
--- create/update/delete mutations. Served at /graphql on the service port.
function p6m.api.graphql_surface(id)
  local P, c = id.PrefixName, id.prefixName
  return {
    type_name = P,
    queries = { c, c .. "s" },
    mutations = { "create" .. P, "update" .. P, "delete" .. P },
    entity_fields = { "id", "displayName" }, -- GraphQL surfaces camelCase at the boundary
  }
end

-- ── S3: the environment contract (what the platform manifests inject) ───────────────────────────

--- The env var NAMES every service must honor, per transport, with the values the caller chooses
--- merged in. The sut fixture boots with shifted port values to prove the service reads them.
function p6m.env_contract(id, transport, values)
  local env = {
    LOGGING_STRUCTURED = "true",
    OTEL_SERVICE_NAME = id.project_name,
  }
  env[transport == "grpc" and "GRPC_PORT" or "SERVER_PORT"] = nil -- named by the contract; value from caller
  for k, v in pairs(values or {}) do
    env[k] = v
  end
  return env
end

-- ── S8: the containerized SUT ───────────────────────────────────────────────────────────────────

-- In-container ports. Deliberately NOT the render defaults (8080/8081): the service only becomes
-- reachable if it actually READS the injected env (S3) — a service that ignores SERVER_PORT and
-- listens on its baked default never answers readiness, and that is the proof.
p6m.SERVICE_PORT = 18080
p6m.MANAGEMENT_PORT = 18081

--- Build a rendered service's own Dockerfile — the PRODUCTION one by default, because that is
--- the artifact CI publishes and the platform deploys; proving `local` only proves the dev inner
--- loop — and boot it as a container on the topology network, wired per the platform env
--- contract. Call INSIDE a `prova.topology` factory (it uses `ctx.network` implicitly via the
--- resource layer). `spec.dockerfile` overrides (e.g. ".platform/docker/local/Dockerfile").
---
--- Ordering matters cold: the image is built FIRST, before any resource with a readiness clock is
--- provisioned — a cold image build can saturate the machine long enough to blow a sibling DB's
--- readiness deadline.
---
---@param ctx any prova context (inside a topology factory)
---@param spec { root: string, id: table, transport: "grpc"|"rest"|"graphql",
---              db: table?, env: table<string,string>?, timeout: string? }
---   `root`: the rendered project directory (holding .platform/docker/). `db`: a resource recipe
---   namespace (e.g. `require("postgres")`) — provisioned here, after the build, auto-joining the
---   network. `env`: extra vars merged over the contract.
function p6m.sut(ctx, spec)
  local id, transport = spec.id, spec.transport
  local port_key = transport == "grpc" and "GRPC_PORT" or "SERVER_PORT"

  local image = docker.build{
    context = spec.root,
    dockerfile = spec.dockerfile or ".platform/docker/prd/Dockerfile",
  }

  -- Alias the DB uniquely per SUT: concurrent topologies otherwise share the recipe's default
  -- alias ("postgres"), and DNS on interleaved networks can hand one SUT its sibling's database.
  local db = spec.db and spec.db.container(ctx, { alias = id.project_name .. "-db" }) or nil

  local env = p6m.env_contract(id, transport, {
    [port_key] = tostring(p6m.SERVICE_PORT),
    MANAGEMENT_PORT = tostring(p6m.MANAGEMENT_PORT),
  })
  if db then
    env.DB_HOST = db.network.host
    env.DB_PORT = tostring(db.network.port)
    env.DB_USERNAME = "prova"
    env.DB_PASSWORD = "prova"
    env.DB_DBNAME = "prova"
  end
  for k, v in pairs(spec.env or {}) do
    env[k] = v
  end

  local app = prova.containerized{
    name = id.project_name,
    image = image,
    ports = { p6m.SERVICE_PORT, p6m.MANAGEMENT_PORT },
    env = env,
    timeout = spec.timeout or "120s",
    url = function(hp)
      return (transport == "grpc" and "" or "http://") .. "127.0.0.1:" .. hp
    end,
  }.container(ctx)

  local mgmt_port = app.container:host_port(p6m.MANAGEMENT_PORT)
  local management_url = "http://127.0.0.1:" .. mgmt_port

  -- Readiness on the MANAGEMENT port (S5) — reachable only if MANAGEMENT_PORT was honored (S3).
  http.wait_for(management_url .. "/health/readiness", { timeout = spec.timeout or "120s" })

  -- S4's other half: the flag must be READ, not merely defined. Boot a sibling from the SAME
  -- image with LOGGING_STRUCTURED=false and keep its logs — a service that is always-JSON
  -- regardless of the flag fails the runtime suite's plain-mode assertion. Skippable via
  -- `check_logging_toggle = false` for callers that only need the primary SUT.
  local plain_logs
  if spec.check_logging_toggle ~= false then
    local plain_env = {}
    for k, v in pairs(env) do
      plain_env[k] = v
    end
    plain_env.LOGGING_STRUCTURED = "false"
    local plain = prova.containerized{
      name = id.project_name .. "-plainlog",
      image = image,
      ports = { p6m.SERVICE_PORT, p6m.MANAGEMENT_PORT },
      env = plain_env,
      timeout = spec.timeout or "120s",
      url = function(hp)
        return "http://127.0.0.1:" .. hp
      end,
    }.container(ctx)
    http.wait_for(
      "http://127.0.0.1:" .. plain.container:host_port(p6m.MANAGEMENT_PORT) .. "/health/readiness",
      { timeout = spec.timeout or "120s" }
    )
    -- Async log transports (e.g. pino-pretty's worker thread) can lag readiness: give plain-mode
    -- output a bounded window to flush a non-JSON line before snapshotting. If none ever appears,
    -- keep the final snapshot — the runtime suite makes the actual judgment (and fails honestly).
    local function has_non_json(logs)
      for line in logs:gmatch("[^\r\n]+") do
        local ok, v = pcall(prova.parse.json, line)
        if not (ok and type(v) == "table") then return true end
      end
      return false
    end
    plain_logs = plain.container:logs()
    if not has_non_json(plain_logs) then
      pcall(prova.retry, function()
        plain_logs = plain.container:logs()
        assert(has_non_json(plain_logs), "no non-JSON plain-mode line flushed yet")
      end, { timeout = "10s", every = "500ms" })
    end
  end

  local api
  if transport == "rest" then
    api = http.client{ base_url = app.url }
  elseif transport == "grpc" then
    api = grpc.client(app.url)
  elseif transport == "graphql" then
    api = graphql.client{ url = app.url .. "/graphql" }
  else
    error("p6m.sut: unknown transport " .. tostring(transport))
  end

  return {
    id = id,
    transport = transport,
    api = api,
    management = http.client{ base_url = management_url },
    db = db,
    container = app.container,
    service_url = app.url,
    management_url = management_url,
    plain_logs = plain_logs,
  }
end

-- ── The one CRUD script, per transport ──────────────────────────────────────────────────────────
-- Normalized operations so S2 is ONE semantic script everywhere. Each returns
-- `{ status_ok: boolean, not_found: boolean?, id: string?, display_name: string? }`.

local drivers = {}

drivers.rest = function(sut)
  local surface = p6m.api.rest_surface(sut.id)
  local base = surface.base
  local function norm(res, expect_status)
    local ok = res.status == expect_status
    local body = ok and res.status ~= 204 and res:json() or nil
    return {
      status_ok = ok,
      not_found = res.status == 404,
      id = body and body.id,
      display_name = body and body.displayName,
      items = body and body.items or body, -- list endpoints: bare array or { items = [...] }
    }
  end
  return {
    create = function(name) return norm(sut.api:post(base, { json = { displayName = name } }), 201) end,
    get = function(rid) return norm(sut.api:get(base .. "/" .. rid), 200) end,
    list = function() return norm(sut.api:get(base), 200) end,
    update = function(rid, name)
      return norm(sut.api:put(base .. "/" .. rid, { json = { displayName = name } }), 200)
    end,
    delete = function(rid) return norm(sut.api:delete(base .. "/" .. rid), 204) end,
    get_missing = function(rid) return norm(sut.api:get(base .. "/" .. rid), 200) end,
  }
end

drivers.grpc = function(sut)
  local surface = p6m.api.grpc_surface(sut.id)
  local S = surface.full_service
  local function norm(st)
    local e = st.response
    -- entity may be the response itself or nested (List); callers pick fields they need
    return {
      status_ok = st.ok,
      not_found = st.code == "NotFound",
      id = e and e.id,
      display_name = e and e.display_name,
      items = e and e.items,
    }
  end
  local rpc = surface.rpcs -- Create, Get, List, Update, Delete in order
  return {
    create = function(name) return norm(sut.api:call_status(S .. "/" .. rpc[1], { display_name = name })) end,
    get = function(rid) return norm(sut.api:call_status(S .. "/" .. rpc[2], { id = rid })) end,
    list = function() return norm(sut.api:call_status(S .. "/" .. rpc[3], {})) end,
    update = function(rid, name)
      return norm(sut.api:call_status(S .. "/" .. rpc[4], { id = rid, display_name = name }))
    end,
    delete = function(rid) return norm(sut.api:call_status(S .. "/" .. rpc[5], { id = rid })) end,
    get_missing = function(rid) return norm(sut.api:call_status(S .. "/" .. rpc[2], { id = rid })) end,
  }
end

drivers.graphql = function(sut)
  local s = p6m.api.graphql_surface(sut.id)
  local one, many = s.queries[1], s.queries[2]
  local sel = "{ id displayName }"
  local function norm(res, field)
    local node = res.data and res.data[field]
    return {
      status_ok = res.errors == nil and node ~= nil,
      not_found = node == nil or node == false,
      id = type(node) == "table" and node.id or nil,
      display_name = type(node) == "table" and node.displayName or nil,
      items = type(node) == "table" and node[1] ~= nil and node or nil,
    }
  end
  return {
    create = function(name)
      return norm(sut.api:execute(
        "mutation($n: String!) { " .. s.mutations[1] .. "(displayName: $n) " .. sel .. " }",
        { n = name }), s.mutations[1])
    end,
    get = function(rid)
      return norm(sut.api:execute(
        "query($i: ID!) { " .. one .. "(id: $i) " .. sel .. " }", { i = rid }), one)
    end,
    list = function()
      return norm(sut.api:execute("query { " .. many .. " " .. sel .. " }"), many)
    end,
    update = function(rid, name)
      return norm(sut.api:execute(
        "mutation($i: ID!, $n: String!) { " .. s.mutations[2] .. "(id: $i, displayName: $n) " .. sel .. " }",
        { i = rid, n = name }), s.mutations[2])
    end,
    delete = function(rid)
      local res = sut.api:execute(
        "mutation($i: ID!) { " .. s.mutations[3] .. "(id: $i) }", { i = rid })
      return { status_ok = res.errors == nil and res.data and res.data[s.mutations[3]] ~= false }
    end,
    get_missing = function(rid)
      return norm(sut.api:execute(
        "query($i: ID!) { " .. one .. "(id: $i) " .. sel .. " }", { i = rid }), one)
    end,
  }
end

--- The transport driver for a booted sut — the normalized CRUD operations S2 asserts through.
function p6m.driver(sut)
  return assert(drivers[sut.transport], "no driver for " .. tostring(sut.transport))(sut)
end

-- ── S10: CI parity — the rendered project's own CI commands, from a clean render ────────────────

p6m.ci = {}

--- The command sequences the rendered projects' CI pipelines run (the `p6m-actions` setup +
--- build steps), per stack — mirrored HERE and nowhere else, so when an action changes this
--- table is the one place to follow. Conditional steps keep the action's own guard verbatim
--- (parity means failing exactly where CI would fail, skipping exactly where CI would skip).
--- Reporting-only flags (trx loggers, results directories) are dropped: they can't change
--- pass/fail, and S10 proves the command path, not the reporting.
p6m.ci.stacks = {
  -- js-pnpm-setup@v1 + js-pnpm-build@v1
  pnpm = {
    image = "node:22",
    commands = {
      "npm install -g pnpm",
      "pnpm install",
      [[if grep -q '"lint":' package.json; then pnpm lint; else echo "no lint script"; fi]],
      [[if grep -q '"test":' package.json; then pnpm test; else echo "no test script"; fi]],
      [[if grep -q '"build":' package.json; then pnpm build; else echo "no build script"; fi]],
    },
  },
  -- dotnet-setup@v1 + dotnet-build@v1 (Release, tests on — the rendered build.yaml's shape)
  dotnet = {
    image = "mcr.microsoft.com/dotnet/sdk:9.0",
    commands = {
      "dotnet restore . --verbosity minimal",
      "dotnet build . --configuration Release --no-restore --verbosity minimal",
      "dotnet test . --configuration Release --no-build --verbosity minimal",
    },
  },
  -- python-uv-setup@v1 + python-uv-build@v1 (uv preinstalled in the image — the setup action's
  -- curl-install, resolved). The repository-login step is credentialed and publish-facing; the
  -- always-run path proven here resolves from public PyPI, like a fresh contributor's clone.
  python = {
    image = "ghcr.io/astral-sh/uv:python3.12-bookworm",
    commands = {
      "uv sync",
      [[if grep -q '\[tool\.ruff\]' pyproject.toml; then uv run ruff check; else echo "no ruff config"; fi]],
      [[if grep -q '\[tool\.pytest\]' pyproject.toml || find . -name 'test_*.py' -o -name '*_test.py' | grep -q .; then uv run pytest; else echo "no tests"; fi]],
      "uv build",
    },
  },
  -- java-maven-setup@v1 + java-maven-build@v1, whose invocation the rendered build.yaml overrides
  -- to a bare verify (run-test "false", build-command "mvn verify --no-transfer-progress").
  java = {
    image = "maven:3-eclipse-temurin-21",
    commands = {
      "mvn verify --no-transfer-progress",
    },
  },
  -- Community actions today (S9: not yet on p6m-actions): setup-go pinned to the rendered
  -- go.mod line, then the workflow's two guarded codegen steps for code that is imported but
  -- never rendered (S10 golang catches) — protoc gen/ for gRPC BEFORE tidy (protoc is
  -- standalone, and tidy must see gen/), gqlgen for GraphQL AFTER tidy (it is a Go tool, so its
  -- dep must resolve first). tidy first materializes go.sum (a fresh render ships none). Plugin
  -- pins/commands match the Dockerfile and the ci-library workflow verbatim.
  golang = {
    image = "golang:1.23",
    commands = {
      "if [ -d proto ]; then apt-get update && apt-get install -y protobuf-compiler"
        .. " && go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.5"
        .. " && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1"
        .. " && mkdir -p gen && protoc -I proto"
        .. " --go_out=gen --go_opt=paths=source_relative"
        .. " --go-grpc_out=gen --go-grpc_opt=paths=source_relative"
        .. " $(find proto -name '*.proto'); fi",
      "go mod tidy",
      "if [ -f gqlgen.yml ]; then go run github.com/99designs/gqlgen generate && go mod tidy; fi",
      "go build ./...",
      "go test ./...",
    },
  },
  -- rust-setup@v1 + rust-build@v1 defaults (format-check, lint, test, build — all on), per the
  -- converged rust-ci-library#dev pipeline. protoc first: prost/tonic build scripts need it and
  -- neither rust-setup nor the runner image provides it (S10's rust catch — the workflow now
  -- installs it too; the image ships clippy/rustfmt with its stable toolchain).
  rust = {
    image = "rust:1",
    commands = {
      -- environment the runner's rust-setup provides: fmt/clippy components (the rust:1 image
      -- ships the bare toolchain) and protoc (S10's rust catch — nothing on the runner had it)
      "rustup component add rustfmt clippy",
      "apt-get update && apt-get install -y protobuf-compiler",
      "cargo fmt -- --check",
      "cargo clippy -- -D warnings",
      "cargo test",
      "cargo build",
    },
  },
}

--- The throwaway CI-parity Dockerfile for a stack: toolchain base, clean-render context, one
--- RUN per CI command — so `docker.build` success IS "the CI command sequence succeeds on a
--- fresh clone", and a failure names the exact command that broke, layer-cached up to it.
--- Pure text so the hermetic self-suite can hold it; `ci_parity` writes and builds it.
---
--- Pinned to `linux/amd64` because the p6m-actions runners are `ubuntu-latest` (amd64): the
--- proof must build the arch CI builds, or it is not parity. On an arm64 host amd64 runs under
--- emulation (slower, faithful); it also sidesteps arch-specific toolchain bugs that would
--- otherwise make the proof lie — e.g. Grpc.Tools ships an arm64 `protoc` that segfaults
--- (exit 139) where the amd64 binary CI uses is fine.
function p6m.ci.dockerfile(stack, opts)
  local lines = {
    "FROM --platform=linux/amd64 " .. ((opts and opts.image) or stack.image),
    "WORKDIR /ci",
    "COPY . .",
  }
  for _, cmd in ipairs(stack.commands) do
    lines[#lines + 1] = "RUN " .. cmd
  end
  return table.concat(lines, "\n") .. "\n"
end

-- ── E1–E7: the overlay ("empty") archetypes ─────────────────────────────────────────────────────
--
-- An overlay archetype retrofits an EXISTING application: it renders only the platform servicing
-- layer (CI/CD workflows, container builds, platform manifests, repo hygiene) IN PLACE at the
-- destination root, and never a line of project scaffolding. Nothing it emits can be booted, so
-- S2 and S4-S7 have no subject and S10 has no rendered project whose CI could run. What replaces
-- them is stricter containment (E3), a non-destructive retrofit (E4), and cross-artifact coherence
-- of the CI/CD wiring (E5) — the seams that actually break a legacy app's first deploy.
-- The spec is docs/standards.md §2b.

p6m.empty = {}

--- E3: the platform servicing layer — the COMPLETE set of paths an overlay may write. Held as an
--- ALLOWLIST rather than a denylist of guessed scaffolding names: `writes ⊆ allowed` cannot be
--- satisfied by a language the oracle never heard of, needs no per-language list to maintain, and
--- names the offending file when it fails. Archetypes declare anything extra they carry (e.g. a
--- Tiltfile) via `spec.extras` — declared, so it is a decision and not an accident.
p6m.empty.PLATFORM_LAYER = {
  -- repo hygiene (dotfiles only; E3's root rule). A legacy repo keeps its own — see E4.
  ".editorconfig",
  ".gitattributes",
  ".gitignore",
  -- CI
  ".github/workflows/build.yaml",
  ".github/workflows/cut-tag.yaml",
  -- container builds (the prd one is what CI publishes and the platform deploys)
  ".platform/docker/local/Dockerfile",
  ".platform/docker/prd/Dockerfile",
  -- CD: the platform manifests
  ".platform/kubernetes/base/application.yaml",
  ".platform/kubernetes/base/application_customizations.yaml",
  ".platform/kubernetes/base/kustomization.yaml",
  ".platform/kubernetes/dev/application_patch.yaml",
  ".platform/kubernetes/dev/kustomization.yaml",
  ".platform/kubernetes/dev/namespace.yaml",
  ".platform/kubernetes/stg/application_patch.yaml",
  ".platform/kubernetes/stg/kustomization.yaml",
  ".platform/kubernetes/stg/namespace.yaml",
  ".platform/kubernetes/prd/application_patch.yaml",
  ".platform/kubernetes/prd/kustomization.yaml",
  ".platform/kubernetes/prd/namespace.yaml",
}

--- The environments the manifests overlay, in the order the platform promotes through them.
p6m.empty.ENVIRONMENTS = { "dev", "stg", "prd" }

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

--- E1: the overlay answer key and everything derived from it. `application` is the ONLY name asked
--- — it is at once the image name, the PlatformApplication name, the CD manifest directory and the
--- Tilt resource; `solution` is the namespace prefix the platform operator reads the solution back
--- out of. Accepts any input shape ("Example Service", "example-service", "ExampleService").
---
--- Deliberately NOT here: prefix/suffix decomposition, org × solution split, author identity — a
--- service archetype needs those to name code it generates, and an overlay generates none.
---@param o { language: string, application: string, solution: string, registry: string,
---           protocol: string?, service_port: integer?, management_port: integer?,
---           persistence: string?, cache: string?, messaging: string?, messaging_access: string?,
---           extras: string[]? }
function p6m.empty.spec(o)
  assert(type(o) == "table" and o.application, "p6m.empty.spec requires { application = ... }")
  local app = tokens(o.application)
  local protocol = o.protocol or "REST"
  local service_port = o.service_port or (protocol == "gRPC" and 50051 or 8080)

  local s = {
    language = assert(o.language, "p6m.empty.spec requires { language = ... }"),
    application = joined(app, "-"),
    application_snake = joined(app, "_"),
    ApplicationName = pascal(app),
    solution = joined(tokens(assert(o.solution, "p6m.empty.spec requires { solution = ... }")), "-"),
    registry = assert(o.registry, "p6m.empty.spec requires { registry = ... }"),
    protocol = protocol,
    service_port = service_port,
    management_port = o.management_port or (service_port + 1),
    persistence = o.persistence or "None",
    cache = o.cache or "None",
    messaging = o.messaging or "None",
    messaging_access = o.messaging_access or "produce",
    extras = o.extras or {},
  }

  -- S3's contract, as the manifest must inject it for this transport
  s.port_env_key = protocol == "gRPC" and "GRPC_PORT" or "SERVER_PORT"
  s.port_protocol = protocol == "gRPC" and "grpc" or "http"
  s.image_repository = s.registry .. "/" .. s.solution .. "/" .. s.application
  s.image = s.image_repository .. ":latest"

  -- E2: the three facts with no sane default. Rendering with ONLY these and no defaults fallback
  -- must succeed — that is the whole prompt-surface proof.
  s.required_answers = {
    project_name = s.application,
    org_solution_name = s.solution,
    image_registry = s.registry,
  }

  -- The full key: the required facts plus the defaulted selections a variant exercises.
  s.answers = {
    project_name = s.application,
    org_solution_name = s.solution,
    image_registry = s.registry,
    protocol = s.protocol,
    service_port = s.service_port,
    management_port = s.management_port,
    persistence = s.persistence,
    cache = s.cache,
    messaging = s.messaging,
    messaging_access = s.messaging_access,
  }

  -- E3's allowlist for this archetype
  s.allowed = {}
  for _, f in ipairs(p6m.empty.PLATFORM_LAYER) do
    s.allowed[#s.allowed + 1] = f
  end
  for _, f in ipairs(s.extras) do
    s.allowed[#s.allowed + 1] = f
  end

  s.label = s.language .. "-empty[" .. s.application .. "/" .. s.protocol .. "/" .. s.persistence .. "]"
  return s
end

--- The namespace the manifests place the application in for an environment: `{solution}-{app}-{env}`
--- (E1 — the convention the platform operator derives solution + environment back out of).
function p6m.empty.namespace(s, env)
  return s.solution .. "-" .. s.application .. "-" .. env
end

--- The resourceRequirements the selected resources must produce, in manifest order (E6). Keyed by
--- resourceName because that is the handle the platform injects connection secrets under.
function p6m.empty.resource_requirements(s)
  local want = {}
  local db = ({ PostgreSQL = "postgresql", MySQL = "mysql" })[s.persistence]
  if db then
    want[#want + 1] = { resourceType = db, resourceName = "db" }
  end
  if s.cache == "Redis" then
    want[#want + 1] = { resourceType = "redis", resourceName = "cache" }
  end
  local bus = ({ Kafka = "kafka", Pulsar = "pulsar-topic" })[s.messaging]
  if bus then
    want[#want + 1] = {
      resourceType = bus,
      resourceName = "messaging",
      scope = "Shared",
      access = s.messaging_access,
    }
  end
  return want
end

--- The shared render fixture: one headless render of the overlay per spec, with `defaults = false`
--- so a prompt outside the tactical key errors instead of being papered over (E2). Scope.Suite by
--- default — the composed prompt libraries all resolve from git, and a suite's worth of renders
--- sharing one tree is both faster and what `[run] jobs = 1` already implies.
---@param s table a `p6m.empty.spec` result
---@param opts { source: string?, scope: any?, answers: table? }?
function p6m.empty.render(s, opts)
  opts = opts or {}
  return prova.fixture(s.label .. ":project", opts.scope or Scope.Suite, function(ctx)
    return archetect.render{
      source = opts.source or ".",
      answers = opts.answers or s.answers,
      destination = ctx:tempdir(),
      defaults = false,
    }
  end)
end

-- The paths a render intended to write, relative to its root and sorted — E3/E4's raw material.
-- `RenderResult.writes` is authoritative: it is what the overlay CLAIMS, independent of whatever
-- was already on disk (which is exactly the distinction E4 turns on).
local function written(rendering)
  local root, rel = rendering.path, {}
  for _, abs in ipairs(rendering.writes or {}) do
    rel[#rel + 1] = abs:sub(#root + 2)
  end
  table.sort(rel)
  return rel
end
p6m.empty.written = written

p6m.empty.standards = {}

--- E3: the render IS the platform servicing layer — all of it, and nothing else.
function p6m.empty.standards.layout(g, project, s)
  g:test("renders the platform servicing layer", function(t)
    local r = t:use(project)
    t:expect_all(function()
      for _, f in ipairs(s.allowed) do
        t:expect(fs.exists(r.path .. "/" .. f), f):is_true()
      end
    end)
  end)

  g:test("renders nothing but the platform servicing layer", {
    proves = "E3: an allowlist, so scaffolding in a language the oracle never heard of still fails",
  }, function(t)
    local allowed = set_of(s.allowed)
    t:expect_all(function()
      for _, f in ipairs(written(t:use(project))) do
        t:expect(allowed[f], f .. " is not part of the platform layer"):is_true()
      end
    end)
  end)

  g:test("writes nothing at the repo root but dotfiles and declared extras", {
    proves = "E3: a generated top-level Dockerfile/Makefile/README is scaffolding by another name,"
      .. " and in a retrofit it lands beside (or instead of) the app's own. A root file that is"
      .. " genuinely required by name (Tilt only reads ./Tiltfile) has to be DECLARED in extras —"
      .. " the point is that it is a visible decision and not an accretion",
  }, function(t)
    local declared = set_of(s.extras)
    t:expect_all(function()
      for _, f in ipairs(written(t:use(project))) do
        if not f:find("/") and not declared[f] then
          t:expect(f:sub(1, 1) == ".", "undeclared root-level " .. f):is_true()
        end
      end
    end)
  end)

  g:test("leaves no unrendered template markers", function(t)
    t:expect(t:use(project)):is_fully_rendered()
  end)
end

--- E6: the platform manifests say what the answers imply.
function p6m.empty.standards.manifests(g, project, s)
  local BASE = "/.platform/kubernetes/base/"

  g:test("PlatformApplication carries the platform env contract", function(t)
    local app = yaml.decode(fs.read(t:use(project).path .. BASE .. "application.yaml"))
    t:expect(app.apiVersion, "apiVersion"):equals("meta.p6m.dev/v1alpha1")
    t:expect(app.kind, "kind"):equals("PlatformApplication")
    t:expect(app.metadata.name, "metadata.name"):equals(s.application)
    t:expect(app.metadata.labels["p6m.dev/app"], "app label"):equals(s.application)

    -- S3, as the manifest must inject it: the transport's port key and nothing else's
    local other = s.port_env_key == "GRPC_PORT" and "SERVER_PORT" or "GRPC_PORT"
    t:expect(app.spec.config[s.port_env_key], s.port_env_key):equals(tostring(s.service_port))
    t:expect(app.spec.config[other], other .. " must not be injected for " .. s.protocol):is_nil()
    t:expect(app.spec.config.MANAGEMENT_PORT, "MANAGEMENT_PORT"):equals(tostring(s.management_port))
    t:expect(app.spec.config.LOGGING_STRUCTURED, "LOGGING_STRUCTURED"):equals("true")
  end)

  g:test("PlatformApplication deploys the derived image on both ports", function(t)
    local app = yaml.decode(fs.read(t:use(project).path .. BASE .. "application.yaml"))
    local d = app.spec.deployment
    t:expect(d.image, "image"):equals(s.image)

    local by_port = {}
    for _, p in ipairs(d.ports or {}) do
      by_port[p.port] = p.protocol
    end
    t:expect(by_port[s.service_port], "service port protocol"):equals(s.port_protocol)
    t:expect(by_port[s.management_port], "management port protocol"):equals("http")

    -- S5: readiness is probed on the management port, never the service port
    t:expect(d.readinessProbe.port, "readiness port"):equals(s.management_port)
    t:expect(d.readinessProbe.path, "readiness path"):equals("/health/readiness")
  end)

  g:test("resourceRequirements match the selected resources", function(t)
    local app = yaml.decode(fs.read(t:use(project).path .. BASE .. "application.yaml"))
    local want, got = p6m.empty.resource_requirements(s), app.spec.resourceRequirements or {}
    t:expect(#got, "requirement count"):equals(#want)
    t:expect_all(function()
      for i, w in ipairs(want) do
        local g_ = got[i] or {}
        t:expect(g_.resourceType, "requirement " .. i .. " type"):equals(w.resourceType)
        t:expect(g_.resourceName, "requirement " .. i .. " name"):equals(w.resourceName)
        if w.scope then
          t:expect(g_.scope, "requirement " .. i .. " scope"):equals(w.scope)
          t:expect(g_.access, "requirement " .. i .. " access"):equals(w.access)
        end
      end
    end)
  end)

  g:test("every environment overlay parses and is namespaced {solution}-{app}-{env}", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, env in ipairs(p6m.empty.ENVIRONMENTS) do
        local ns = p6m.empty.namespace(s, env)
        local dir = root .. "/.platform/kubernetes/" .. env .. "/"
        local kust = yaml.decode(fs.read(dir .. "kustomization.yaml"))
        t:expect(kust.kind, env .. " kustomization kind"):equals("Kustomization")
        t:expect(kust.namespace, env .. " kustomization namespace"):equals(ns)
        t:expect(yaml.decode(fs.read(dir .. "namespace.yaml")).metadata.name, env .. " Namespace"):equals(ns)
      end
    end)
  end)
end

--- E5: the CI/CD wiring agrees with itself. Every assertion here spans TWO artifacts — a first
--- deploy breaks on disagreement between them, never on either one read alone.
---
--- `opts.cd_spec` authors the three CD-dependent tests as open specs with that reason: a language
--- whose ci-library still stops at build has no publish step and no dispatch step for them to be
--- consistent WITH, and that is a gap in the ci-library, not a disagreement in the overlay.
---@param opts { cd_spec: string? }?
function p6m.empty.standards.cicd(g, project, s, opts)
  local cd_spec = opts and opts.cd_spec

  local function workflow(t)
    return yaml.decode(fs.read(t:use(project).path .. "/.github/workflows/build.yaml"))
  end

  -- Named steps are found by the action they use, so a renamed step never silently stops being
  -- checked (which a `name:` lookup would).
  local function step_using(steps, pattern)
    for _, step in ipairs(steps or {}) do
      if step.uses and step.uses:find(pattern) then
        return step
      end
    end
  end

  g:test("the build workflow is a valid workflow", function(t)
    local build = workflow(t)
    -- `on:` is the YAML 1.1 boolean `true` once decoded — pin the trigger by that key
    t:expect(build[true] or build["on"], "workflow triggers"):never():is_nil()
    t:expect(build.jobs and build.jobs.build, "a `build` job"):never():is_nil()
  end)

  g:test("the build workflow names the application as its image", { spec = cd_spec }, function(t)
    local env = workflow(t).env or {}
    t:expect(env.IMAGE_NAME, "IMAGE_NAME"):equals(s.application)
    t:expect(env.APPLICATION_NAME, "APPLICATION_NAME"):equals(s.application)
  end)

  g:test("the workflow's dockerfile-path names a Dockerfile the overlay rendered", {
    spec = cd_spec,
    proves = cd_spec == nil
      and "E5: the publish step and the container build are two artifacts; CD dies on the seam"
      or nil,
  }, function(t)
    local r = t:use(project)
    local publish = step_using(workflow(t).jobs.build.steps, "docker%-buildx%-build%-publish")
    t:expect(publish, "a docker-buildx-build-publish step"):never():is_nil()
    local path = publish["with"]["dockerfile-path"]
    t:expect(fs.exists(r.path .. "/" .. path), "dockerfile-path " .. path .. " exists"):is_true()
  end)

  g:test("the manifest-dispatch directory is the application name", {
    spec = cd_spec,
    proves = cd_spec == nil
      and "E5: directory-name is the path CD writes into in the manifests repo — a mismatch means"
        .. " the pipeline is green and the deployment never updates"
      or nil,
  }, function(t)
    local dispatch = step_using(
      workflow(t).jobs.build.steps, "platform%-application%-manifest%-dispatch"
    )
    t:expect(dispatch, "a platform-application-manifest-dispatch step"):never():is_nil()
    -- Both resolve through workflow env, which the sibling test pinned to the application name.
    t:expect(dispatch["with"]["directory-name"], "directory-name"):equals("${{ env.APPLICATION_NAME }}")
    t:expect(dispatch["with"]["image-name"], "image-name"):equals("${{ env.IMAGE_NAME }}")
  end)

  g:test("the dev overlay renames the same image repository the manifest deploys", function(t)
    local kust = yaml.decode(
      fs.read(t:use(project).path .. "/.platform/kubernetes/dev/kustomization.yaml")
    )
    local names = {}
    for _, img in ipairs(kust.images or {}) do
      names[img.name] = img
    end
    local dev = names[s.image_repository]
    t:expect(dev, "a kustomize image rename for " .. s.image_repository):never():is_nil()
    t:expect(dev.newName, "local image name"):equals(s.application)
  end)

  g:test("every workflow step is pinned to a version", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, wf in ipairs(fs.glob(root, ".github/workflows/*.yaml")) do
        local doc = yaml.decode(fs.read(wf))
        for job_name, job in pairs(doc.jobs) do
          for _, step in ipairs(job.steps or {}) do
            if step.uses then
              t:expect(step.uses:find("@"), job_name .. ": " .. step.uses .. " is unpinned")
                :never():is_nil()
            end
          end
        end
      end
    end)
  end)
end

--- E2: the prompt surface IS the tactical minimum. Two halves, because a render can only observe
--- one of them: a headless render with ONLY the required facts and no defaults fallback proves
--- nothing else is REQUIRED; the archetype's own catalog proves no vestigial DEFAULTED prompt
--- survives (a suffix selector, a debug port nothing publishes — invisible to a render).
---@param opts { source: string?, root: string?, catalog: string[]? }?
function p6m.empty.standards.prompt_surface(g, s, opts)
  opts = opts or {}
  local source = opts.source or "."

  g:test("renders from the tactical answers alone, with no defaults fallback", {
    proves = "E2: archetect makes an unanswered prompt that has no default a hard error naming the"
      .. " key, so a required answer the overlay's output never reads cannot hide",
  }, function(t)
    local r = archetect.render{
      source = source,
      answers = s.required_answers,
      destination = t:tempdir(),
      defaults = false,
    }
    t:expect(#written(r) > 0, "the overlay rendered its platform layer"):is_true()
  end)

  g:test("composes no prompt library that asks for identity opinions", {
    proves = "E2's other half: a DEFAULTED vestigial prompt is invisible to a render, so the bar"
      .. " is held on the declared composition surface instead",
  }, function(t)
    local allowed = set_of(opts.catalog or {
      -- prompts the tactical key answers, or that render no prompt at all
      "ports", "editor-config", "gitignore", "scm", "archiver",
      "platform-application-manifests",
      s.language .. "-ci",
    })
    local manifest = yaml.decode(fs.read((opts.root or ".") .. "/archetype.yaml"))
    t:expect_all(function()
      for name in pairs(manifest.catalog or {}) do
        t:expect(allowed[name], "composed library `" .. name .. "`"):is_true()
      end
    end)
  end)
end

--- E4: retrofit is additive. Seeds a fake legacy application, renders the overlay over it, and
--- holds what the overlay must not touch.
---
--- Two halves, because only one of them is the ARCHETYPE's to satisfy:
---
---   * The application's own project files must survive — a property of the archetype (it is E3
---     restated on a dirty tree: the writes stay inside the platform layer), so a full proof.
---   * The application's own HYGIENE files (.gitignore/.editorconfig/.gitattributes) should survive
---     too — but whether they do is the RENDER ENGINE's overwrite policy, not the archetype's, and
---     the two engines disagree: the archetect CLI skips a path that already exists, while prova's
---     in-process engine overwrites everything it writes. So it is authored as a spec (measured
---     2026-07-27 against archetect 3.4.0 / prova 0.11.0). See docs/standards.md §2b E4.
---@param opts { source: string?, legacy: table<string,string>?, hygiene: table<string,string>? }?
function p6m.empty.standards.retrofit(g, s, opts)
  opts = opts or {}
  -- Project files the overlay has no business owning, in the shapes real repos have them.
  local legacy = opts.legacy or {
    ["README.md"] = "# legacy application\n",
    ["Dockerfile"] = "FROM scratch\n# the application's own image build\n",
    ["Makefile"] = "build:\n\t@echo the application's own build\n",
    ["src/entrypoint.txt"] = "the application's own source tree\n",
  }
  -- Hygiene files the overlay would otherwise own.
  local hygiene = opts.hygiene or {
    [".gitignore"] = "/legacy-build-output\n",
    [".editorconfig"] = "root = true\n[*]\nindent_size = 7\n",
  }

  local function retrofit(t, seed)
    local dest = t:tempdir()
    for path, contents in pairs(seed) do
      fs.write(dest .. "/" .. path, contents)
    end
    archetect.render{
      source = opts.source or ".",
      answers = s.answers,
      destination = dest,
      defaults = false,
    }
    return dest
  end

  g:test("retrofits an application without touching its project files", {
    proves = "E4: E3's containment restated on a dirty tree — the overlay adds its platform layer"
      .. " to a repo that already has a build, a README and a source tree, and leaves them alone",
  }, function(t)
    local dest = retrofit(t, legacy)
    t:expect_all(function()
      for path, contents in pairs(legacy) do
        t:expect(fs.read(dest .. "/" .. path), path .. " untouched"):equals(contents)
      end
      -- …and the platform layer still landed alongside them
      for _, f in ipairs({
        ".github/workflows/build.yaml",
        ".platform/kubernetes/base/application.yaml",
        ".platform/docker/prd/Dockerfile",
      }) do
        t:expect(fs.exists(dest .. "/" .. f), f .. " added"):is_true()
      end
    end)
  end)

  g:test("leaves the application's own hygiene files alone", {
    spec = "E4: the app's ignores and formatting rules outrank ours. The archetect CLI already"
      .. " skips an existing path, but prova's in-process engine overwrites, so this cannot be"
      .. " held from a proof yet — it needs the engines to agree (or the gitignore/editor-config"
      .. " libraries to merge rather than replace). YP6M-3172",
  }, function(t)
    local dest = retrofit(t, hygiene)
    t:expect_all(function()
      for path, contents in pairs(hygiene) do
        t:expect(fs.read(dest .. "/" .. path), path .. " untouched"):equals(contents)
      end
    end)
  end)
end

--- E7: the archetype repo's own suite and CI hygiene. `opts.pin_spec`, when given, authors the
--- released-tag assertion as an open spec with that reason — for the window between a standards
--- change landing on dev and the release that lets consumers pin it.
---@param opts { root: string?, pin_spec: string? }?
function p6m.empty.standards.hygiene(g, opts)
  opts = opts or {}
  local root = opts.root or "."

  g:test("the suite is configured on the keys prova reads", function(t)
    local manifest = toml.decode(fs.read(root .. "/prova.toml"))
    t:expect(manifest.run and manifest.run.proofs, "[run] proofs (S9: `paths` is dead in ≥0.7)")
      :never():is_nil()
    t:expect(manifest.plugins and manifest.plugins.p6m, "[plugins] p6m"):never():is_nil()
    t:expect(fs.read(root .. "/.gitignore"), ".gitignore"):contains(".last-failed.json")
  end)

  g:test("the p6m plugin is pinned to a released tag", { spec = opts.pin_spec }, function(t)
    local pin = toml.decode(fs.read(root .. "/prova.toml")).plugins.p6m
    t:expect(type(pin) == "string" and pin or "", "the pin is a source string"):matches("@v%d")
  end)

  g:test("acceptance CI runs the suite on prova-rs/run-action, with no toolchain", {
    proves = "E7: an overlay suite renders and inspects, so a runner needs nothing but prova —"
      .. " a language setup step here is a claim about a project that was never generated",
  }, function(t)
    local wf = yaml.decode(fs.read(root .. "/.github/workflows/acceptance.yaml"))
    local uses = {}
    for _, job in pairs(wf.jobs) do
      for _, step in ipairs(job.steps or {}) do
        if step.uses then
          uses[#uses + 1] = step.uses
        end
      end
    end
    local runs_prova = false
    t:expect_all(function()
      for _, u in ipairs(uses) do
        if u:find("^prova%-rs/run%-action@v") then
          runs_prova = true
        end
        t:expect(u:find("setup%-"), "no toolchain step, but found " .. u):is_nil()
      end
    end)
    t:expect(runs_prova, "a prova-rs/run-action@v… step"):is_true()
  end)
end

--- Everything that is a function of ONE answer set (E3–E6): invoke per variant.
---@param opts { source: string?, legacy: table<string,string>?, hygiene: table<string,string>?,
---              cd_spec: string? }?
function p6m.empty.standards.rendering(g, project, s, opts)
  p6m.empty.standards.layout(g, project, s)
  p6m.empty.standards.manifests(g, project, s)
  p6m.empty.standards.cicd(g, project, s, opts)
  p6m.empty.standards.retrofit(g, s, opts)
end

--- Everything that is a property of the ARCHETYPE REPO rather than of a variant (E2, E7): invoke
--- once, whatever the variant count.
---@param opts { source: string?, root: string?, catalog: string[]?, pin_spec: string? }?
function p6m.empty.standards.archetype(g, s, opts)
  p6m.empty.standards.prompt_surface(g, s, opts)
  p6m.empty.standards.hygiene(g, opts)
end

-- ── The standards suites ────────────────────────────────────────────────────────────────────────

p6m.standards = {}

--- S2: the same semantic CRUD script, through whatever transport the sut speaks. `persisted` is an
--- optional hook `(t, display_name, expected_count)` the caller supplies to cross-check rows where
--- they land (schema naming is the service's own business; counting is the caller's).
function p6m.standards.api(g, sut_fixture, opts)
  opts = opts or {}

  g:test("CRUD round-trips through the standard API", function(t)
    local sut = t:use(sut_fixture)
    local d = p6m.driver(sut)

    local created = d.create("widget")
    t:expect(created.status_ok, "create accepted"):is_true()
    t:expect(created.display_name, "create echoes the entity"):equals("widget")
    t:expect(created.id, "create returns an id"):is_truthy()
    if opts.persisted then opts.persisted(t, "widget", 1) end

    t:expect(d.get(created.id).display_name, "read back"):equals("widget")

    local updated = d.update(created.id, "renamed")
    t:expect(updated.status_ok, "update accepted"):is_true()
    t:expect(d.get(created.id).display_name, "update visible"):equals("renamed")
    if opts.persisted then
      opts.persisted(t, "renamed", 1)
      opts.persisted(t, "widget", 0)
    end

    t:expect(d.delete(created.id).status_ok, "delete accepted"):is_true()
    t:expect(d.get_missing(created.id).not_found, "gone after delete"):is_true()
    if opts.persisted then opts.persisted(t, "renamed", 0) end
  end)
end

--- S4–S6: the runtime surface every service exposes identically — health on the management port,
--- real Prometheus metrics, structured JSON logs (the sut boots with LOGGING_STRUCTURED=true).
function p6m.standards.runtime(g, sut_fixture)
  g:test("liveness answers on the management port", function(t)
    local sut = t:use(sut_fixture)
    -- readiness already gated boot; liveness is the sibling the platform will probe next
    t:expect(sut.management:get("/health/liveness").status):equals(200)
    t:expect(sut.management:get("/health/readiness").status):equals(200)
  end)

  g:test("metrics exports real Prometheus content", function(t)
    local sut = t:use(sut_fixture)
    local res = sut.management:get("/metrics")
    t:expect(res.status):equals(200)
    t:expect(res.body, "at least one metric family"):matches("# TYPE%s+%S+")
  end)

  g:test("logs are structured JSON lines", function(t)
    local sut = t:use(sut_fixture)
    local logs = sut.container:logs()
    local structured = 0
    for line in logs:gmatch("[^\r\n]+") do
      local ok, v = pcall(prova.parse.json, line)
      if ok and type(v) == "table" then structured = structured + 1 end
    end
    t:expect(structured > 0, "no JSON log lines despite LOGGING_STRUCTURED=true"):is_true()
  end)

  g:test("the LOGGING_STRUCTURED flag is read, not just defined", function(t)
    local sut = t:use(sut_fixture)
    if sut.plain_logs == nil then
      t:skip("toggle check disabled on this sut (check_logging_toggle = false)")
    end
    local non_json = 0
    for line in sut.plain_logs:gmatch("[^\r\n]+") do
      local ok, v = pcall(prova.parse.json, line)
      if not (ok and type(v) == "table") then non_json = non_json + 1 end
    end
    t:expect(
      non_json > 0,
      "every plain-mode (LOGGING_STRUCTURED=false) line still parsed as JSON — the flag is ignored"
    ):is_true()
  end)
end

--- S10: the rendered project's own CI command path, from a fresh clone, hermetically (docker is
--- still the only host requirement). One hollow render per archetype suffices — resource
--- variants change dependencies, not the command path. The main-only CI tail (publish, cut-tag,
--- manifest dispatch) is deliberately NOT here: that is the e2e harness's tier.
---@param spec { stack: string, project_dir: string, name: string, image: string? }
---   `stack`: a key of `p6m.ci.stacks`. `project_dir`: the project directory inside the render.
---   `name`: unique per suite (tags the image, so concurrent suites sharing a docker daemon
---   never trample each other's tag). `image`: toolchain override.
function p6m.standards.ci_parity(g, project_fixture, spec)
  local stack =
    assert(p6m.ci.stacks[spec.stack], "p6m.standards.ci_parity: unknown stack " .. tostring(spec.stack))
  g:test("CI commands succeed on a fresh clone (" .. spec.stack .. ")", function(t)
    local root = t:use(project_fixture):dir(spec.project_dir).path
    -- Written into the render because docker resolves the dockerfile against the context root;
    -- COPY . . picks it up, which is harmless — it is not part of what the commands build.
    local dockerfile = ".prova-s10-ci.Dockerfile"
    local f = assert(io.open(root .. "/" .. dockerfile, "w"))
    f:write(p6m.ci.dockerfile(stack, { image = spec.image }))
    f:close()
    local image = docker.build{
      context = root,
      dockerfile = dockerfile,
      tag = "prova-s10-" .. spec.name .. ":latest",
    }
    t:expect(image, "CI-parity image (each CI command is a RUN layer)"):never():is_nil()
  end)
end

return p6m
