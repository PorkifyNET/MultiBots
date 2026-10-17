local modules = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
	Order = dofile("bot/order.lua"),
}
modules = dofile("bot/expert.lua").modules(modules)   -- MultiBots' Expert decides

local state = modules.Simulator.new({
	seed = "CELESTIAL", difficulty = "expert", the_order = true,
}, modules)
state.money = 26
modules.Simulator.set_ante(state, 2)
modules.Simulator.visit_shop(state, { "p_celestial_jumbo_1" })

local pack_decision
for _, decision in ipairs(state.decisions) do
	if decision.type == "buy_pack" then pack_decision = decision; break end
end

assert(pack_decision and pack_decision.supported:find("c_earth", 1, true)
	and pack_decision.supported:find("c_mars", 1, true)
	and pack_decision.supported:find("c_pluto", 1, true),
	"Celestial Pack decisions should expose all supported Planets, not only sampled choices")

print("pack_support_spec: ok")
