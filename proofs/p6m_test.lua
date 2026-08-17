-- Self-test for the hermetic core: the identity oracle and the per-transport API surfaces.
-- Always two name shapes — single-word ("Customer") and multi-word ("User Details") — because
-- casing bugs only show on the second. Hermetic: no docker, no renders; this is the bar the
-- oracle itself must always clear before any archetype is held to it.
--
-- S1 (YP6M-3424): the oracle TAKES `project` and `entity` and derives neither from the other.
-- p6m-identity-library owns the rule that defaults an entity off a project name, and holds it in
-- its own suite; re-deriving it here would be the second implementation that drifts. So every
-- identity below passes both names explicitly — which is exactly what a suite must do.
local p6m = require("p6m")

prova.describe("identity: single-word (customer-service)", function()
	local id = p6m.identity{ project = "customer-service", entity = "customer" }

	prova.test("cases both names, and keeps them separate", {
		covers = "docs/standards.md#simplified-identity",
	}, function(t)
		t:expect(id.project_name):equals("customer-service")
		t:expect(id.project_snake):equals("customer_service")
		t:expect(id.ProjectName):equals("CustomerService")
		t:expect(id.projectName):equals("customerService")
		t:expect(id.entity_name):equals("customer")
		t:expect(id.entity_snake):equals("customer")
		t:expect(id.EntityName):equals("Customer")
		t:expect(id.entityName):equals("customer")
	end)
end)

prova.describe("identity: multi-word (user-details-service)", function()
	local id = p6m.identity{ project = "user-details-service", entity = "user-details",
		solution = "acme-platform" }

	prova.test("cases both names, and keeps them separate", {
		covers = "docs/standards.md#simplified-identity",
	}, function(t)
		t:expect(id.project_name):equals("user-details-service")
		t:expect(id.project_snake):equals("user_details_service")
		t:expect(id.ProjectName):equals("UserDetailsService")
		t:expect(id.entity_name):equals("user-details")
		t:expect(id.entity_snake):equals("user_details")
		t:expect(id.EntityName):equals("UserDetails")
		t:expect(id.entityName):equals("userDetails")
		t:expect(id.solution):equals("acme-platform")
	end)

	prova.test("tolerates every input shape", function(t)
		for _, shape in ipairs({ "User Details", "user-details", "user_details", "UserDetails" }) do
			t:expect(p6m.identity{ project = "x", entity = shape }.EntityName, shape)
				:equals("UserDetails")
		end
	end)

	prova.test("an omitted entity means the shape has none — never a guessed strip", {
		covers = "docs/standards.md#simplified-identity",
		proves = "the derivation lives in p6m-identity-library and nowhere else; an oracle that "
			.. "quietly re-implemented it would disagree with the library the day the vocabulary moved",
	}, function(t)
		local bare = p6m.identity{ project = "billing-service" }
		t:expect(bare.EntityName, "no strip is attempted"):equals("BillingService")
	end)

	prova.test("the retired prefix/suffix vocabulary is refused, with the migration in the message", {
		covers = "docs/standards.md#simplified-identity",
		proves = "a silent nil would surface as an empty class name three layers downstream; the "
			.. "assert names the replacement instead",
	}, function(t)
		local ok, err = pcall(p6m.identity, { prefix = "User Details", suffix = "Service" })
		t:expect(ok, "prefix/suffix is rejected"):is_false()
		t:expect(tostring(err), "the error names the new shape"):contains("project =")
	end)

	prova.test("the retiring aliases still answer, so unconverted suites stay green", {
		proves = "21 hand-rolled suites read the old names; they are aliases of one derivation, not "
			.. "a second one, and they go with the last suite that reads them",
	}, function(t)
		t:expect(id.PrefixName):equals(id.EntityName)
		t:expect(id.prefixName):equals(id.entityName)
		t:expect(id.prefix_kebab):equals(id.entity_name)
		t:expect(id.prefix_name):equals(id.entity_snake)
		t:expect(id.PascalFull):equals(id.ProjectName)
		t:expect(id.snake_full):equals(id.project_snake)
		t:expect(id.org_solution):equals(id.solution)
	end)
end)

