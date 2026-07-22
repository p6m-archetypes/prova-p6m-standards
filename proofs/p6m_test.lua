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
