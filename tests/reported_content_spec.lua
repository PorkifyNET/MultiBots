local modules = {
	PRNG = dofile("bot/prng.lua"), Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"), Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"), Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"), Order = dofile("bot/order.lua"),
}

local catalog = modules.Content.build({ Joker = {
	{ key = "j_madness" }, { key = "j_joker" }, { key = "j_mp_taxes" },
	{ key = "j_mp_pizza" }, { key = "j_to_the_moon" },
} }, {}, {})

local madness = modules.Simulator.new({ seed = "REPORTED-MADNESS", content_catalog = catalog }, modules)
madness.jokers = { "j_madness", "j_joker" }
modules.Simulator.begin_round(madness, 300, "Small")
assert(#madness.jokers == 1 and madness.jokers[1] == "j_madness"
	and madness.joker_state.j_madness == 1.5,
	"Madness should gain X0.5 and destroy another Joker on a non-Boss Blind")

local taxes = modules.Simulator.new({ seed = "REPORTED-TAXES", content_catalog = catalog }, modules)
taxes.jokers = { "j_mp_taxes" }
assert(modules.Simulator.apply_pvp_effect(taxes, "soldJoker")
	and modules.Simulator.apply_pvp_effect(taxes, "soldJoker"),
	"opponent Joker sales should be accepted as PvP effects")
modules.Simulator.begin_round(taxes, nil, "PvP")
assert(taxes.joker_state.j_mp_taxes == 8,
	"Taxes should bank +4 Mult for each opponent sale when PvP starts")

local pizza = modules.Simulator.new({ seed = "REPORTED-PIZZA", content_catalog = catalog }, modules)
pizza.jokers = { "j_mp_pizza" }
local pvp = modules.Simulator.begin_round(pizza, nil, "PvP")
modules.Simulator.finish_round(pvp)
assert(#pizza.jokers == 0 and pizza.pizza_discards == 2,
	"Pizza should be consumed after PvP and queue two discards")
modules.Simulator.set_ante(pizza, 2)
local next_blind = modules.Simulator.begin_round(pizza, 800, "Small")
assert(next_blind.discards_left == pizza.discards_per_round + 2,
	"Pizza's queued discards should apply to the next ante")

local moon = modules.Simulator.new({ seed = "REPORTED-MOON", content_catalog = catalog }, modules)
moon.jokers = { "j_to_the_moon" }
moon.money = 10
modules.Simulator.award_blind(moon, "Small", {
	cleared = true, hands_left = 0, discards_left = 0, discards_available = 3,
})
assert(moon.money == 17, "To the Moon should add one extra dollar per interest step")

print("reported_content_spec: ok")