prova.describe("api surfaces (User Details)", function()
	local id = p6m.identity{ project = "user-details-service", entity = "user-details" }

	prova.test("grpc: flat package, service-named service, entity-named CRUD rpcs", function(t)
		local g = p6m.api.grpc_surface(id)
		t:expect(g.package):equals("user_details_service")
		t:expect(g.service):equals("UserDetailsService")
		t:expect(g.full_service):equals("user_details_service.UserDetailsService")
		t:expect(g.rpcs):has_length(5)
		t:expect(g.rpcs[1]):equals("CreateUserDetails")
		t:expect(g.rpcs[3]):equals("ListUserDetailss") -- naive plural, by design (see standards.md)
		t:expect(g.rpcs[5]):equals("DeleteUserDetails")
	end)

	prova.test("rest: versioned, name-derived, five routes", function(t)
		local r = p6m.api.rest_surface(id)
		t:expect(r.base):equals("/api/v1/user-detailss")
		t:expect(r.routes):has_length(5)
		t:expect(r.routes[1].method):equals("POST")
		t:expect(r.routes[1].status):equals(201)
		t:expect(r.routes[5].method):equals("DELETE")
		t:expect(r.routes[5].status):equals(204)
	end)

	prova.test("graphql: entity-named type, prefix-free queries, camel fields", function(t)
		local q = p6m.api.graphql_surface(id)
		t:expect(q.type_name):equals("UserDetails")
		t:expect(q.queries[1]):equals("userDetails")
		t:expect(q.queries[2]):equals("userDetailss")
		t:expect(q.mutations[1]):equals("createUserDetails")
		t:expect(q.entity_fields[2]):equals("displayName")
	end)
end)

