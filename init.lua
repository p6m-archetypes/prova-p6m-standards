-- prova-p6m-standards — p6m platform standards as executable proofs.
--
-- One parameterized suite every p6m service archetype must pass, so that services rendered from
-- the same answers are indistinguishable at the API and at runtime, regardless of language. The
-- spec is docs/standards.md (S1–S10); this module is its oracle: every expectation is a pure
-- function of the ANSWER KEY given to the archetype — never of the language.
--
--   local p6m = require("p6m")
--   local id  = p6m.identity{ project = "user-details-service", entity = "user-details" }
--   id.ProjectName       -- "UserDetailsService"  (repo, image, gRPC service)
--   id.EntityName        -- "UserDetails"         (the CRUD subject)
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

--- The identity every standard is stated in terms of (S1): every cased variant of the two names
--- an archetype is answered with, and nothing else.
---
--- THE ORACLE TAKES; IT DOES NOT DERIVE. `project` and `entity` are both explicit inputs, because
--- the p6m identity surface has exactly one implementation — `p6m-identity-library`, which owns
--- the rule that defaults an entity off a project name — and a prompt library and an oracle that
--- each derive the same names is a drift machine. Pass this the SAME values you answered the
--- render with; `p6m.spec{}`-style shape harnesses do that structurally, which is why a suite
--- should build its identity through one rather than by hand.
---
--- `entity` therefore defaults to `project` rather than re-implementing the strip: an omitted
--- entity means "this shape has no domain entity" (the overlay and basic archetypes), never
--- "guess what the library would have done".
---
--- Casing is archetect's own inflection engine by way of `prova.str`, so a name cased here and a
--- name cased by a template agree by construction.
---
---@param spec { project: string, entity: string?, solution: string? }
function p6m.identity(spec)
  assert(type(spec) == "table" and spec.project,
    "p6m.identity requires { project = ... } — the project name the archetype was answered with")
  assert(spec.prefix == nil and spec.suffix == nil,
    "p6m.identity no longer takes prefix/suffix (S1, YP6M-3424): pass { project = \"billing-service\""
    .. ", entity = \"billing\" }. prefix x suffix was one name doing two jobs — the project name and"
    .. " the CRUD entity — and they are separate answers now.")

  local proj = tokens(spec.project)
  local ent = tokens(spec.entity or spec.project)

  local id = {
    -- The raw answers, echoed so a suite can round-trip them straight into an archetect render
    -- without restating them — the render and the expectation then cannot disagree.
    answers = {
      project_name = spec.project,
      entity_name = spec.entity or spec.project,
    },

    -- The project: repo, directory, container image, PlatformApplication, Tilt resource,
    -- OTEL_SERVICE_NAME, and the gRPC service name.
    --
    -- NOTE the spelling trap: `project_name` here is KEBAB, because that is what the repo and
    -- image are actually called. Archetect's key of the same name expands to SNAKE. The snake form
    -- is `project_snake` — never reach for `project_name` expecting `billing_service`.
    project_name = joined(proj, "-"),
    project_snake = joined(proj, "_"),
    ProjectName = pascal(proj),
    projectName = camel(proj),

    -- The entity: the CRUD subject. S2 fixes it as entity-named, not service-named — a
    -- `billing-service` exposes `/api/v1/billings`, type `Billing`, rpc `CreateBilling`.
    entity_name = joined(ent, "-"),
    entity_snake = joined(ent, "_"),
    EntityName = pascal(ent),
    entityName = camel(ent),
  }

  if spec.solution then
    id.solution = joined(tokens(spec.solution), "-")
  end

  -- ── Retiring vocabulary (YP6M-3424) ───────────────────────────────────────────────────────────
  -- Twenty-one hand-rolled suites still read these. They are ALIASES of the fields above, computed
  -- once from one input — a rename with a transition window, not a second derivation. They go with
  -- the last suite that reads them, which is the shape-harness work; the reminder below carries it.
  id.PrefixName  = id.EntityName
  id.prefixName  = id.entityName
  id.prefix_kebab = id.entity_name
  id.prefix_name = id.entity_snake
  id.PascalFull  = id.ProjectName
  id.snake_full  = id.project_snake
  id.org_solution = id.solution

  return id
end

--- Whether a log line parses as a JSON object. `prova.parse.json` does NOT exist on any engine
--- (checked against released v0.11.0 and a source build) — it was reached through `pcall`, which
--- swallowed the nil and reported "not JSON" for every line ever inspected. That broke S4 in both
--- directions at once: "logs are structured JSON lines" could never pass, and "the flag is read"
--- passed vacuously because every line counted as non-JSON. `json.decode` is stable on both.
local function is_json_object(line)
  local ok, v = pcall(json.decode, line)
  return ok and type(v) == "table"
