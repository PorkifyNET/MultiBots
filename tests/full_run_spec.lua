local modules = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
modules = dofile("bot/expert.lua").modules(modules)   -- MultiBots' Expert decides

local snapshots = modules.Simulator.run({
	seed = "FULLRUN",
	difficulty = "normal",
	max_ante = 64,
	the_order = true,
}, modules)

assert(#snapshots == 64, "full simulation should produce 64 ante snapshots")
for ante = 1, 64 do assert(#snapshots[ante].hands > 0, "ante " .. ante .. " has no bot hands") end

print("full_run_spec: ok")
