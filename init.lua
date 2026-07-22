-- prova-p6m — p6m platform standards as executable proofs — one parameterized suite every service archetype must pass.
--
-- A Prova plugin is just a module: `require("p6m")` returns this table, and whatever you hang
-- on it is the plugin's API. That's the entire contract — everything below is a starting point to
-- replace.
--
--   local p6m = require("p6m")
--   p6m.greet("world")            -- → "hello, world"
--
-- Two common shapes, when you're ready for them:
--
--   • A RESOURCE — an ephemeral container the suite talks to (docker-exec, zero native code):
--       local p6m = prova.containerized{
--         name = "p6m", image = "…", port = 1234,
--         url    = function(host_port) return "tcp://127.0.0.1:" .. host_port end,
--         client = function(url, opts, container) return make_client(container) end,
--       }
--     A consumer then does `require("p6m").container(ctx)`.
--
--   • A TOPOLOGY — a whole environment `prova up` can stand up. Advertise it in prova.toml:
--       [[plugin.topologies]]
--       name     = "…"        # the public name a project references in [topologies]
--       factory  = "…"        # the field on THIS table it resolves to
--       requires = ["…"]      # tools/daemons it needs — gates `prova up` and any test that uses it
--     and export that factory as `function(ctx, opts) … end` returning the live environment.

local p6m = {}

--- Replace me with the plugin's real API.
function p6m.greet(who)
  return "hello, " .. tostring(who)
end

return p6m
