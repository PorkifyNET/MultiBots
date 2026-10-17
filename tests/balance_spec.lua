local modules = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
modules = dofile("bot/expert.lua").modules(modules)   -- MultiBots' Expert decides

local minimum_ante_one_clears = { easy = 200, normal = 240, hard = 250, expert = 260 }
local maximum_progression_failures = { easy = 60, normal = 35, hard = 30, expert = 25 }

for _, difficulty in ipairs({ "easy", "normal", "hard", "expert" }) do
	local clears, attempts, total_ratio = 0, 0, 0
	local blind_clears = { Small = 0, Big = 0, Boss = 0 }
	for seed_index = 1, 100 do
		local state = modules.Simulator.new({
			seed = "BALANCE" .. seed_index,
			difficulty = difficulty,
			the_order = true,
		}, modules)
		modules.Simulator.set_ante(state, 1)
		for _, blind in ipairs({ { "Small", 300 }, { "Big", 450 }, { "Boss", 600 } }) do
			local result = modules.Simulator.play_round(state, blind[2], blind[1])
			attempts = attempts + 1
			if result.cleared then
				clears = clears + 1
				blind_clears[blind[1]] = blind_clears[blind[1]] + 1
			end
			total_ratio = total_ratio + result.score / blind[2]
		end
	end
	print(string.format("balance_probe %s clears=%d/%d small=%d big=%d boss=%d average_target_ratio=%.3f",
		difficulty, clears, attempts, blind_clears.Small, blind_clears.Big, blind_clears.Boss, total_ratio / attempts))
	assert(clears >= minimum_ante_one_clears[difficulty],
		difficulty .. " Ante 1 clear rate regressed: " .. clears .. "/" .. attempts)

	local full_failures, full_attempts = 0, 0
	for seed_index = 1, 25 do
		local state = modules.Simulator.new({
			seed = "FULLBALANCE" .. seed_index,
			difficulty = difficulty,
			the_order = true,
		}, modules)
		for ante = 1, 4 do
			modules.Simulator.set_ante(state, ante)
			local base = modules.Simulator.base_score(ante)
			for _, blind in ipairs({ { "Small", base }, { "Big", base * 1.5 } }) do
				local result = modules.Simulator.play_round(state, blind[2], blind[1])
				full_attempts = full_attempts + 1
				if not result.cleared then full_failures = full_failures + 1 end
				modules.Simulator.award_blind(state, blind[1], result)
				modules.Simulator.visit_shop(state)
			end
			if ante == 1 then
				local boss = modules.Simulator.play_round(state, base * 2, "Boss")
				full_attempts = full_attempts + 1
				if not boss.cleared then full_failures = full_failures + 1 end
				modules.Simulator.award_blind(state, "Boss", boss)
				modules.Simulator.visit_shop(state)
			else
				local pvp = modules.Simulator.play_round(state, nil, "Boss")
				modules.Simulator.award_blind(state, "Boss", pvp)
				modules.Simulator.visit_shop(state)
			end
		end
	end
	print(string.format("balance_progression %s failures=%d/%d", difficulty, full_failures, full_attempts))
	assert(full_failures <= maximum_progression_failures[difficulty],
		difficulty .. " progression failure rate regressed: " .. full_failures .. "/" .. full_attempts)
end

print("balance_spec: ok")
