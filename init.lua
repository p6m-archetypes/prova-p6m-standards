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
  -- go.mod line, then the workflow's guarded gRPC codegen (gen/ is imported but never rendered
  -- — S10's second golang catch; plugin pins match the Dockerfile), tidy (a fresh render ships
  -- no go.sum — S10's first golang catch), and the two inline run steps.
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
function p6m.ci.dockerfile(stack, opts)
  local lines = { "FROM " .. ((opts and opts.image) or stack.image), "WORKDIR /ci", "COPY . ." }
  for _, cmd in ipairs(stack.commands) do
    lines[#lines + 1] = "RUN " .. cmd
  end
  return table.concat(lines, "\n") .. "\n"
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