prova.describe("s10 ci parity", function()
	prova.test("pnpm stack mirrors js-pnpm-setup + js-pnpm-build", function(t)
		local df = p6m.ci.dockerfile(p6m.ci.stacks.pnpm)
		t:expect(df):matches("^FROM %-%-platform=linux/amd64 node:22\n")
		t:expect(df, "context lands before any command runs"):matches("WORKDIR /ci\nCOPY %. %.\n")
		t:expect(df):matches("RUN npm install %-g pnpm\n")
		t:expect(df):matches("RUN pnpm install\n")
		-- Conditional steps keep the action's own guard verbatim — parity means skipping
		-- exactly where CI would skip, failing exactly where CI would fail.
		for _, script in ipairs({ "lint", "test", "build" }) do
			t:expect(df, script .. " guarded as the action guards it")
				:matches([[RUN if grep %-q '"]] .. script .. [[":' package%.json; then pnpm ]] .. script)
		end
	end)

	prova.test("dotnet stack mirrors dotnet-setup + dotnet-build", function(t)
		local df = p6m.ci.dockerfile(p6m.ci.stacks.dotnet)
		t:expect(df):matches("^FROM %-%-platform=linux/amd64 mcr%.microsoft%.com/dotnet/sdk:9%.0\n")
		t:expect(df, "restore, then build without re-restore, then test without re-build")
			:matches("RUN dotnet restore.*RUN dotnet build.*%-%-no%-restore.*RUN dotnet test.*%-%-no%-build")
	end)

	prova.test("a caller's toolchain override lands in FROM", function(t)
		local df = p6m.ci.dockerfile(p6m.ci.stacks.pnpm, { image = "node:24" })
		t:expect(df):matches("^FROM %-%-platform=linux/amd64 node:24\n")
	end)

	prova.test("every stack pins linux/amd64 — the proof builds the arch CI runs", function(t)
		for name, stack in pairs(p6m.ci.stacks) do
			t:expect(p6m.ci.dockerfile(stack), name .. " pins amd64")
				:matches("^FROM %-%-platform=linux/amd64 ")
		end
	end)

	prova.test("python stack mirrors python-uv-setup + python-uv-build", function(t)
		local df = p6m.ci.dockerfile(p6m.ci.stacks.python)
		t:expect(df):matches("^FROM %-%-platform=linux/amd64 ghcr%.io/astral%-sh/uv:python3%.12%-bookworm\n")
		t:expect(df, "sync, guarded ruff, guarded pytest, then build — the action's own order")
			:matches("RUN uv sync\n.*ruff.*pytest.*RUN uv build\n")
		t:expect(df, "pytest gate keeps BOTH action conditions (config section OR test files)")
			:matches([[grep %-q '\%[tool\%.pytest\%]' pyproject%.toml || find]])
	end)

	prova.test("java stack mirrors the rendered build.yaml's maven verify override", function(t)
		local df = p6m.ci.dockerfile(p6m.ci.stacks.java)
		t:expect(df):matches("^FROM %-%-platform=linux/amd64 maven:3%-eclipse%-temurin%-21\n")
		t:expect(df):matches("RUN mvn verify %-%-no%-transfer%-progress\n")
	end)

	prova.test("golang stack generates guarded gRPC + GraphQL code around tidy, then builds", function(t)
		local go = p6m.ci.dockerfile(p6m.ci.stacks.golang)
		t:expect(go):matches("^FROM %-%-platform=linux/amd64 golang:1%.23\n")
		t:expect(go, "protoc codegen guarded on proto/ and pinned to the Dockerfile's plugin versions")
			:matches("RUN if %[ %-d proto %]; then.*protoc%-gen%-go@v1%.36%.5.*protoc%-gen%-go%-grpc@v1%.5%.1.*; fi\n")
		t:expect(go, "protoc before tidy (standalone, and tidy must see gen/); gqlgen after (a Go tool)")
			:matches("; fi\nRUN go mod tidy\nRUN if %[ %-f gqlgen%.yml %]; then go run github%.com/99designs/gqlgen generate")
		t:expect(go, "gofmt and vet gate before the build — golang-build's defaults since 2026-07-27")
			:matches("RUN go vet %./%.%.%.\nRUN go build %./%.%.%.\nRUN go test %./%.%.%.\n")
	end)

	prova.test("golang's gofmt gate fails on output, not on exit status", {
		proves = "`gofmt -l` prints misformatted files and still exits 0, so a bare `gofmt -l .` as a"
			.. " RUN layer always passes and proves nothing — the guard is the whole assertion",
	}, function(t)
		local go = p6m.ci.dockerfile(p6m.ci.stacks.golang)
		t:expect(go):matches('RUN if %[ %-n "%$%(gofmt %-l %.%)" %]; then.*exit 1; fi\n')
		t:expect(go, "and never as a bare command"):never():matches("RUN gofmt %-l %.\n")
	end)

	prova.test("rust stack mirrors rust-setup + rust-build defaults, protoc first", function(t)
		local rust = p6m.ci.dockerfile(p6m.ci.stacks.rust)
		t:expect(rust):matches("^FROM %-%-platform=linux/amd64 rust:1\n")
		t:expect(rust, "runner-parity setup first: fmt/clippy components, then protoc")
			:matches("RUN rustup component add rustfmt clippy\nRUN apt%-get update && apt%-get install %-y protobuf%-compiler\nRUN cargo fmt")
		t:expect(rust, "format-check, lint, test, build — rust-build@v1's default order")
			:matches("RUN cargo fmt %-%- %-%-check\nRUN cargo clippy %-%- %-D warnings\nRUN cargo test\nRUN cargo build\n")
	end)
end)

prova.describe("env contract", function()
	local id = p6m.identity{ project = "customer-service", entity = "customer" }

	prova.test("names the platform-injected vars per transport", function(t)
		local grpc = p6m.env_contract(id, "grpc", { GRPC_PORT = "50051", MANAGEMENT_PORT = "8081" })
		t:expect(grpc.GRPC_PORT):equals("50051")
		t:expect(grpc.SERVER_PORT):is_nil()
		t:expect(grpc.LOGGING_STRUCTURED):equals("true")
		t:expect(grpc.OTEL_SERVICE_NAME):equals("customer-service")

		local rest = p6m.env_contract(id, "rest", { SERVER_PORT = "8080" })
		t:expect(rest.SERVER_PORT):equals("8080")
		t:expect(rest.GRPC_PORT):is_nil()
	end)
end)

