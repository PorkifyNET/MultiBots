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
modules = dofile("bot/expert.lua").modules(modules)

local pool = {
	{ key = "j_negative_keep", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
	{ key = "j_keep_a", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
	{ key = "j_keep_b", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
	{ key = "j_keep_c", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
	{ key = "j_keep_d", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
	{ key = "j_bonus_filler", cost = 4, utility = 8, effect = { kind = "flat_mult", amount = 2 } },
}
local state = modules.Simulator.new({
	seed = "NEGATIVE-SLOT", difficulty = "expert", the_order = true, joker_pool = pool,
}, modules)
state.jokers = { "j_negative_keep", "j_keep_a", "j_keep_b", "j_keep_c", "j_keep_d" }
state.joker_editions.j_negative_keep = "negative"
state.joker_limit = 6
state.money = 20
state.planet_pool, state.deck_tools = {}, {}
modules.Simulator.set_ante(state, 4)
modules.Simulator.visit_shop(state, { "j_bonus_filler" })

local found = false
for _, key in ipairs(state.jokers) do
	if key == "j_bonus_filler" then found = true; break end
end
assert(#state.jokers == 6 and found,
	"a positive Joker should fill capacity created by an owned Negative Joker")

print("negative_joker_slot_spec: ok")
