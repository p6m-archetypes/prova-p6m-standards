# prova-p6m

A plugin for [Prova](https://github.com/prova-rs/prova) — p6m platform standards as executable proofs — one parameterized suite every service archetype must pass.

In Prova a **package** is one `prova.toml`-rooted unit; it can act as a **plugin** (exports a
namespace) and a **suite** (runs its own proofs). This repo is such a package — author the plugin in
`init.lua`, prove it in `proofs/`, ship both.

## Use it


Declare it in your project's `prova.toml`, pinned to a released tag:

```toml
[plugins]
p6m = { git = "https://github.com/p6m-archetypes/prova-p6m-standards", tag = "v1" }
```

Then `require` it in a test:


```lua
local p6m = require("p6m")

prova.test("does the thing", function(t)
  t:expect(p6m.greet("world")):equals("hello, world")
end)
```

## What to build

The generated `init.lua` returns a table whose fields are the API. Two common shapes it can grow into:

- **A resource** — an ephemeral container the suite talks to (`prova.containerized`, docker-exec, zero
  native code); a consumer does `require("p6m").container(ctx)`.
- **A topology** — a whole environment `prova up` can stand up, advertised via `[[plugin.topologies]]`
  in `prova.toml` and gated on the tools it needs.

`init.lua` carries commented starting points for both.

## Develop

```bash
prova                        # run the self-test in proofs/ (hermetic by default)
prova plugin lint init.lua   # check the plugin conforms to the namespacing grammar
```


The **Test** workflow runs the self-test on every push; the **Release** workflow (dispatched
manually) tags the next version so consumers can pin `p6m-archetypes/prova-p6m-standards@vX.Y.Z`.

MIT licensed.