end
p6m.is_json_object = is_json_object

-- ── S2: the API surfaces — expectations per transport ───────────────────────────────────────────

p6m.api = {}

--- Expected gRPC surface: flat package `{project_name}`, service `{PrefixName}{SuffixName}`,
--- full CRUD rpcs named from the entity (`{PrefixName}`), naive-plural List. `messages` pins the
--- request/response shapes — the drift the survey found lives there as much as in rpc names.
function p6m.api.grpc_surface(id)
  local P = id.EntityName
  return {
    package = id.project_snake,
    service = id.ProjectName,
    -- fully-qualified name as reflection reports it
    full_service = id.project_snake .. "." .. id.ProjectName,
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
  local base = "/api/v1/" .. id.entity_name .. "s"
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
  local P, c = id.EntityName, id.entityName
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
        if not is_json_object(line) then return true end
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
  -- golang-setup@v1 + golang-build@v1 (created 2026-07-27; golang was the last ecosystem with no
  -- p6m-actions trio, which is why this stack used to mirror community actions). The commands are
  -- unchanged by that convergence — they moved from the rendered workflow into golang-build, which
  -- is where S10 says they belong: two guarded codegen steps for code that is imported but never
  -- rendered — protoc gen/ for gRPC BEFORE tidy (protoc is standalone, and tidy must see gen/),
  -- gqlgen for GraphQL AFTER tidy (it is a Go tool, so its dep must resolve first). tidy first
  -- materializes go.sum (a fresh render ships none). gofmt and vet are the config-free,
  -- toolchain-native gates, matching what rust (fmt + clippy) and python (ruff) already run.
  -- golangci-lint stays out of both: it is a third-party meta-linter whose enabled set moves
  -- between its own releases, so a repo that passes today would fail on a version bump it never
  -- asked for.
  --
  -- Mirror status (2026-07-27): golang-build's gofmt/vet defaults are on a PR
  -- (p6m-actions/golang-build#YP6M-3172), because that org now requires one for main. Until it
  -- merges this stack is deliberately STRICTER than the rendered CI rather than looser — the
  -- archetypes were made gofmt-clean first, so it passes today and holds the line against
  -- regression while the action catches up. If that PR is rejected, drop these two commands.
  --
  -- The gofmt line is a guard, not a bare command, because `gofmt -l` reports misformatted files on
  -- stdout and still EXITS 0 — a bare `gofmt -l .` in a RUN layer always "succeeds" and would prove
  -- nothing. The action makes the same distinction.
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
      [[if [ -n "$(gofmt -l .)" ]; then echo "misformatted:"; gofmt -l .; exit 1; fi]],
      "go vet ./...",
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

-- ── The service shapes: one harness per shape, so a suite is a thin invocation ───────────────────
--
-- A p6m archetype comes in one of three SHAPES, and the shape — not the language — decides which
-- standards have a subject:
--
--   full    (rest/grpc/graphql) generates a domain: S1-S10, CRUD over the entity
--   basic   generates a bootable service with no domain: S1, S3-S9 (no S2 CRUD)
--   overlay (empty) generates only the platform layer: E1-E7 (see p6m.empty below)
--
-- The overlay shape has had this triple — `spec{}` / `render` / `standards.*` — since 2026-07-27,
-- and its six suites are ~75-line thin invocations that cannot drift from each other. The other
-- twenty-four hand-rolled theirs, and the cost was measurable: twenty-one called `archetect.render`
-- themselves, and the entity's persistence table alone had FOUR answers across the fleet (`items`,
-- `Items`/`DisplayName`, `` `items` ``, `{prefix_name}s`) for one standard that says it is
-- name-derived. Every one of those suites passed. A suite that encodes the drift it exists to catch
-- is worse than no suite, because it reports green.
--
-- So the identity, the render answers and the SQL oracle all come from ONE spec here. A suite that
-- builds its expectations and its render from the same object cannot answer the archetype one thing
-- and assert another.

-- No path allowlist here on purpose. Containment (`writes ⊆ allowed`) is the OVERLAY's bar (E3),
-- because an overlay that writes project scaffolding has broken its contract. A service archetype
-- is supposed to write scaffolding, and it is language-specific, so an allowlist would be a
-- per-language list to maintain that proves nothing.

--- The service-shape spec: one object that answers the render AND states the expectation.
---
--- `project` is the only name required. `entity` is passed through to `p6m.identity` untouched —
--- neither this nor the oracle re-derives it, because p6m-identity-library owns that rule (S1). A
--- full-shape suite should pass both, and pass the SAME `entity` it answers the render with, which
--- is automatic here: `s.answers` and `s.id` are built from the one input.
---
---@param o { language: string, shape: string?, transport: string?,
---           project: string, entity: string?, solution: string, registry: string?,
---           persistence: string?, cache: string?, messaging: string?, messaging_access: string?,
---           answers: table?, extras: string[]? }
function p6m.spec(o)
  assert(type(o) == "table" and o.project, "p6m.spec requires { project = ... }")
  local language = assert(o.language, "p6m.spec requires { language = ... }")
  local shape = o.shape or "full"
  assert(shape == "full" or shape == "basic",
    "p6m.spec shape must be \"full\" or \"basic\" — the overlay shape is p6m.empty.spec")

  local transport = o.transport
  if shape == "full" then
    assert(transport == "rest" or transport == "grpc" or transport == "graphql",
      "p6m.spec{ shape = \"full\" } requires transport = \"rest\" | \"grpc\" | \"graphql\"")
  end

  -- A basic archetype generates no domain, so it has no entity — and the oracle must be told that
  -- rather than left to guess a strip it deliberately does not implement (S1).
  local entity = shape == "full" and (o.entity or o.project) or nil

  local s = {
    language = language,
    shape = shape,
    transport = transport,
    id = p6m.identity{ project = o.project, entity = entity, solution = o.solution },
    registry = o.registry or "ghcr.io/acme",
    persistence = o.persistence or "None",
    cache = o.cache or "None",
    messaging = o.messaging or "None",
    messaging_access = o.messaging_access or "produce",
    extras = o.extras or {},
  }

  s.protocol = ({ rest = "REST", grpc = "gRPC", graphql = "GraphQL" })[transport] or "REST"
  s.service_port = o.service_port or (transport == "grpc" and 50051 or 8080)
  s.management_port = o.management_port or (s.service_port + 1)

  -- The directory a service archetype renders its project into — `project-name`, not the
  -- destination root. Every consumer needs it to reach the rendered tree.
  s.project_dir = s.id.project_name

  -- S2's persistence oracle, stated ONCE. The entity's table is name-derived with the same naive
  -- plural the API uses, which is the whole point: `items` hardcoded in a suite cannot fail when a
  -- rendered service hardcodes `items` too, so the drift survived precisely where it was checked.
  --
  -- Storage naming is the one place the fleet legitimately differs: EF Core names tables and
  -- columns after the CLR property names (PascalCase), every other stack uses snake. That is the
  -- standard's own principle — idiomatic inside, identical at the boundary — so the API surface
  -- stays identical while the storage spelling stays native. It is stated here rather than in six
  -- suites, so a language cannot quietly invent a third convention.
  local pascal_storage = (language == "dotnet")
  s.table_name = entity
    and (pascal_storage and (s.id.EntityName .. "s") or (s.id.entity_snake .. "s"))
    or nil
  s.display_name_column = pascal_storage and "DisplayName" or "display_name"

  -- The identity facts with no sane default. A headless render with ONLY these and no defaults
  -- fallback must succeed — E2's mechanism, generalized off the overlays onto every service shape.
  -- Language-specific required answers (a Maven group id, a Go module path) are merged by the
  -- consumer through `o.answers`, and each one it must supply is a prompt this bar makes visible.
  -- `image_registry` belongs here, not merely in `answers`: no library in the composition gives it
  -- a default (registry hostnames are company-specific), so a defaults=false render demands it. The
  -- E2 check surfaced that the first time it ran against a real archetype — which is what it is for.
  s.required_answers = {
    project_name = s.id.project_name,
    solution_name = s.id.solution,
    image_registry = s.registry,
  }
  if entity then s.required_answers.entity_name = s.id.entity_name end

  s.answers = {
    project_name = s.id.project_name,
    solution_name = s.id.solution,
    image_registry = s.registry,
    service_port = s.service_port,
    management_port = s.management_port,
    persistence = s.persistence,
    cache = s.cache,
    messaging = s.messaging,
    messaging_access = s.messaging_access,
  }
  if entity then s.answers.entity_name = s.id.entity_name end

  for k, v in pairs(o.answers or {}) do
    s.answers[k] = v
    -- A language answer with no default is required for the E2 render too; the consumer declares
    -- which by listing it in `o.required`, defaulting to all of them (the safe direction: a stray
    -- entry only makes the E2 render more specific, never less).
    if (o.required == nil) or o.required[k] then s.required_answers[k] = v end
  end

  s.label = language .. "-" .. (transport or shape)
    .. "[" .. s.id.project_name .. "/" .. s.persistence .. "]"
  return s
end

--- The shared render fixture for a service shape. One headless render per spec, into a named
--- tempdir so several specs in one file cannot collide.
---
--- `ctx:tempdir()` is ADDRESSED, not created: every unnamed call in one scope answers with the same
--- directory, so N renders into one destination leave the first winner in place and every later
--- spec silently asserts against it — a suite that proves one variant N times, all green. The name
--- is the fix and it is not optional.
---@param s table a `p6m.spec` result
---@param opts { source: string?, scope: any?, answers: table?, defaults: boolean? }?
function p6m.render(s, opts)
  opts = opts or {}
  return prova.fixture(s.label .. ":project", opts.scope or Scope.File, function(ctx)
    local answers = {}
    for k, v in pairs(s.answers) do answers[k] = v end
    for k, v in pairs(opts.answers or {}) do answers[k] = v end
    return archetect.render{
      source = opts.source or ".",
      answers = answers,
      destination = ctx:tempdir(s.label),
      defaults = opts.defaults ~= false,
    }
  end)
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

-- prova's document formats read with `decode` and write with `encode` — api-freeze §1, ratified
-- 2026-07-23 and amended 2026-07-26. The former `parse`/`dump` spellings were removed outright with
-- NO aliases, deliberately: "a shim would only be a second name to keep working, a second thing to
-- document, and a route for the drift to grow back." This plugin briefly carried such a shim, which
-- was the wrong instinct — it let consumers keep running an engine four releases behind without
-- noticing. The fleet resolves its engine through `prova-rs/run-action@v1`, which now tracks every
-- prova release automatically, so the current names are the only ones any consumer sees.


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
    -- E1b: how to build and run the EXISTING application. The overlay cannot guess these — a
    -- retrofit target may be a single crate or a workspace, flat or multi-module, src/ layout or
    -- not — so they are answers, defaulted to what each language's own service archetype produces.
    build_command = o.build_command,
    runtime_artifact = o.runtime_artifact,
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
    solution_name = s.solution,
    image_registry = s.registry,
  }

  -- The full key: the required facts plus the defaulted selections a variant exercises.
  s.answers = {
    project_name = s.application,
    solution_name = s.solution,
    image_registry = s.registry,
    protocol = s.protocol,
    service_port = s.service_port,
    management_port = s.management_port,
    persistence = s.persistence,
    cache = s.cache,
    messaging = s.messaging,
    messaging_access = s.messaging_access,
    build_command = s.build_command,
    runtime_artifact = s.runtime_artifact,
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
--- so a prompt outside the tactical key errors instead of being papered over (E2). Scope.File by
--- default — every consumer today is a single-file suite, where Scope.Suite degrades to file scope
--- with a warning on every run. A consumer that grows a suite.lua and wants one render shared
--- across its files opts in with `scope = Scope.Suite`.
---@param s table a `p6m.empty.spec` result
---@param opts { source: string?, scope: any?, answers: table? }?
function p6m.empty.render(s, opts)
  opts = opts or {}
  return prova.fixture(s.label .. ":project", opts.scope or Scope.File, function(ctx)
    return archetect.render{
      source = opts.source or ".",
      answers = opts.answers or s.answers,
      -- NAMED, and that is load-bearing. `ctx:tempdir()` is ADDRESSED, not created: every unnamed
      -- call in one scope answers with the SAME directory. A suite with two variants therefore
      -- rendered both into one destination, and since prova 0.19 preserves an existing path rather
      -- than overwriting it, the FIRST variant won and the second silently asserted against it —
      -- so every overlay suite's second variant (the single-word name, the gRPC port contract, the
      -- full resourceRequirements set) was never actually proven. Latent from 0.19 until the
      -- YP6M-3424 sweep pushed a change that made the expectations disagree loudly enough to see.
      destination = ctx:tempdir(s.label),
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

  g:test("the container build is driven by the answers, not by an assumed layout", {
    proves = "E1b: an overlay retrofits an EXISTING application, so a Dockerfile that hardcodes a"
      .. " module name, a crate, a src/ layout or an output path only containerizes applications"
      .. " already shaped like our own archetypes — which is the one thing a retrofit tool cannot"
      .. " assume. Asserted with NON-DEFAULT values so it cannot pass by coincidence: the defaults"
      .. " happen to equal what the greenfield archetypes produce.",
  }, function(t)
    if s.build_command == nil and s.runtime_artifact == nil then
      t:skip("variant supplies neither build_command nor runtime_artifact")
    end
    local root = t:use(project).path
    t:expect_all(function()
      for _, kind in ipairs({ "prd", "local" }) do
        local df = fs.read(root .. "/.platform/docker/" .. kind .. "/Dockerfile")
        if s.build_command then
          t:expect(df, kind .. " runs the answered build command"):contains(s.build_command)
        end
        if s.runtime_artifact then
          t:expect(df, kind .. " uses the answered runtime artifact"):contains(s.runtime_artifact)
        end
        -- and copies the whole repo rather than naming parts of it
        t:expect(df, kind .. " copies the repo wholesale"):matches("COPY %. %.")
      end
    end)
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

  g:test("the build workflow names the application as its image", { promises = cd_spec }, function(t)
    local env = workflow(t).env or {}
    t:expect(env.IMAGE_NAME, "IMAGE_NAME"):equals(s.application)
    t:expect(env.APPLICATION_NAME, "APPLICATION_NAME"):equals(s.application)
  end)

  g:test("the workflow's dockerfile-path names a Dockerfile the overlay rendered", {
    promises = cd_spec,
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
    promises = cd_spec,
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
    -- The overlay shape composes the SAME declared vocabulary as every other shape
    -- (`p6m.PROMPT_LIBRARIES`, S1b) plus its language's CI library. Reusing that list rather than
    -- keeping a second copy here is the point: two allowlists for one bar drift, and this one had
    -- already fallen behind — it predated p6m-identity, so an overlay that adopted the fleet's
    -- single identity implementation failed for doing the right thing.
    local names = {}
    for _, n in ipairs(opts.catalog or p6m.PROMPT_LIBRARIES) do names[#names + 1] = n end
    names[#names + 1] = s.language .. "-ci"
    local allowed = set_of(names)
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
    proves = "E4: the app's ignores and formatting rules outrank ours. The archetect CLI always"
      .. " skipped an existing path; prova's in-process engine clobbered it until the headless"
      .. " driver learned to honor the render's if_exists policy (prova v0.19.0 — the [requires]"
      .. " floor). The engines agree now, so the bar holds from a proof. YP6M-3172",
  }, function(t)
    local dest = retrofit(t, hygiene)
    t:expect_all(function()
      for path, contents in pairs(hygiene) do
        t:expect(fs.read(dest .. "/" .. path), path .. " untouched"):equals(contents)
      end
    end)
  end)
end

--- E7: the archetype repo's own suite and CI hygiene. The released-tag bar is a REMINDER, not a
--- test (see below), so a fleet iterating the standards on `dev` stays green while the pin owes
--- attention; `--heed=p6m-pin` (or a profile's `heed = ["p6m-pin"]`) enforces it when the
--- iteration window closes.
---@param opts { root: string? }?
function p6m.empty.standards.hygiene(g, opts)
  opts = opts or {}
  local root = opts.root or "."

  g:test("the suite is configured on the keys prova reads", function(t)
    local manifest = toml.decode(fs.read(root .. "/prova.toml"))
    t:expect(manifest.run and manifest.run.proofs, "[run] proofs (S9: `paths` is dead in ≥0.7)")
      :never():is_nil()
    t:expect(manifest.dependencies and manifest.dependencies.p6m, "[dependencies] p6m"):never():is_nil()
  end)

  g:test("prova's own generated artifacts are gitignored, not committed", {
    proves = "S9: every prova run writes .luarc.json and annotations/, and .luarc.json holds"
      .. " absolute paths into ONE machine's prova data dir and plugin cache. Ignoring them is not"
      .. " tidiness — a tracked one is committed the moment anyone else runs the suite, and it"
      .. " silently overwrites whatever paths the last person committed. Found tracked in 19 of the"
      .. " fleet's prova packages on 2026-07-27.",
  }, function(t)
    local gitignore = fs.read(root .. "/.gitignore")
    t:expect_all(function()
      for _, artifact in ipairs({ ".last-failed.json", ".luarc.json", "annotations/" }) do
        t:expect(gitignore, artifact .. " ignored"):contains(artifact)
      end
    end)
  end)

  -- E7's released-tag bar is NOT a test here: it is the `p6m-pin` REMINDER, declared at file
  -- root via `p6m.pin_reminder()` (a reminder registers outside any group).

  g:test("acceptance CI runs the suite on prova-rs/run-action, with no toolchain", {
    proves = "E7: an overlay suite renders and inspects, so a runner needs nothing but prova —"
      .. " a language setup step here is a claim about a project that was never generated",
  }, function(t)
    local wf = yaml.decode(fs.read(root .. "/.github/workflows/acceptance.yaml"))
    local prova_step
    t:expect_all(function()
      for _, job in pairs(wf.jobs) do
        for _, step in ipairs(job.steps or {}) do
          if step.uses then
            if step.uses:find("^prova%-rs/run%-action@v") then
              prova_step = step
            end
            t:expect(step.uses:find("setup%-"), "no toolchain step, but found " .. step.uses):is_nil()
          end
        end
      end
    end)
    t:expect(prova_step, "a prova-rs/run-action@v… step"):never():is_nil()
  end)

  g:test("acceptance CI tracks run-action@v1 rather than pinning an engine version", {
    proves = "E7: the engine version belongs in run-action, which is bumped on every prova release"
      .. " (automatically, since 2026-07-28), so tracking the tag is what keeps a suite on the engine"
      .. " the fleet runs. A local `version:` silently freezes it — and is invisible next to a tag"
      .. " that still looks current. This assertion previously REQUIRED such a pin, which is how"
      .. " these six ended up frozen on v0.11.0 while run-action@v1 already served v0.14.0, across a"
      .. " breaking deserializer rename.",
  }, function(t)
    local wf = yaml.decode(fs.read(root .. "/.github/workflows/acceptance.yaml"))
    local found = false
    t:expect_all(function()
      for _, job in pairs(wf.jobs) do
        for _, step in ipairs(job.steps or {}) do
          if step.uses and step.uses:find("^prova%-rs/run%-action@") then
            found = true
            t:expect(step.uses, "tracks the v1 tag"):equals("prova-rs/run-action@v1")
            t:expect(step["with"] and step["with"].version, "no local engine pin"):is_nil()
          end
        end
      end
      t:expect(found, "a prova-rs/run-action step"):is_true()
    end)
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
---@param opts { source: string?, root: string?, catalog: string[]? }?
function p6m.empty.standards.archetype(g, s, opts)
  p6m.empty.standards.prompt_surface(g, s, opts)
  p6m.empty.standards.hygiene(g, opts)
end

--- E7's released-tag bar, as a standing REMINDER — an obligation the world creates, not a defect
--- in the change under test: iterating the standards on `dev` is a sanctioned state while the
--- studio staging settles, so a moving pin owes ATTENTION, never a red run. DUE while
--- [dependencies] p6m rides a branch, path, or untagged git source; silent again the moment the
--- pin returns to a released tag — the repin IS the discharge. A lane that promises the bar
--- heeds it by name or tag (`--heed=p6m-pin`, or `heed = ["p6m-pin"]` on a profile).
---
--- A reminder registers at the FILE ROOT (never inside a group body): call this once, beside —
--- not within — the `prova.group` that holds the archetype's other repo-level standards.
---@param opts { root: string? }?
function p6m.pin_reminder(opts)
  local root = (opts or {}).root or "."
  prova.remind("the p6m standards return to a released tag", {
    tags = { "p6m-pin" },
    when = function()
      local pin = toml.decode(fs.read(root .. "/prova.toml")).dependencies.p6m
      if type(pin) == "string" then
        return not pin:match("@v%d") and ("the pin is `" .. pin .. "` — not a released @vN")
      end
      if type(pin) == "table" then
        if pin.tag then return false end
        local ref = pin.branch and ('branch = "' .. pin.branch .. '"')
          or pin.path and ('path = "' .. pin.path .. '"')
          or "an untagged git source"
        return "the pin rides " .. ref .. " — sanctioned while the studio staging settles (YP6M-3372)"
      end
      return "no [dependencies] p6m pin found"
    end,
  }, "repin [dependencies] p6m to the released tag (p6m-archetypes/prova-p6m-standards@vN)")
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
      if is_json_object(line) then structured = structured + 1 end
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
      if not is_json_object(line) then non_json = non_json + 1 end
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

-- ── The prompt surface: every archetype complies with one declared interface ─────────────────────

--- The prompt vocabulary a p6m service archetype may ask for. Anything outside it is an identity
--- opinion the fleet retired (S1) or a prompt whose answer nothing reads (E2's principle).
---
--- Held on the COMPOSED CATALOG rather than on a render, because the two halves of the bar are
--- visible in different places: a render exposes what is REQUIRED (an unanswered prompt with no
--- default is a hard error naming its key), while a DEFAULTED vestigial prompt — a suffix selector,
--- a debug port nothing publishes — renders perfectly and is invisible to it. The library a prompt
--- arrives through is the one place both are declarable.
p6m.PROMPT_LIBRARIES = {
  -- the identity surface: THE single implementation (S1)
  "p6m-identity",
  -- prompt nothing, or prompt only what the tactical key answers
  "ports", "editor-config", "gitignore", "scm", "archiver",
  "platform-application-manifests",
}

--- The libraries the fleet retired, named so the failure says WHY rather than "not in the list".
p6m.RETIRED_PROMPT_LIBRARIES = {
  ["author"] = "author identity reached four files fleet-wide and archetect pre-answers it from ~/.gitconfig",
  ["org"] = "org_name x solution_name were two prompts building one string; p6m-identity asks for the solution slug once",
  ["project"] = "prefix_name x suffix_name was one name doing two jobs; p6m-identity asks for the project and the entity separately",
}

--- E2, generalized off the overlays onto every service archetype: **the prompt surface IS the
--- declared interface.** Two halves, because a render can only observe one of them.
---
---@param s table a `p6m.spec` result
---@param opts { source: string?, root: string?, catalog: string[]?, resources: string[]? }?
function p6m.standards.prompt_surface(g, s, opts)
  opts = opts or {}
  local source = opts.source or "."
  local root = opts.root or "."

  g:test("renders from the declared answer key alone, with no defaults fallback", {
    proves = "archetect makes an unanswered prompt that has no default a hard error naming the key,"
      .. " so a REQUIRED answer the archetype's output never reads cannot hide behind -D",
  }, function(t)
    local r = archetect.render{
      source = source,
      answers = s.required_answers,
      destination = t:tempdir(s.label .. ":e2"),
      defaults = false,
    }
    t:expect(#(r.writes or {}) > 0,
      "the archetype rendered its project from the declared key alone"):is_true()
  end)

  g:test("composes only libraries whose prompts survive the declared vocabulary", {
    proves = "E2's other half: a DEFAULTED vestigial prompt renders perfectly and is invisible to"
      .. " the check above, so the bar is held on the declared composition surface instead",
  }, function(t)
    local allowed = {}
    for _, name in ipairs(opts.catalog or p6m.PROMPT_LIBRARIES) do allowed[name] = true end
    -- Resource and CI libraries render files and prompt nothing; they are per-language, so the
    -- consumer names its own rather than the plugin maintaining six lists.
    for _, name in ipairs(opts.resources or {}) do allowed[name] = true end
    allowed[s.language .. "-ci"] = true

    local manifest = yaml.decode(fs.read(root .. "/archetype.yaml"))
    t:expect_all(function()
      for name in pairs(manifest.catalog or {}) do
        local retired = p6m.RETIRED_PROMPT_LIBRARIES[name]
        if retired then
          t:expect(false, "composes retired prompt library `" .. name .. "` — " .. retired):is_true()
        else
          t:expect(allowed[name], "composed library `" .. name .. "` is outside the declared"
            .. " prompt vocabulary"):is_true()
        end
      end
    end)
  end)

  g:test("composes the one identity library, so the surface has a single implementation", {
    proves = "S1: an archetype that asks for identity inline has its own copy of the contract, and"
      .. " the fleet's whole drift problem is copies of one contract",
  }, function(t)
    local manifest = yaml.decode(fs.read(root .. "/archetype.yaml"))
    t:expect((manifest.catalog or {})["p6m-identity"],
      "archetype.yaml composes p6m-identity"):never():is_nil()
  end)
end


-- ── S1c: the layout vocabulary ───────────────────────────────────────────────────────────────────

--- The page and section keys every p6m archetype lays its prompts out in. One vocabulary, so a form
--- reads identically whatever the language or shape, and a wizard can route on keys it knows.
---
--- `sections` lists what MAY appear under a page; `shapes` limits a page to the shapes that have
--- prompts for it. A shape omits what it has no prompts for and never invents a key.
p6m.LAYOUT = {
  pages = {
    project         = { sections = { "platform", "service" },
                        shapes = { full = true, basic = true, overlay = true } },
    container_build = { sections = {},
                        shapes = { overlay = true } },
    -- the overlay carries this page without sections: its resource prompts sit on it directly
    resources       = { sections = { "persistence", "cache", "messaging", "object_storage" },
                        shapes = { full = true, overlay = true } },
    source_control  = { sections = {},
                        shapes = { full = true, basic = true, overlay = true } },
  },
  -- the pages a shape MUST declare (it may not omit these; it has prompts for them)
  required = {
    full    = { "project", "resources", "source_control" },
    basic   = { "project", "source_control" },
    overlay = { "project", "container_build", "resources", "source_control" },
  },
}

--- S1c: the archetype declares the fleet's layout vocabulary, and pins its keys.
---
--- Read from the SCRIPT, not from a derived interface. That a declaration becomes a layout in the
--- derived interface is archetect's bar, held by its own suite — restating it here would be a
--- second statement of one thing. What only we can get wrong is which keys we declare, and whether
--- we pinned them; both are visible in the source and need no toolchain to check (S8b).
---@param shape string "full" | "basic" | "overlay"
---@param opts { root: string? }?
function p6m.standards.layout(g, shape, opts)
  opts = opts or {}
  local root = opts.root or "."
  local required = assert(p6m.LAYOUT.required[shape],
    "p6m.standards.layout: unknown shape " .. tostring(shape))

  local script = fs.read(root .. "/archetype.lua")

  -- every page/section declaration, as { verb, key }
  local declared = {}
  for verb, body in script:gmatch("[:%.](page|section)%(%s*{(.-)}%s*,") do
    local key = body:match('key%s*=%s*"([%w_]+)"')
    declared[#declared + 1] = { verb = verb, key = key, body = body }
  end

  g:test("declares only the fleet's page and section keys", {
    proves = "S1c: one vocabulary across thirty archetypes is what lets a wizard route on keys it "
      .. "knows; an archetype that invents `storage` where the fleet says `object_storage` renders "
      .. "a step no client recognises",
  }, function(t)
    local pages, sections = {}, {}
    for key, spec in pairs(p6m.LAYOUT.pages) do
      pages[key] = spec
      for _, sec in ipairs(spec.sections) do sections[sec] = true end
    end
    t:expect(#declared > 0, "the archetype declares a layout at all"):is_true()
    t:expect_all(function()
      for _, d in ipairs(declared) do
        if d.verb == "page" then
          t:expect(pages[d.key] ~= nil, "page key `" .. tostring(d.key) .. "`"):is_true()
          if pages[d.key] then
            t:expect(pages[d.key].shapes[shape] == true,
              "page `" .. d.key .. "` belongs to the " .. shape .. " shape"):is_true()
          end
        else
          t:expect(sections[d.key] ~= nil, "section key `" .. tostring(d.key) .. "`"):is_true()
        end
      end
    end)
  end)

  g:test("declares every page its shape has prompts for", {
    proves = "S1c: a shape omits what it has no prompts for — but it may not drop a page it does "
      .. "have prompts for, which would bury those fields in whatever step came before",
  }, function(t)
    local seen = {}
    for _, d in ipairs(declared) do
      if d.verb == "page" then seen[d.key] = true end
    end
    t:expect_all(function()
      for _, key in ipairs(required) do
        t:expect(seen[key], "the " .. shape .. " shape declares page `" .. key .. "`"):is_true()
      end
    end)
  end)

  g:test("pins every key, so a wizard can route on it", {
    proves = "S1c: the hybrid drive re-derives between rounds and pages appear and disappear as "
      .. "branches open, so a client routes on `key`. The bare-string form lets archetect derive "
      .. "one from the title — and titles are display text that changes",
  }, function(t)
    t:expect_all(function()
      for _, d in ipairs(declared) do
        t:expect(d.key ~= nil,
          "a " .. d.verb .. " declared without an explicit key: {" .. d.body:sub(1, 60) .. "…"):is_true()
      end
      -- the bare-string form takes a string literal where the table form takes `{`
      for verb in script:gmatch('[:%.](page)%(%s*"') do
        t:expect(false, "bare-string `" .. verb .. "(\"…\")` derives a key from the title"):is_true()
      end
      for verb in script:gmatch('[:%.](section)%(%s*"') do
        t:expect(false, "bare-string `" .. verb .. "(\"…\")` derives a key from the title"):is_true()
      end
    end)
  end)
end

--- The properties of the ARCHETYPE REPO (as opposed to its rendered output): the prompt surface it
--- declares and the suite/CI hygiene it keeps. The mirror of `p6m.empty.standards.archetype`.
---@param s table a `p6m.spec` result
function p6m.standards.archetype(g, s, opts)
  p6m.standards.prompt_surface(g, s, opts)
  p6m.empty.standards.hygiene(g, opts)
end

return p6m
