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

---@class p6m.CiStack
---@field image string      # the toolchain image the commands run in
---@field commands string[] # the exact p6m-actions setup+build command sequence, in order

p6m.ci = {}

--- The CI command sequences (S10), per stack — the one place each rendered build.yaml's
--- setup/build steps are mirrored (p6m-actions pairs, or the community-action inline steps
--- golang/rust still run). Keys: "pnpm", "dotnet", "python", "java", "golang", "rust".
---@type table<string, p6m.CiStack>
p6m.ci.stacks = {}

--- The throwaway CI-parity Dockerfile text for a stack (S10): toolchain base, clean-render
--- context, one RUN per CI command. Pure — hermetically assertable.
---@param stack p6m.CiStack
---@param opts { image: string? }?
---@return string
function p6m.ci.dockerfile(stack, opts) end

------------------------------------------------------------------------------------------
-- p6m.empty — the overlay ("empty") archetypes, E1–E7 (docs/standards.md §2b)
------------------------------------------------------------------------------------------

---@class p6m.OverlaySpec
---@field language string           # "rust" | "java" | "golang" | "python" | "typescript" | "dotnet"
---@field application string        # kebab: the image name, PlatformApplication name, CD directory
---@field application_snake string
---@field ApplicationName string
---@field solution string           # kebab solution slug — the namespace prefix
---@field registry string
---@field protocol string           # "REST" | "gRPC" | "GraphQL"
---@field service_port integer
---@field management_port integer
---@field persistence string
---@field cache string
---@field messaging string
---@field messaging_access string
---@field extras string[]           # paths beyond the common layer this archetype declares
---@field port_env_key string       # "SERVER_PORT" | "GRPC_PORT"
---@field port_protocol string      # "http" | "grpc"
---@field image_repository string   # "{registry}/{solution}/{application}"
---@field image string              # …":latest"
---@field required_answers table<string,any> # the three facts with no sane default (E2)
---@field answers table<string,any>          # required + the defaulted selections a variant exercises
---@field allowed string[]                   # E3's allowlist: platform layer + extras
---@field label string

p6m.empty = {}

--- E3: the COMPLETE set of paths an overlay may write. An allowlist, not a denylist of guessed
--- scaffolding names.
---@type string[]
p6m.empty.PLATFORM_LAYER = {}

--- The environments the manifests overlay, in promotion order.
---@type string[]
p6m.empty.ENVIRONMENTS = {}

--- E1: the overlay answer key and everything derived from it. `application` is the only name asked;
--- accepts any input shape. No prefix/suffix, no org × solution split, no author identity.
---@param o { language: string, application: string, solution: string, registry: string,
---           protocol: string?, service_port: integer?, management_port: integer?,
---           persistence: string?, cache: string?, messaging: string?, messaging_access: string?,
---           extras: string[]? }
---@return p6m.OverlaySpec
function p6m.empty.spec(o) end

--- `{solution}-{application}-{env}` — the namespace the platform reads solution + env back out of.
---@param s p6m.OverlaySpec
---@param env string
---@return string
function p6m.empty.namespace(s, env) end

--- The `resourceRequirements` the selected resources must produce, in manifest order (E6).
---@param s p6m.OverlaySpec
---@return { resourceType: string, resourceName: string, scope: string?, access: string? }[]
function p6m.empty.resource_requirements(s) end

--- The shared render fixture: one headless render with `defaults = false`, so a prompt outside the
--- tactical key errors instead of being papered over (E2).
---@param s p6m.OverlaySpec
---@param opts { source: string?, scope: any?, answers: table? }?
---@return prova.Fixture
function p6m.empty.render(s, opts) end

--- The paths a rendering intended to write, relative to its root and sorted (E3/E4's raw material).
---@param rendering prova.RenderResult
---@return string[]
function p6m.empty.written(rendering) end

p6m.empty.standards = {}

--- E3: the render is the platform servicing layer — all of it, nothing else, nothing at the repo
--- root but dotfiles, no leftover template markers.
---@param g any group builder
---@param project prova.Fixture
---@param s p6m.OverlaySpec
function p6m.empty.standards.layout(g, project, s) end

--- E6: the platform manifests say what the answers imply (env contract, image, ports, readiness,
--- resourceRequirements, per-environment namespaces).
---@param g any
---@param project prova.Fixture
---@param s p6m.OverlaySpec
function p6m.empty.standards.manifests(g, project, s) end

--- E5: the CI/CD wiring agrees with itself — every assertion spans two artifacts. `opts.cd_spec`
--- authors the three CD-dependent tests as open specs, for a language whose ci-library still stops
--- at build and so has no publish/dispatch step to be consistent with.
---@param g any
---@param project prova.Fixture
---@param s p6m.OverlaySpec
---@param opts { cd_spec: string? }?
function p6m.empty.standards.cicd(g, project, s, opts) end

--- E2: the prompt surface is the tactical minimum — a render from the required facts alone, plus
--- the declared composition surface for the defaulted prompts a render cannot observe.
---@param g any
---@param s p6m.OverlaySpec
---@param opts { source: string?, root: string?, catalog: string[]? }?
function p6m.empty.standards.prompt_surface(g, s, opts) end

--- E4: retrofit is additive and non-destructive — every pre-existing byte survives.
---@param g any
---@param s p6m.OverlaySpec
---@param opts { source: string?, legacy: table<string,string>?, hygiene: table<string,string>? }?
function p6m.empty.standards.retrofit(g, s, opts) end

--- E7: the archetype repo's own suite + CI hygiene. `opts.pin_spec` authors the released-tag
--- assertion as an open spec with that reason.
---@param g any
---@param opts { root: string?, pin_spec: string? }?
function p6m.empty.standards.hygiene(g, opts) end

--- Everything that is a function of ONE answer set (E3–E6): invoke per variant.
---@param g any
---@param project prova.Fixture
---@param s p6m.OverlaySpec
---@param opts { source: string?, legacy: table<string,string>?, hygiene: table<string,string>?,
---              cd_spec: string? }?
function p6m.empty.standards.rendering(g, project, s, opts) end

--- Everything that is a property of the ARCHETYPE REPO rather than of a variant (E2, E7): invoke
--- once, whatever the variant count.
---@param g any
---@param s p6m.OverlaySpec
---@param opts { source: string?, root: string?, catalog: string[]?, pin_spec: string? }?
function p6m.empty.standards.archetype(g, s, opts) end

return p6m
