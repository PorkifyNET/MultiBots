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

local run = modules.Simulator.new({
	seed = "SELL-UNSUPPORTED", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_supported", cost = 4, utility = 20,
				effect = { kind = "flat_mult", amount = 5 } },
		},
		unsupported = { Joker = { "j_unsupported", "j_negative_unsupported" } },
		planets = {}, deck_tools = {}, packs = {}, vouchers = {},
	},
}, modules)
run.jokers = { "j_unsupported", "j_supported", "j_negative_unsupported" }
run.joker_limit = 6
run.joker_editions.j_negative_unsupported = "negative"
local initial_money = run.money

modules.Simulator.visit_shop(run, {})

assert(#run.jokers == 1 and run.jokers[1] == "j_supported",
	"entering a shop should sell unsupported Jokers while retaining supported ones")
-- a Negative edition adds $5 to a Joker's cost (Card:set_cost,
-- card.lua), so it sells for $3 instead of $1.
assert(run.money == initial_money + 4 and run.joker_limit == 5,
	"selling unsupported Jokers should pay their sell values and release Negative slots")
local unsupported_sales = 0
for _, decision in ipairs(run.decisions) do
	if decision.type == "sell_joker" and decision.reason == "unsupported" then
		unsupported_sales = unsupported_sales + 1
	end
end
assert(unsupported_sales == 2, "each unsupported Joker sold at shop entry should be logged")

print("unsupported_sale_spec: ok")
