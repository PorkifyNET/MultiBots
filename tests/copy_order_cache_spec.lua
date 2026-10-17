local modules = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
	Order = dofile("bot/order.lua"),
	Weights = dofile("bot/weights.lua"),
}

local state = modules.Simulator.new({
	seed = "COPY-CACHE", difficulty = "expert", joker_limit = 7,
}, modules)
state.jokers = { "j_blueprint", "j_joker", "j_cavendish" }
local session = modules.Simulator.begin_round(state, 1000000000, "Small")
session.discards_left = 0

local resolved_order_count = 0
local resolve_jokers = modules.Evaluator.resolve_jokers
local evaluation_count = 0
local evaluate = modules.Evaluator.evaluate
modules.Evaluator.resolve_jokers = function(...)
	resolved_order_count = resolved_order_count + 1
	return resolve_jokers(...)
end
modules.Evaluator.evaluate = function(...)
	evaluation_count = evaluation_count + 1
	return evaluate(...)
end
local step_ok, step_error = pcall(modules.Simulator.step_round, session)
modules.Evaluator.resolve_jokers = resolve_jokers
modules.Evaluator.evaluate = evaluate

assert(step_ok, step_error)
assert(resolved_order_count == 6,
	"each distinct copy-Joker order should be resolved once across all play candidates")
assert(evaluation_count > 42,
	"multiple candidate plays should reuse the resolved copy-Joker orders")

print("copy_order_cache_spec: ok")
