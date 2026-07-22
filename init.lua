-- prova-p6m-standards — p6m platform standards as executable proofs.
--
-- One parameterized suite every p6m service archetype must pass, so that services rendered from
-- the same answers are indistinguishable at the API and at runtime, regardless of language. The
-- spec is docs/standards.md (S1–S9); this module is its oracle: every expectation is a pure
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
--- full CRUD rpcs named from the entity (`{PrefixName}`), naive-plural List.
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

-- Live layers (p6m.sut{}, p6m.standards.*) land next: the containerized-SUT fixture built on
-- docker.build + topology networks, and the shared api/runtime/docker/hygiene suites each
-- archetype's thin proof file invokes. See docs/standards.md §3.

return p6m
