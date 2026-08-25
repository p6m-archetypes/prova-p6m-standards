---@meta p6m
--- prova-p6m-standards — p6m platform standards as executable proofs.
---
--- Editor-only type stub for `require("p6m")`: it gives consumers completion and signatures
--- and ships nothing at runtime. Keep it in sync with init.lua's public API as the plugin grows.

---@class p6m.Identity
---@field answers { project_name: string, entity_name: string } the raw answer key, for renders
--- The project — repo, directory, image, PlatformApplication, gRPC service.
--- NOTE `project_name` is KEBAB here (what the repo is actually called); archetect's key of the
--- same name expands to snake. The snake form is `project_snake`.
---@field project_name string  # "user-details-service"
---@field project_snake string # "user_details_service"
---@field ProjectName string   # "UserDetailsService"
---@field projectName string   # "userDetailsService"
--- The entity — the CRUD subject. S2: entity-named, not service-named.
---@field entity_name string   # "user-details"
---@field entity_snake string  # "user_details"
---@field EntityName string    # "UserDetails"
---@field entityName string    # "userDetails"
---@field solution string?     # "acme-platform" (when a solution is given)
--- Retiring aliases of the fields above (YP6M-3424) — kept while the hand-rolled suites convert
--- onto the shape harnesses. Same values, one derivation; do not author against them.
---@field PrefixName string    # deprecated → EntityName
---@field prefixName string    # deprecated → entityName
---@field prefix_kebab string  # deprecated → entity_name
---@field prefix_name string   # deprecated → entity_snake
---@field PascalFull string    # deprecated → ProjectName
---@field snake_full string    # deprecated → project_snake
---@field org_solution string? # deprecated → solution

---@class p6m.GrpcSurface
---@field package string      # flat "{project_snake}"
---@field service string      # "{ProjectName}"
---@field full_service string # "package.Service" as reflection reports it
---@field rpcs string[]       # Create/Get/List…s/Update/Delete {EntityName}
---@field entity string
---@field entity_fields string[]

---@class p6m.RestRoute
---@field method string
---@field path string
---@field status integer

---@class p6m.RestSurface
---@field base string         # "/api/v1/{entity-name}s"
---@field routes p6m.RestRoute[]
---@field entity_fields string[]

---@class p6m.GraphqlSurface
---@field type_name string    # "{EntityName}" (entity-named)
---@field queries string[]    # "{entityName}", "{entityName}s" — no get/list prefixes
---@field mutations string[]  # create/update/delete{EntityName}
---@field entity_fields string[] # camelCase at the boundary

local p6m = {}

--- The identity oracle. TAKES the two names an archetype was answered with and cases them; it
--- derives nothing — p6m-identity-library owns the one rule that defaults an entity off a project
--- name, and two implementations of it would drift. `entity` omitted means the shape has no domain
--- entity (overlay, basic), not "guess". Accepts any input shape ("User Details", "user-details").
---@param spec { project: string, entity: string?, solution: string? }
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
-- p6m.empty — the retrofit overlay archetypes, E1–E7 (docs/standards.md §2b)
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

--- E7: the archetype repo's own suite + CI hygiene. The released-tag bar is a standing REMINDER
--- (tag `p6m-pin`): DUE while the p6m pin rides a moving ref, silent on a released tag; heed it
--- (`--heed=p6m-pin`) when the iteration window closes.
---@param g any
---@param opts { root: string? }?
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
---@param opts { source: string?, root: string?, catalog: string[]? }?
function p6m.empty.standards.archetype(g, s, opts) end

--- E7's released-tag bar as a standing REMINDER (tag `p6m-pin`): DUE while the p6m pin rides a
--- moving ref, silent on a released tag. Call once at FILE ROOT, beside — never inside — a group.
---@param opts { root: string? }?
function p6m.pin_reminder(opts) end

return p6m
