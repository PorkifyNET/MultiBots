local Evolution = {}

local function number(value) return tonumber(value) or 0 end

local function serialize_lua(value, indent)
	indent = indent or ""
	if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
	if type(value) == "string" then return string.format("%q", value) end
	if type(value) ~= "table" then return "nil" end
	local next_indent, out = indent .. "  ", { "{" }
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do
		local rendered_key = type(key) == "string" and string.format("[%q]", key) or "[" .. tostring(key) .. "]"
		out[#out + 1] = "\n" .. next_indent .. rendered_key .. " = "
			.. serialize_lua(value[key], next_indent) .. ","
	end
	out[#out + 1] = "\n" .. indent .. "}"
	return table.concat(out)
end

local function write(path, value)
	local file = assert(io.open(path, "wb"))
	file:write(value)
	file:close()
end

local function candidate_copy(candidate, Weights)
	if not candidate then return nil end
	local training_baseline = candidate.training_baseline_fitness
	return {
		id = candidate.id, generation = candidate.generation, origin = candidate.origin,
		weights = Weights.copy(candidate.weights), training = candidate.training,
		validation = candidate.validation, training_paired = candidate.training_paired,
		validation_paired = candidate.validation_paired,
		training_baseline_fitness = training_baseline,
		training_gain_vs_generation_baseline = training_baseline
			and candidate.training.fitness - training_baseline or nil,
		generation_best_training_fitness = candidate.generation_best_training_fitness,
	}
end

local function mutate(parent, rng, options, Weights)
	local child = Weights.copy(parent)
	local mutation_rate = tonumber(options.mutation_rate) or 0.35
	local mutation_magnitude = tonumber(options.mutation_magnitude) or 0.18
	local changed = false
	for _, key in ipairs(Weights.keys()) do
		if rng:next() < mutation_rate then
			local delta = (rng:next() * 2 - 1) * mutation_magnitude
			local value = math.max(Weights.minimum, math.min(Weights.maximum, child[key] * (1 + delta)))
			changed = changed or math.abs(value - child[key]) > 1e-12
			child[key] = value
		end
	end
	-- Exact elites survive separately. Every child explores at least one weight.
	if not changed then
		local keys = Weights.keys()
		local key = keys[rng:integer(1, #keys)]
		local delta = (rng:next() * 2 - 1) * mutation_magnitude
		if math.abs(delta) < 1e-6 then delta = mutation_magnitude * 0.5 end
		local value = math.max(Weights.minimum, math.min(Weights.maximum, child[key] * (1 + delta)))
		if math.abs(value - child[key]) <= 1e-12 then
			value = math.max(Weights.minimum, math.min(Weights.maximum, child[key] * (1 - delta)))
		end
		child[key] = value
	end
	return child
end

local function aggregate_pair(baseline, candidate, options, Fitness)
	if Fitness.compare_evaluations and baseline.per_seed and candidate.per_seed then
		return Fitness.compare_evaluations(baseline, candidate, options)
	end
	local delta = candidate.fitness - baseline.fitness
	return {
		seeds = 1, per_seed = {}, candidate_wins = delta > 0 and 1 or 0,
		baseline_wins = delta < 0 and 1 or 0, ties = delta == 0 and 1 or 0,
		mean_delta = delta, median_delta = delta, delta_stddev = 0, standard_error = 0,
		confidence_95_low = delta, confidence_95_high = delta, worst_delta = delta, best_delta = delta,
		win_rate = delta > 0 and 1 or 0, objective = "aggregate_delta", objective_score = delta,
	}
end

local function evaluate_population(population, training_seeds, baseline_evaluation,
		config, dependencies, services, generation)
	for index, candidate in ipairs(population) do
		candidate.training = services.Fitness.evaluate(candidate.weights, training_seeds,
			config, dependencies, services.opponent,
			string.format("Generation %d candidate %d/%d training", generation, index, #population))
		candidate.training_paired = aggregate_pair(baseline_evaluation, candidate.training,
			config.paired_objective, services.Fitness)
	end
	table.sort(population, function(a, b)
		if a.training_paired.objective_score == b.training_paired.objective_score then return a.id < b.id end
		return a.training_paired.objective_score > b.training_paired.objective_score
	end)
end

local function differences(weights, baseline, Weights)
	local result = {}
	for _, key in ipairs(Weights.keys()) do
		if math.abs(weights[key] - baseline[key]) > 1e-9 then result[key] = {
			baseline = baseline[key], candidate = weights[key],
		} end
	end
	return result
end

local function selection_score(candidate, options)
	if options.mode == "weighted" then
		local training_value = candidate.training_paired and candidate.training_paired.objective_score
			or candidate.training.fitness - (candidate.training_baseline_fitness or 0)
		local validation_value = candidate.validation_paired and candidate.validation_paired.objective_score
			or candidate.validation.fitness
		return training_value * (tonumber(options.training_weight) or 0.25)
			+ validation_value * (tonumber(options.validation_weight) or 0.75)
	end
	return candidate.validation_paired and candidate.validation_paired.objective_score
		or candidate.validation.fitness
end

local function better_training(a, b)
	local a_gain = a.training_paired and a.training_paired.objective_score
		or a.training.fitness - (a.training_baseline_fitness or 0)
	local b_gain = b and (b.training_paired and b.training_paired.objective_score
		or b.training.fitness - (b.training_baseline_fitness or 0)) or nil
	if not b or a_gain ~= b_gain then return not b or a_gain > b_gain end
	if a.training_paired and b.training_paired then
		if a.training_paired.mean_delta ~= b.training_paired.mean_delta then
			return a.training_paired.mean_delta > b.training_paired.mean_delta
		end
		if a.training_paired.win_rate ~= b.training_paired.win_rate then
			return a.training_paired.win_rate > b.training_paired.win_rate
		end
		if a.training_paired.median_delta ~= b.training_paired.median_delta then
			return a.training_paired.median_delta > b.training_paired.median_delta
		end
	end
	return tostring(a.id) < tostring(b.id)
end

local function better_validation(a, b)
	local a_score, b_score = selection_score(a, {}), b and selection_score(b, {}) or nil
	return not b or a_score > b_score or (a_score == b_score and better_training(a, b))
end

-- Public so selection policy can be regression-tested without running matches.
function Evolution.select_candidates(archive, baseline, options)
	options = options or {}
	local best_training, best_validation
	for _, candidate in ipairs(archive or {}) do
		if better_training(candidate, best_training) then best_training = candidate end
		if better_validation(candidate, best_validation) then best_validation = candidate end
	end
	local baseline_candidate = {
		id = "baseline", origin = "baseline", weights = baseline.weights,
		training = baseline.training, validation = baseline.validation,
		training_baseline_fitness = baseline.training.fitness,
		generation_best_training_fitness = baseline.training.fitness,
		training_paired = baseline.training_paired, validation_paired = baseline.validation_paired,
	}
	local selected = baseline_candidate
	local training_floor = tonumber(options.minimum_mean_paired_delta)
		or tonumber(options.minimum_training_improvement) or 0
	local training_objective_floor = -math.huge
	local fraction = tonumber(options.minimum_training_fraction_of_best)
	if fraction and best_training then
		local best_score = best_training.training_paired and best_training.training_paired.objective_score
			or best_training.training.fitness - (best_training.training_baseline_fitness or baseline.training.fitness)
		training_objective_floor = best_score - math.abs(best_score) * math.max(0, 1 - fraction)
	end
	local validation_floor = baseline.validation.fitness
		- (tonumber(options.maximum_validation_regression) or 0)
		+ (tonumber(options.minimum_validation_improvement) or 0)
	for _, candidate in ipairs(archive or {}) do
		local training_pair = candidate.training_paired or aggregate_pair(
			{ fitness = candidate.training_baseline_fitness or baseline.training.fitness }, candidate.training, {}, {})
		local validation_pair = candidate.validation_paired or aggregate_pair(baseline.validation, candidate.validation, {}, {})
		local candidate_floor = training_floor
		local passes = training_pair.mean_delta >= candidate_floor
			and training_pair.objective_score >= training_objective_floor
			and training_pair.win_rate >= (tonumber(options.minimum_paired_win_rate) or 0)
			and training_pair.confidence_95_low
				>= (tonumber(options.minimum_training_confidence_95_low) or -math.huge)
			and validation_pair.mean_delta >= (tonumber(options.minimum_validation_mean_paired_delta) or 0)
			and validation_pair.win_rate >= (tonumber(options.minimum_validation_paired_win_rate) or 0)
			and validation_pair.confidence_95_low
				>= (tonumber(options.minimum_validation_confidence_95_low) or -math.huge)
			and candidate.validation.fitness >= validation_floor
		if passes then
			local candidate_score, selected_score = selection_score(candidate, options), selection_score(selected, options)
			if candidate_score > selected_score
				or (candidate_score == selected_score and better_validation(candidate, selected)) then
				selected = candidate
				training_floor = candidate_floor
			end
		end
	end
	return {
		best_training = best_training, best_validation = best_validation, selected = selected,
		training_floor = training_floor, training_objective_floor = training_objective_floor,
		validation_floor = validation_floor,
		mode = options.mode or "max_paired_validation_with_training_floor",
		selection_score = selection_score(selected, options),
	}
end

local function assert_disjoint_seeds(config)
	local seen = {}
	for name, seeds in pairs({ training = config.training_seeds or {}, validation = config.validation_seeds or {},
		test = config.test_seeds or {} }) do
		for _, seed in ipairs(seeds) do
			local key = tostring(seed)
			assert(not seen[key], string.format("seed %s occurs in both %s and %s sets", key, seen[key], name))
			seen[key] = name
		end
	end
	assert(#(config.training_seeds or {}) > 0, "training_seeds must not be empty")
	assert(#(config.validation_seeds or {}) > 0, "validation_seeds must not be empty")
	assert(#(config.test_seeds or {}) > 0, "test_seeds must not be empty")
end

local function legacy_experiment(experiment)
	return {
		difficulty = experiment.difficulty, max_ante = experiment.max_ante,
		stop_on_failed_blind = experiment.stop_on_failed_blind,
		training_seeds = experiment.training_seeds, validation_seeds = experiment.validation_seeds,
		fitness_weights = experiment.fitness_weights, opponent = experiment.opponent,
		evolution = experiment.evolution,
	}
end

function Evolution.run(config, dependencies, services)
	assert_disjoint_seeds(config)
	local options, selection_options, stopping = config.evolution or {}, config.selection or {}, config.early_stopping or {}
	local Weights, rng = dependencies.Weights, dependencies.PRNG.new(options.rng_seed or "MULTIBOTS-EVOLUTION")
	local population_size = math.max(2, tonumber(options.population_size) or 8)
	local generation_count = math.max(1, tonumber(options.generations) or 10)
	local validation_count = math.max(1, math.min(population_size,
		tonumber(selection_options.validation_candidates_per_generation) or 3))
	local baseline_weights = Weights.copy(config.baseline_weights)
	local experiment = {
		experiment_seed = config.experiment_seed,
		difficulty = config.difficulty, max_ante = config.max_ante,
		stop_on_failed_blind = config.stop_on_failed_blind,
		training_seeds = config.training_seeds, validation_seeds = config.validation_seeds,
		test_seeds = config.test_seeds, fitness_weights = config.fitness_weights,
		opponent = config.opponent, selection = selection_options, early_stopping = stopping,
		seed_generation = config.seed_generation,
		evolution = {
			population_size = population_size, elite_count = options.elite_count,
			mutation_rate = options.mutation_rate, mutation_magnitude = options.mutation_magnitude,
			rng_seed = options.rng_seed,
		},
	}
	local baseline = {
		weights = baseline_weights,
		training = services.Fitness.evaluate(baseline_weights, config.training_seeds, config, dependencies,
			services.opponent, "Initial baseline training"),
		validation = services.Fitness.evaluate(baseline_weights, config.validation_seeds, config, dependencies,
			services.opponent, "Initial baseline validation"),
	}
	baseline.training_paired = aggregate_pair(baseline.training, baseline.training,
		config.paired_objective, services.Fitness)
	baseline.validation_paired = aggregate_pair(baseline.validation, baseline.validation,
		config.paired_objective, services.Fitness)
	local population = { { id = "00-00", weights = baseline_weights } }
	for index = 2, population_size do population[index] = {
		id = string.format("00-%02d", index - 1), weights = mutate(baseline_weights, rng, options, Weights),
	} end
	local history, archive, start_generation = {}, {}, 1
	local plateau_count, plateau_best = 0, baseline.validation_paired.objective_score
	local early_stopped, stopped_generation = false, nil
	if config.resume_checkpoint then
		local checkpoint = assert(loadfile(config.resume_checkpoint))()
		assert(type(checkpoint) == "table" and type(checkpoint.population) == "table", "invalid training checkpoint")
		if checkpoint.experiment then
			local expected = checkpoint.experiment.test_seeds and experiment or legacy_experiment(experiment)
			assert(services.Json.encode(checkpoint.experiment) == services.Json.encode(expected),
				"checkpoint configuration does not match this experiment")
		end
		population, history, archive = checkpoint.population, checkpoint.history or {}, checkpoint.archive or {}
		if #archive == 0 then
			for _, item in ipairs(history) do
				if item.best_weights and item.training and item.validation then archive[#archive + 1] = {
					id = item.best_id, generation = item.generation, weights = item.best_weights,
					training = item.training, validation = item.validation,
					training_baseline_fitness = baseline.training.fitness,
					generation_best_training_fitness = item.best_training_fitness or item.training.fitness,
				} end
			end
		end
		start_generation = tonumber(checkpoint.next_generation) or 1
		plateau_count = tonumber(checkpoint.plateau_count) or 0
		plateau_best = tonumber(checkpoint.plateau_best) or plateau_best
		if checkpoint.rng_state then rng.state = checkpoint.rng_state end
	end

	for generation = start_generation, generation_count do
		local generation_training_seeds = config.training_seeds
		if services.Seeds and config.seed_generation and config.seed_generation.rotate_training_each_generation ~= false
			and config.experiment_seed then
			generation_training_seeds = services.Seeds.generate(dependencies.PRNG,
				config.experiment_seed .. ":generation:" .. tostring(generation),
				"training", #config.training_seeds)
		end
		for index, candidate in ipairs(population) do
			candidate.id, candidate.generation = string.format("%02d-%02d", generation, index), generation
		end
		local previous_match_progress = config.on_match_progress
		local completed_matches = 0
		local generation_match_total = #generation_training_seeds * (#population + 1)
			+ #config.validation_seeds * validation_count
		if previous_match_progress then
			config.on_match_progress = function(label, event, index, total, seed, elapsed, success)
				if event == "finish" then completed_matches = completed_matches + 1 end
				previous_match_progress(label, event, index, total, seed, elapsed, success,
					generation, generation_count, completed_matches, generation_match_total)
			end
		end
		local generation_baseline = services.Fitness.evaluate(baseline_weights, generation_training_seeds,
			config, dependencies, services.opponent, string.format("Generation %d baseline", generation))
		evaluate_population(population, generation_training_seeds, generation_baseline,
			config, dependencies, services, generation)
		for _, candidate in ipairs(population) do
			candidate.training_baseline_fitness = generation_baseline.fitness
			candidate.generation_best_training_fitness = population[1].training.fitness
		end
		local generation_candidates = {}
		for index = 1, validation_count do
			local candidate = population[index]
			candidate.validation = services.Fitness.evaluate(candidate.weights, config.validation_seeds,
				config, dependencies, services.opponent,
				string.format("Generation %d candidate %d/%d validation", generation, index, validation_count))
			candidate.validation_paired = aggregate_pair(baseline.validation, candidate.validation,
				config.paired_objective, services.Fitness)
			local stored = candidate_copy(candidate, Weights)
			generation_candidates[#generation_candidates + 1], archive[#archive + 1] = stored, stored
		end
		config.on_match_progress = previous_match_progress
		local generation_baseline_candidate = {
			weights = baseline_weights, training = generation_baseline, validation = baseline.validation,
			training_paired = aggregate_pair(generation_baseline, generation_baseline,
				config.paired_objective, services.Fitness),
			validation_paired = baseline.validation_paired,
		}
		local generation_selection = Evolution.select_candidates(generation_candidates,
			generation_baseline_candidate, selection_options)
		local global_selection = Evolution.select_candidates(archive, baseline, selection_options)
		local meaningful_delta = tonumber(stopping.meaningful_validation_improvement) or 1
		local current_validation = global_selection.selected.validation_paired
			and global_selection.selected.validation_paired.objective_score or 0
		local meaningful_improvement = current_validation > plateau_best + meaningful_delta
		if meaningful_improvement then plateau_best, plateau_count = current_validation, 0
		else plateau_count = plateau_count + 1 end
		local plateau_after = math.max(1, tonumber(stopping.plateau_generations) or 3)
		local item = {
			generation = generation,
			best_id = generation_selection.selected.id,
			best_weights = Weights.copy(generation_selection.selected.weights),
			training_fitness = generation_selection.selected.training.fitness,
			validation_fitness = generation_selection.selected.validation.fitness,
			training = generation_selection.selected.training, validation = generation_selection.selected.validation,
			best_training_id = generation_selection.best_training and generation_selection.best_training.id,
			best_training_fitness = generation_selection.best_training and generation_selection.best_training.training.fitness,
			best_training_gain_vs_generation_baseline = generation_selection.best_training
				and generation_selection.best_training.training_paired.mean_delta,
			best_training_paired_objective = generation_selection.best_training
				and generation_selection.best_training.training_paired.objective_score,
			best_validation_id = generation_selection.best_validation and generation_selection.best_validation.id,
			best_validation_fitness = generation_selection.best_validation and generation_selection.best_validation.validation.fitness,
			validated_candidates = generation_candidates,
			global_selected_id = global_selection.selected.id,
			global_selected_validation_fitness = global_selection.selected.validation.fitness,
			meaningful_validation_improvement = meaningful_improvement,
			validation_plateau_generations = plateau_count,
			plateau_detected = plateau_count >= plateau_after,
			training_seed_count = #generation_training_seeds,
			training_seeds = generation_training_seeds,
			generation_baseline_training_fitness = generation_baseline.fitness,
		}
		history[#history + 1] = item
		if config.on_generation then config.on_generation(item, generation_selection.selected) end
		if config.output_dir then write(config.output_dir .. "/generation-" .. string.format("%03d", generation)
			.. ".json", services.Json.encode(item) .. "\n") end

		local next_population, elite_count = {}, math.max(1,
			math.min(tonumber(options.elite_count) or 2, #population))
		for index = 1, elite_count do next_population[#next_population + 1] = {
			id = population[index].id, weights = Weights.copy(population[index].weights),
		} end
		while #next_population < population_size do
			local parent = population[((#next_population - elite_count) % elite_count) + 1]
			next_population[#next_population + 1] = { weights = mutate(parent.weights, rng, options, Weights) }
		end
		population = next_population
		local patience = tonumber(stopping.patience) or 8
		early_stopped = stopping.enabled ~= false and patience > 0
			and generation >= (tonumber(stopping.minimum_generations) or 5) and plateau_count >= patience
		if early_stopped then stopped_generation = generation end
		if config.output_dir then write(config.output_dir .. "/checkpoint.lua", "return " .. serialize_lua({
			next_generation = generation + 1, history = history, population = population,
			archive = archive, rng_state = rng.state, experiment = experiment,
			plateau_count = plateau_count, plateau_best = plateau_best,
		}) .. "\n") end
		if early_stopped then break end
	end

	local selection = Evolution.select_candidates(archive, baseline, selection_options)
	local selected = candidate_copy(selection.selected, Weights)
	local best_training = candidate_copy(selection.best_training, Weights)
	local best_validation = candidate_copy(selection.best_validation, Weights)
	baseline.test = services.Fitness.evaluate(baseline_weights, config.test_seeds, config, dependencies,
		services.opponent, "Final baseline test")
	if selected.origin == "baseline" then selected.test = baseline.test
	else selected.test = services.Fitness.evaluate(selected.weights, config.test_seeds, config, dependencies,
		services.opponent, "Final candidate test") end
	selected.test_paired = aggregate_pair(baseline.test, selected.test, config.paired_objective, services.Fitness)
	baseline.test_paired = aggregate_pair(baseline.test, baseline.test, config.paired_objective, services.Fitness)
	local promotion = config.promotion or {}
	local validation_survival_regression = number(baseline.validation.metrics.survival_rate)
		- number(selected.validation.metrics.survival_rate)
	local validation_clear_regression = number(baseline.validation.metrics.blind_clear_rate)
		- number(selected.validation.metrics.blind_clear_rate)
	local test_survival_regression = number(baseline.test.metrics.survival_rate)
		- number(selected.test.metrics.survival_rate)
	local test_clear_regression = number(baseline.test.metrics.blind_clear_rate)
		- number(selected.test.metrics.blind_clear_rate)
	local promotion_eligible = selected.origin ~= "baseline"
		and selected.validation_paired.mean_delta >= (tonumber(promotion.minimum_validation_mean_paired_delta) or 0)
		and selected.validation_paired.win_rate >= (tonumber(promotion.minimum_validation_paired_win_rate) or 0.5)
		and selected.validation_paired.confidence_95_low
			>= (tonumber(promotion.minimum_validation_confidence_95_low) or -math.huge)
		and selected.validation.fitness - baseline.validation.fitness
			>= (tonumber(promotion.minimum_validation_improvement) or 0)
		and selected.test_paired.mean_delta >= (tonumber(promotion.minimum_test_mean_paired_delta) or 0)
		and selected.test_paired.win_rate >= (tonumber(promotion.minimum_test_paired_win_rate) or 0.5)
		and selected.test_paired.confidence_95_low
			>= (tonumber(promotion.minimum_test_confidence_95_low) or -math.huge)
		and validation_survival_regression <= (tonumber(promotion.maximum_survival_regression) or 0)
		and test_survival_regression <= (tonumber(promotion.maximum_survival_regression) or 0)
		and validation_clear_regression <= (tonumber(promotion.maximum_clear_rate_regression) or 0)
		and test_clear_regression <= (tonumber(promotion.maximum_clear_rate_regression) or 0)
	local plateau_after = tonumber(stopping.plateau_generations) or 3
	local result = {
		baseline = baseline, best_training_candidate = best_training,
		best_validation_candidate = best_validation, selected_candidate = selected,
		best = selected, -- Backward-compatible alias; now means selected, not final generation.
		history = history, experiment = experiment, requested_generations = generation_count,
		selection = {
			mode = selection.mode, training_floor = selection.training_floor,
			validation_floor = selection.validation_floor, score = selection.selection_score,
			validation_candidates_per_generation = validation_count,
		},
		plateau = {
			meaningful_validation_improvement = tonumber(stopping.meaningful_validation_improvement) or 1,
			plateau_generations = plateau_after, no_improvement_generations = plateau_count,
			detected = plateau_count >= plateau_after,
			early_stopped = early_stopped, stopped_generation = stopped_generation,
		},
		validation_improved = selected.validation.fitness > baseline.validation.fitness,
		test_improved = selected.test.fitness > baseline.test.fitness,
		promotion_eligible = promotion_eligible,
		promotion_checks = {
			validation_mean_paired_delta = selected.validation_paired.mean_delta,
			validation_paired_win_rate = selected.validation_paired.win_rate,
			validation_confidence_95_low = selected.validation_paired.confidence_95_low,
			validation_fitness_improvement = selected.validation.fitness - baseline.validation.fitness,
			test_mean_paired_delta = selected.test_paired.mean_delta,
			test_paired_win_rate = selected.test_paired.win_rate,
			test_confidence_95_low = selected.test_paired.confidence_95_low,
			validation_survival_regression = validation_survival_regression,
			validation_clear_rate_regression = validation_clear_regression,
			test_survival_regression = test_survival_regression,
			test_clear_rate_regression = test_clear_regression,
			thresholds = promotion,
		},
		auto_promoted = false,
		changes = differences(selected.weights, baseline_weights, Weights),
	}
	if config.output_dir then
		write(config.output_dir .. "/result.json", services.Json.encode(result) .. "\n")
		write(config.output_dir .. "/best-weights.lua",
			"-- Validation-selected candidate only; never loaded by live gameplay automatically.\nreturn "
			.. serialize_lua(selected.weights) .. "\n")
		write(config.output_dir .. "/champion-weights.lua",
			"-- Experiment champion; saved only and never auto-promoted.\nreturn "
			.. serialize_lua(selected.weights) .. "\n")
		write(config.output_dir .. "/best-training-weights.lua", "return "
			.. serialize_lua(best_training and best_training.weights or baseline_weights) .. "\n")
		write(config.output_dir .. "/best-validation-weights.lua", "return "
			.. serialize_lua(best_validation and best_validation.weights or baseline_weights) .. "\n")
	end
	return result
end

return Evolution
