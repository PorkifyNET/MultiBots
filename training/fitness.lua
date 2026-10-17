local Fitness = {}
local unpack_values = table.unpack or unpack

local function number(value) return tonumber(value) or 0 end

local function fresh_metrics()
	return {
		runs = 0, completed_runs = 0, blind_attempts = 0, blind_clears = 0,
		ante_reached_total = 0, score_margin_total = 0, score_margin_samples = 0,
		failed_blinds = 0, failed_deficit_total = 0,
		failed_with_unused_hands = 0, failed_with_unused_discards = 0,
		failed_with_unused_consumables = 0, ending_money_total = 0,
		pvp_rounds = 0, pvp_wins = 0, invalid_actions = 0, crashes = 0,
		known_regression_failures = 0, ante_attempts = {}, ante_clears = {},
	}
end

local raw_metric_keys = {
	"runs", "completed_runs", "blind_attempts", "blind_clears", "ante_reached_total",
	"score_margin_total", "score_margin_samples", "failed_blinds", "failed_deficit_total",
	"failed_with_unused_hands", "failed_with_unused_discards", "failed_with_unused_consumables",
	"ending_money_total", "pvp_rounds", "pvp_wins", "invalid_actions", "crashes",
}

local function merge_metrics(target, source)
	for _, key in ipairs(raw_metric_keys) do target[key] = target[key] + number(source[key]) end
	for ante, count in pairs(source.ante_attempts or {}) do
		target.ante_attempts[ante] = (target.ante_attempts[ante] or 0) + count
	end
	for ante, count in pairs(source.ante_clears or {}) do
		target.ante_clears[ante] = (target.ante_clears[ante] or 0) + count
	end
end

local function invalid_state(state)
	if not state or type(state.money) ~= "number" or state.money ~= state.money
		or state.money == math.huge or state.money == -math.huge then return true end
	if type(state.jokers) ~= "table" or type(state.deck) ~= "table" then return true end
	return false
end

local function record_blind(metrics, ante, result)
	metrics.blind_attempts = metrics.blind_attempts + 1
	metrics.ante_attempts[ante] = (metrics.ante_attempts[ante] or 0) + 1
	local target, score = number(result.target), number(result.score)
	if result.cleared then
		metrics.blind_clears = metrics.blind_clears + 1
		metrics.ante_clears[ante] = (metrics.ante_clears[ante] or 0) + 1
	else
		metrics.failed_blinds = metrics.failed_blinds + 1
		if target > 0 then metrics.failed_deficit_total = metrics.failed_deficit_total
			+ math.max(0, (target - score) / target) end
		if number(result.hands_left) > 0 then metrics.failed_with_unused_hands = metrics.failed_with_unused_hands + 1 end
		if number(result.discards_left) > 0 then
			metrics.failed_with_unused_discards = metrics.failed_with_unused_discards + 1
		end
		if number(result.consumables_remaining) > 0 then
			metrics.failed_with_unused_consumables = metrics.failed_with_unused_consumables + 1
		end
	end
	if target > 0 then
		metrics.score_margin_total = metrics.score_margin_total + (score - target) / target
		metrics.score_margin_samples = metrics.score_margin_samples + 1
	end
end

local function finalize(metrics, fitness_weights)
	local runs = math.max(1, metrics.runs)
	local attempts = math.max(1, metrics.blind_attempts)
	local failed = math.max(1, metrics.failed_blinds)
	metrics.blind_clear_rate = metrics.blind_clears / attempts
	metrics.average_ante = metrics.ante_reached_total / runs
	metrics.survival_rate = metrics.completed_runs / runs
	metrics.average_score_margin = metrics.score_margin_total / math.max(1, metrics.score_margin_samples)
	metrics.average_failed_blind_deficit = metrics.failed_deficit_total / failed
	metrics.average_ending_money = metrics.ending_money_total / runs
	metrics.pvp_win_rate = metrics.pvp_wins / math.max(1, metrics.pvp_rounds)
	for ante, count in pairs(metrics.ante_attempts) do
		metrics["ante" .. tostring(ante) .. "_clear"] = (metrics.ante_clears[ante] or 0) / math.max(1, count)
	end
	local terms = {
		blind_clear_rate = metrics.blind_clear_rate,
		average_ante = metrics.average_ante,
		survival_rate = metrics.survival_rate,
		average_score_margin = metrics.average_score_margin,
		failed_blind_deficit = metrics.average_failed_blind_deficit,
		failed_with_unused_hands = metrics.failed_with_unused_hands,
		failed_with_unused_discards = metrics.failed_with_unused_discards,
		failed_with_unused_consumables = metrics.failed_with_unused_consumables,
		average_ending_money = metrics.average_ending_money,
		pvp_win_rate = metrics.pvp_win_rate,
		invalid_actions = metrics.invalid_actions,
		crashes = metrics.crashes,
		known_regression_failures = metrics.known_regression_failures,
	}
	local fitness, contributions = 0, {}
	for key, value in pairs(terms) do
		local contribution = value * number(fitness_weights[key])
		contributions[key] = contribution
		fitness = fitness + contribution
	end
	metrics.fitness_contributions = contributions
	return fitness