-- ── E1–E3: the overlay oracle ───────────────────────────────────────────────────────────────────
-- Hermetic, like the identity oracle above: pure functions of the tactical answer key. The suites
-- that consume these (p6m.empty.standards.*) are proven where they are used — in the six
-- *-service-empty-archetype repos, against real renders.

prova.describe("overlay spec: multi-word application (Example Service)", function()
	local s = p6m.empty.spec{
		language = "rust",
		application = "Example Service",
		solution = "Acme Platform",
		registry = "ghcr.io/acme",
		persistence = "PostgreSQL",
		extras = { "Tiltfile" },
	}

	prova.test("derives every deployment name from the one application answer", function(t)
		t:expect(s.application):equals("example-service")
		t:expect(s.application_snake):equals("example_service")
		t:expect(s.ApplicationName):equals("ExampleService")
		t:expect(s.solution):equals("acme-platform")
		t:expect(s.image_repository):equals("ghcr.io/acme/acme-platform/example-service")
		t:expect(s.image):equals("ghcr.io/acme/acme-platform/example-service:latest")
	end)

	prova.test("namespaces every environment {solution}-{application}-{env}", function(t)
		t:expect(p6m.empty.namespace(s, "dev")):equals("acme-platform-example-service-dev")
		t:expect(p6m.empty.namespace(s, "stg")):equals("acme-platform-example-service-stg")
		t:expect(p6m.empty.namespace(s, "prd")):equals("acme-platform-example-service-prd")
	end)

	prova.test("tolerates every input shape for the application name", function(t)
		for _, shape in ipairs({ "Example Service", "example-service", "example_service", "ExampleService" }) do
			local v = p6m.empty.spec{ language = "rust", application = shape, solution = "acme", registry = "r" }
			t:expect(v.application, shape):equals("example-service")
		end
	end)

	prova.test("E2: the required answer key is exactly the three facts with no sane default", function(t)
		local keys = {}
		for k in pairs(s.required_answers) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		t:expect(table.concat(keys, ",")):equals("image_registry,org_solution_name,project_name")
	end)

	prova.test("E2: the answer key names no identity opinion", function(t)
		for _, forbidden in ipairs({
			"author_name", "author_email", "org_name", "solution_name",
			"prefix_name", "suffix_name", "debug_port",
		}) do
			t:expect(s.answers[forbidden], forbidden .. " must not be asked"):is_nil()
		end
	end)

	prova.test("E3: the allowlist is the platform layer plus the declared extras", function(t)
		t:expect(#s.allowed):equals(#p6m.empty.PLATFORM_LAYER + 1)
		local has_tiltfile = false
		for _, f in ipairs(s.allowed) do
			if f == "Tiltfile" then
				has_tiltfile = true
			end
		end
		t:expect(has_tiltfile, "declared extras are allowed"):is_true()
	end)

	prova.test("E3: the platform layer is dotfiles at the root, nothing else", function(t)
		for _, f in ipairs(p6m.empty.PLATFORM_LAYER) do
			if not f:find("/") then
				t:expect(f:sub(1, 1) == ".", f .. " at the repo root"):is_true()
			end
		end
	end)
end)

prova.describe("overlay spec: the transport decides the env contract", function()
	local function spec(protocol)
		return p6m.empty.spec{
			language = "golang", application = "billing", solution = "acme",
			registry = "r", protocol = protocol,
		}
	end

	prova.test("REST binds SERVER_PORT on 8080/8081 over http", function(t)
		local s = spec("REST")
		t:expect(s.port_env_key):equals("SERVER_PORT")
		t:expect(s.port_protocol):equals("http")
		t:expect(s.service_port):equals(8080)
		t:expect(s.management_port):equals(8081)
	end)

	prova.test("GraphQL is an HTTP transport — same contract as REST", function(t)
		local s = spec("GraphQL")
		t:expect(s.port_env_key):equals("SERVER_PORT")
		t:expect(s.port_protocol):equals("http")
	end)

	prova.test("gRPC binds GRPC_PORT on 50051/50052 over grpc", function(t)
		local s = spec("gRPC")
		t:expect(s.port_env_key):equals("GRPC_PORT")
		t:expect(s.port_protocol):equals("grpc")
		t:expect(s.service_port):equals(50051)
		t:expect(s.management_port):equals(50052)
	end)
end)

prova.describe("overlay spec: resourceRequirements", function()
	local function reqs(o)
		o.language, o.application, o.solution, o.registry = "java", "billing", "acme", "r"
		return p6m.empty.resource_requirements(p6m.empty.spec(o))
	end

	prova.test("a hollow overlay declares none", function(t)
		t:expect(#reqs{}):equals(0)
	end)

	prova.test("each selection maps to its platform resource type", function(t)
		t:expect(reqs{ persistence = "PostgreSQL" }[1].resourceType):equals("postgresql")
		t:expect(reqs{ persistence = "MySQL" }[1].resourceType):equals("mysql")
		t:expect(reqs{ cache = "Redis" }[1].resourceType):equals("redis")
		t:expect(reqs{ messaging = "Kafka" }[1].resourceType):equals("kafka")
		t:expect(reqs{ messaging = "Pulsar" }[1].resourceType):equals("pulsar-topic")
	end)

	prova.test("messaging is Shared and carries the chosen access", function(t)
		local m = reqs{ messaging = "Kafka", messaging_access = "consume" }[1]
		t:expect(m.resourceName):equals("messaging")
		t:expect(m.scope):equals("Shared")
		t:expect(m.access):equals("consume")
	end)

	prova.test("all three selections come in manifest order: db, cache, messaging", function(t)
		local r = reqs{ persistence = "PostgreSQL", cache = "Redis", messaging = "Pulsar" }
		t:expect(#r):equals(3)
		t:expect(r[1].resourceName):equals("db")
		t:expect(r[2].resourceName):equals("cache")
		t:expect(r[3].resourceName):equals("messaging")
	end)
end)

-- ── S4: the JSON-line judgment itself ───────────────────────────────────────────────────────────
-- This exists because the original spelling (`prova.parse.json`) does not exist on ANY engine and
-- was called through `pcall`, which swallowed the nil and answered "not JSON" for every line ever
-- inspected. That is the worst shape a bug can take here: it broke S4 in both directions at once —
-- "logs are structured JSON lines" could never pass, and "the flag is read" passed vacuously — and
-- both looked like verdicts about the SERVICE rather than about the oracle. A live suite could not
-- tell the difference; only a hermetic proof of the judgment can.

prova.describe("S4: the JSON-line judgment", function()
	prova.test("recognizes a real structured log line", function(t)
		t:expect(p6m.is_json_object('{"time":"2026-07-27T21:19:20Z","level":"INFO","msg":"started"}'))
			:is_true()
	end)

	prova.test("rejects human-readable output", function(t)
		for _, line in ipairs({
			"2026-07-27T21:19:20.557Z INFO service server starting port=18080",
			"INFO  [main] com.example.Service - started",
			"",
			"not json at all",
		}) do
			t:expect(p6m.is_json_object(line), "plain: " .. line):is_false()
		end
	end)

	prova.test("rejects JSON that is not an object", {
		proves = "a bare scalar or array is valid JSON but not a log RECORD, and counting it would"
			.. " let a service emitting stray numbers look structured",
	}, function(t)
		for _, line in ipairs({ "42", '"a string"' }) do
			t:expect(p6m.is_json_object(line), "scalar: " .. line):is_false()
		end
	end)

	prova.test("the judgment is a real function, not a nil reached through pcall", {
		proves = "the original bug: pcall(prova.parse.json, line) is indistinguishable from"
			.. " 'this line is not JSON' when the function does not exist",
	}, function(t)
		t:expect(type(p6m.is_json_object)):equals("function")
		t:expect(type(json.decode), "the decoder it delegates to"):equals("function")
	end)
end)
