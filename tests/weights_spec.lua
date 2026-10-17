local base = {
	PRNG = dofile("bot/prng.lua"), Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"), Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"), Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
base = dofile("bot/expert.lua").modules(base)   -- MultiBots' Expert decides
local weighted = {}
for key, value in pairs(base) do weighted[key] = value end
weighted.Weights = dofile("bot/weights.lua")

local function run(dependencies, weights)
	return dependencies.Simulator.run({
		seed = "DEFAULT-WEIGHTS", difficulty = "expert", max_ante = 2,
		the_order = true, weights = weights,
	}, dependencies)
end

local old_rounds, old_state = run(base)
local new_rounds, new_state = run(weighted, weighted.Weights.defaults)
assert(old_state.money == new_state.money, "default weights changed ending money")
assert(table.concat(old_state.jokers, ",") == table.concat(new_state.jokers, ","),
	"default weights changed Joker purchases")
for ante = 1, 2 do
	assert(#old_rounds[ante].hands == #new_rounds[ante].hands, "default weights changed hand count")
	for index, hand in ipairs(old_rounds[ante].hands) do
		assert(hand.score == new_rounds[ante].hands[index].score, "default weights changed scores")
		assert(hand.hand == new_rounds[ante].hands[index].hand, "default weights changed hand choices")
	end
end
local valid, errors = weighted.Weights.validate({ immediate_score = 1.25 })
assert(valid and #errors == 0 and valid.immediate_score == 1.25, "valid weight rejected")
local invalid = weighted.Weights.validate({ immediate_score = 99 })
assert(not invalid, "out-of-range weight accepted")
print("weights_spec: ok")