end

local function evaluate_seed(seed, weights, config, dependencies, opponent, metrics)
	metrics.runs = metrics.runs + 1
	local state = dependencies.Simulator.new({
		seed = seed, difficulty = config.difficulty or "expert", the_order = true,
		weights = weights, content_catalog = dependencies.Content and dependencies.Content.defaults() or nil,
	}, dependencies)
	local reached, alive = 0, true
	for ante = 1, tonumber(config.max_ante) or 5 do
		reached = ante
		dependencies.Simulator.set_ante(state, ante)
		local base = dependencies.Simulator.base_score(ante)
		for _, blind in ipairs({ { "Small", base }, { "Big", base * 1.5 } }) do
			local result = dependencies.Simulator.play_round(state, blind[2], blind[1])
			record_blind(metrics, ante, result)
			dependencies.Simulator.award_blind(state, blind[1], result)
			dependencies.Simulator.visit_shop(state)
			if not result.cleared and config.stop_on_failed_blind ~= false then alive = false; break end
		end
		if not alive then break end
		if ante == 1 then
			local boss = dependencies.Simulator.play_round(state, base * 2, "Boss")
			record_blind(metrics, ante, boss)
			dependencies.Simulator.award_blind(state, "Boss", boss)
			dependencies.Simulator.visit_shop(state)
			if not boss.cleared and config.stop_on_failed_blind ~= false then alive = false; break end
		else
			local pvp = dependencies.Simulator.play_round(state, nil, "Boss", "PvP")
			local opponent_score = opponent.score({
				ante = ante, base_score = base, bot_score = pvp.score, state = state,
			})
			metrics.pvp_rounds = metrics.pvp_rounds + 1
			if number(pvp.score) >= number(opponent_score) then metrics.pvp_wins = metrics.pvp_wins + 1 end
			dependencies.Simulator.record_pvp_outcome(state, pvp.score, opponent_score)
			pvp.life_lost = number(pvp.score) < number(opponent_score)
			dependencies.Simulator.award_blind(state, "Boss", pvp)
			dependencies.Simulator.visit_shop(state)
		end
		if invalid_state(state) then metrics.invalid_actions = metrics.invalid_actions + 1; alive = false; break end
	end
	metrics.ante_reached_total = metrics.ante_reached_total + reached
	metrics.ending_money_total = metrics.ending_money_total + number(state.money)
	if alive and reached >= (tonumber(config.max_ante) or 5) then metrics.completed_runs = metrics.completed_runs + 1 end
end

