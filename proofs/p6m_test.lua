-- Self-test for prova-p6m. `require("p6m")` resolves to THIS plugin — prova.toml
-- declares it as a path plugin at "." — so the suite proves the plugin exactly the way a consumer
-- uses it. Hermetic by default (no docker, no network): the bar the plugin must always clear.
--
-- As you grow the plugin, gate the tests that touch a real resource with `{ requires = { "docker" } }`
-- (or the tool your topology needs), so they skip cleanly where it's absent instead of failing.
local p6m = require("p6m")

prova.test("greets by name", function(t)
  t:expect(p6m.greet("world")):equals("hello, world")
end)
