-- Self-test for the hermetic core: the identity oracle and the per-transport API surfaces.
-- Always two name shapes — single-word ("Customer") and multi-word ("User Details") — because
-- casing bugs only show on the second. Hermetic: no docker, no renders; this is the bar the
-- oracle itself must always clear before any archetype is held to it.
local p6m = require("p6m")

prova.describe("identity: single-word (Customer)", function()
	local id = p6m.identity{ prefix = "Customer" }

	prova.test("derives every cased variant", function(t)
		t:expect(id.PrefixName):equals("Customer")
		t:expect(id.SuffixName):equals("Service")
		t:expect(id.prefix_name):equals("customer")
		t:expect(id.prefixName):equals("customer")
		t:expect(id.PascalFull):equals("CustomerService")
		t:expect(id.snake_full):equals("customer_service")
		t:expect(id.project_name):equals("customer-service")
	end)
end)

prova.describe("identity: multi-word (User Details)", function()
	local id = p6m.identity{ prefix = "User Details", org = "Acme", solution = "Platform" }

	prova.test("derives every cased variant", function(t)
		t:expect(id.PrefixName):equals("UserDetails")
		t:expect(id.prefix_name):equals("user_details")
		t:expect(id.prefixName):equals("userDetails")
		t:expect(id.prefix_kebab):equals("user-details")
		t:expect(id.PascalFull):equals("UserDetailsService")
		t:expect(id.snake_full):equals("user_details_service")
		t:expect(id.project_name):equals("user-details-service")
		t:expect(id.org_solution):equals("acme-platform")
	end)

	prova.test("tolerates every input shape", function(t)
		for _, shape in ipairs({ "User Details", "user-details", "user_details", "UserDetails" }) do
			t:expect(p6m.identity{ prefix = shape }.PrefixName, shape):equals("UserDetails")
		end
	end)
end)

prova.describe("api surfaces (User Details)", function()
	local id = p6m.identity{ prefix = "User Details" }

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
		t:expect(go, "build/test last")
			:matches("; fi\nRUN go build %./%.%.%.\nRUN go test %./%.%.%.\n")
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
	local id = p6m.identity{ prefix = "Customer" }

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