function Fitness.evaluate(weights, seeds, config, dependencies, opponent, progress_label)
	local metrics = fresh_metrics()
	local per_seed = {}
	local seed_list = seeds or {}
	for index, seed in ipairs(seed_list) do
		local started_at = os.clock()
		if config.on_match_progress then
			config.on_match_progress(progress_label, "start", index, #seed_list, seed)
		end
		local seed_metrics = fresh_metrics()
		local ok = pcall(evaluate_seed, seed, weights, config, dependencies, opponent, seed_metrics)
		if not ok then seed_metrics.crashes = seed_metrics.crashes + 1 end
		seed_metrics.known_regression_failures = tonumber(config.known_regression_failures) or 0
		local seed_fitness = finalize(seed_metrics, config.fitness_weights or {})
		per_seed[#per_seed + 1] = {
			seed = seed, fitness = seed_fitness,
			survival = seed_metrics.survival_rate,
			clear_rate = seed_metrics.blind_clear_rate,
			ante_reached = seed_metrics.average_ante,
			failed_blind_deficit = seed_metrics.average_failed_blind_deficit,
			average_score_margin = seed_metrics.average_score_margin,
			crashes = seed_metrics.crashes,
			invalid_actions = seed_metrics.invalid_actions,
		}
		merge_metrics(metrics, seed_metrics)
		if config.on_match_progress then
			config.on_match_progress(progress_label, "finish", index, #seed_list, seed,
				os.clock() - started_at, ok)
		end
	end
	metrics.known_regression_failures = tonumber(config.known_regression_failures) or 0
	local fitness = finalize(metrics, config.fitness_weights or {})
	return { fitness = fitness, metrics = metrics, per_seed = per_seed }
end

local function median(values)
	local sorted = {}
	for index, value in ipairs(values) do sorted[index] = value end
	table.sort(sorted)
	local count = #sorted
	if count == 0 then return 0 end
	if count % 2 == 1 then return sorted[(count + 1) / 2] end
	return (sorted[count / 2] + sorted[count / 2 + 1]) / 2
end

function Fitness.compare_evaluations(baseline, candidate, options)
	options = options or {}
	local rows, deltas = {}, {}
	local baseline_by_seed = {}
	for _, row in ipairs(baseline.per_seed or {}) do baseline_by_seed[tostring(row.seed)] = row end
	local wins, losses, ties, sum = 0, 0, 0, 0
	local epsilon = math.max(0, tonumber(options.tie_epsilon) or 0)
	for _, candidate_row in ipairs(candidate.per_seed or {}) do
		local baseline_row = assert(baseline_by_seed[tostring(candidate_row.seed)],
			"candidate seed missing from baseline evaluation: " .. tostring(candidate_row.seed))
		local delta = candidate_row.fitness - baseline_row.fitness
		local winner
		if delta > epsilon then winner, wins = "candidate", wins + 1
		elseif delta < -epsilon then winner, losses = "baseline", losses + 1
		else winner, ties = "tie", ties + 1 end
		deltas[#deltas + 1], sum = delta, sum + delta
		rows[#rows + 1] = {
			seed = candidate_row.seed,
			baseline_fitness = baseline_row.fitness, candidate_fitness = candidate_row.fitness,
			delta = delta, winner = winner,
			baseline_survival = baseline_row.survival, candidate_survival = candidate_row.survival,
			baseline_clear_rate = baseline_row.clear_rate, candidate_clear_rate = candidate_row.clear_rate,
			baseline_ante = baseline_row.ante_reached, candidate_ante = candidate_row.ante_reached,
			baseline_score_margin = baseline_row.average_score_margin,
			candidate_score_margin = candidate_row.average_score_margin,
		}
	end
	local count = #deltas
	local mean = count > 0 and sum / count or 0
	local squared = 0
	for _, delta in ipairs(deltas) do squared = squared + (delta - mean) * (delta - mean) end
	local stddev = count > 1 and math.sqrt(squared / (count - 1)) or 0
	local standard_error = count > 0 and stddev / math.sqrt(count) or 0
	local win_rate = count > 0 and wins / count or 0
	local mode = options.objective or options.mode or "mean_with_consistency_penalty"
	local objective
	if mode == "weighted_mean_win_rate" then
		objective = mean * (tonumber(options.mean_weight) or 1)
			+ win_rate * (tonumber(options.win_rate_weight) or 100)
	else
		objective = mean - stddev * (tonumber(options.consistency_penalty) or 0.10)
	end
	return {
		seeds = count, per_seed = rows, candidate_wins = wins, baseline_wins = losses, ties = ties,
		mean_delta = mean, median_delta = median(deltas), delta_stddev = stddev,
		standard_error = standard_error,
		confidence_95_low = mean - 1.96 * standard_error,
		confidence_95_high = mean + 1.96 * standard_error,
		worst_delta = count > 0 and math.min(unpack_values(deltas)) or 0,
		best_delta = count > 0 and math.max(unpack_values(deltas)) or 0,
		win_rate = win_rate, objective = mode, objective_score = objective,
	}
end

function Fitness.compare(baseline_weights, candidate_weights, seeds, config, dependencies, opponent)
	local baseline = Fitness.evaluate(baseline_weights, seeds, config, dependencies, opponent)
	local candidate = Fitness.evaluate(candidate_weights, seeds, config, dependencies, opponent)
	return {
		baseline = baseline, candidate = candidate,
		paired = Fitness.compare_evaluations(baseline, candidate, config.paired_objective),
	}
end

return Fitness
