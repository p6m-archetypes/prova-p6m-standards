---@meta p6m
--- prova-p6m-standards — p6m platform standards as executable proofs.
---
--- Editor-only type stub for `require("p6m")`: it gives consumers completion and signatures
--- and ships nothing at runtime. Keep it in sync with init.lua's public API as the plugin grows.

---@class p6m.Identity
---@field answers { prefix_name: string, suffix_name: string } the raw answer key, for renders
---@field PrefixName string   # "UserDetails"
---@field SuffixName string   # "Service"
---@field prefix_name string  # "user_details"
---@field suffix_name string  # "service"
---@field prefixName string   # "userDetails"
---@field prefix_kebab string # "user-details"
---@field suffix_kebab string # "service"
---@field PascalFull string   # "UserDetailsService"
---@field snake_full string   # "user_details_service"
---@field project_name string # "user-details-service"
---@field org_solution string? # "acme-platform" (when org+solution given)

---@class p6m.GrpcSurface
---@field package string      # flat "{prefix}_{suffix}"
---@field service string      # "{PrefixName}{SuffixName}"
---@field full_service string # "package.Service" as reflection reports it
---@field rpcs string[]       # Create/Get/List…s/Update/Delete {PrefixName}
---@field entity string
---@field entity_fields string[]

---@class p6m.RestRoute
---@field method string
---@field path string
---@field status integer

---@class p6m.RestSurface
---@field base string         # "/api/v1/{prefix-name}s"
---@field routes p6m.RestRoute[]
---@field entity_fields string[]

---@class p6m.GraphqlSurface
---@field type_name string    # "{PrefixName}" (entity-named)
---@field queries string[]    # "{prefixName}", "{prefixName}s" — no get/list prefixes
---@field mutations string[]  # create/update/delete{PrefixName}
---@field entity_fields string[] # camelCase at the boundary

local p6m = {}

--- The casing oracle: derive every cased variant the standards reference from an answer key.
--- `suffix` defaults to "Service". Accepts any input shape ("User Details", "user-details", …).
---@param spec { prefix: string, suffix: string?, org: string?, solution: string? }
---@return p6m.Identity
function p6m.identity(spec) end

p6m.api = {}

--- Expected gRPC surface (S2) for an identity.
---@param id p6m.Identity
---@return p6m.GrpcSurface
function p6m.api.grpc_surface(id) end

--- Expected REST surface (S2) for an identity.
---@param id p6m.Identity
---@return p6m.RestSurface
function p6m.api.rest_surface(id) end

--- Expected GraphQL surface (S2) for an identity.
---@param id p6m.Identity
---@return p6m.GraphqlSurface
function p6m.api.graphql_surface(id) end

--- The platform env contract (S3): the var names every service must honor for a transport,
--- with the caller's concrete values merged in.
---@param id p6m.Identity
---@param transport "grpc"|"rest"|"graphql"
---@param values table<string, string>?
---@return table<string, string>
function p6m.env_contract(id, transport, values) end

return p6m
