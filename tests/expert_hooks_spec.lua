-- Decision hooks for external policies (bot/expert.lua lists them): every hook
-- is honoured, and the shops of a run depend only on what was done in them,
-- not on whether the Expert's code ran.
local base = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
base = dofile("bot/expert.lua").modules(base)   -- MultiBots' Expert decides
local Simulator = base.Simulator

local function with_policy(policy)
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	modules.Policy = setmetatable(policy, { __index = base.Policy })
	return modules
end

-- A short headless run through the drivers' shop loop; returns the run and the
-- keys of every shop visit.
local function play(modules, seed, antes)
	local state = Simulator.new({ seed = seed, difficulty = "hard", the_order = true,
		content_catalog = base.Content.defaults() }, modules)
	local shops = {}
	local function shop()
		local report = Simulator.shop_phase(state, nil, {
			visit = function(keys)
				local visit = Simulator.visit_shop(state, keys)
				shops[#shops + 1] = table.concat(visit.keys, ",")
				return visit
			end,
		})
		return report
	end
	for ante = 1, antes do
		Simulator.set_ante(state, ante)
		local target = Simulator.base_score(ante)
		for _, blind in ipairs({ { "Small", target }, { "Big", target * 1.5 }, { "Boss", target * 2 } }) do
			Simulator.award_blind(state, blind[1], Simulator.play_round(state, blind[2], blind[1]))
			shop()
		end
	end
	return state, shops
end

-- 1. The Expert's shop decisions, replayed by a policy that never runs the
-- Expert's shop code, give the same shops and the same run (The Order's shop
-- counter does not depend on the Expert's decision draws).
local recorded = {}
local expert_run, expert_shops = play(with_policy({
	shop_step = function(state, ctx)
		local index, meta = base.Policy.shop_step(state, ctx)
		recorded[#recorded + 1] = index
		return index, meta
	end,
}), "*HOOKS-REPLAY", 3)
local cursor = 0
local replay_run, replay_shops = play(with_policy({
	shop_step = function()
		cursor = cursor + 1
		return recorded[cursor]
	end,
}), "*HOOKS-REPLAY", 3)
assert(cursor == #recorded and #recorded > 0, "the replay makes every recorded shop decision")
assert(table.concat(expert_shops, "|") == table.concat(replay_shops, "|"), "same shops without the Expert's shop code")
assert(expert_run.money == replay_run.money and table.concat(expert_run.jokers, ",") == table.concat(replay_run.jokers, ","),
	"the replayed run ends like the Expert's")

-- 2. A random external policy that makes every decision through the hooks.
local function random_policy(seed, real_rules)
	local rng = base.PRNG.new(seed)
	local counts = {}
	local function pick(name, actions)
		counts[name] = (counts[name] or 0) + 1
		return rng:integer(1, #actions)
	end
	local function shuffled(list)
		local out = {}
		for i, value in ipairs(list) do out[i] = value end
		for i = #out, 2, -1 do
			local j = rng:integer(1, i)
			out[i], out[j] = out[j], out[i]
		end
		return out
	end
	local policy = {
		shop_open = function(_, ctx) return pick("shop_open", ctx.actions) > 1 and rng:next() < 0.1 and 2 or 1 end,
		shop_step = function(_, ctx) return pick("shop_step", ctx.actions) end,
		reroll_step = function() counts.reroll_step = (counts.reroll_step or 0) + 1; return rng:next() < 0.3 end,
		pack_step = function(_, ctx) return pick("pack_step", ctx.actions) end,
		consumable_step = function(_, ctx) return pick("consumable_step", ctx.actions) end,
		target_step = function(_, ctx)
			for _, action in ipairs(ctx.actions) do
				assert(action.type ~= "none" or not real_rules, "no target-less use under the real rules")
			end
			return pick("target_step", ctx.actions)
		end,
		skip_pair = function() counts.skip_pair = (counts.skip_pair or 0) + 1; return rng:next() < 0.2, rng:next() < 0.2 end,
		joker_order = function(state, ctx)
			counts.joker_order = (counts.joker_order or 0) + 1
			local order = shuffled(state.jokers)
			return order, ctx.evaluate_order(order)
		end,
		arrange_jokers = function(state)
			counts.arrange_jokers = (counts.arrange_jokers or 0) + 1
			return shuffled(state.jokers)
		end,
		observe = function(state, event, data)
			counts.observe = (counts.observe or 0) + 1
			if event ~= "turn" then base.Policy.observe(state, event, data) end
			if event == "new" and real_rules then state.expert_compat = nil end
		end,
		choose_turn = function(args)
			counts.choose_turn = (counts.choose_turn or 0) + 1
			local count = math.min(#args.hand, rng:integer(1, 5))
			local indices = {}
			for index, position in ipairs(shuffled((function()
				local all = {}
				for i = 1, #args.hand do all[i] = i end
				return all
			end)())) do
				if index <= count then indices[#indices + 1] = position end
			end
			table.sort(indices)
			if args.discards_left > 0 and rng:next() < 0.3 then return { type = "discard", indices = indices } end
			local cards = {}
			for i, index in ipairs(indices) do cards[i] = args.hand[index] end
			return { type = "play", indices = indices, result = args.evaluate(cards, args.hand) }
		end,
	}
	return policy, counts
end

for _, real_rules in ipairs({ true, false }) do
	local policy, counts = random_policy("RANDOM-" .. tostring(real_rules), real_rules)
	local modules = with_policy(policy)
	local state = Simulator.new({ seed = "*HOOKS-RANDOM", difficulty = "normal", the_order = true,
		content_catalog = base.Content.defaults() }, modules)
	state.money = 60
	for ante = 1, 3 do
		Simulator.set_ante(state, ante)
		local skipped = Simulator.plan_skips(state, "reactive", { Small = "tag_economy", Big = "tag_negative" })
		local target = Simulator.base_score(ante)
		for _, blind in ipairs({ { "Small", target }, { "Big", target * 1.5 }, { "Boss", target * 2 } }) do
			if not skipped[blind[1]] then
				Simulator.award_blind(state, blind[1], Simulator.play_round(state, blind[2], blind[1]))
				Simulator.shop_phase(state)
			end
		end
	end
	for _, name in ipairs({ "shop_open", "shop_step", "reroll_step", "skip_pair", "joker_order",
		"arrange_jokers", "observe", "choose_turn" }) do
		assert((counts[name] or 0) > 0, "the " .. name .. " hook is asked")
	end
	assert(state.money >= -Simulator.debt_limit(state), "money stays within the debt limit")
end

-- 3. The rules reject what a hook cannot do.
local bad = with_policy({ arrange_jokers = function() return { "j_joker", "j_joker" } end })
local bad_state = Simulator.new({ seed = "HOOKS-BAD", content_catalog = base.Content.defaults() }, bad)
bad_state.jokers = { "j_joker", "j_jolly" }
assert(not pcall(Simulator.begin_round, bad_state, 300, "Small"), "an order that is not a permutation is an error")

print("expert_hooks_spec: ok")
