local modules = {
	PRNG = dofile("bot/prng.lua"),
	Weights = dofile("bot/weights.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
local Fitness = dofile("training/fitness.lua")
local Evolution = dofile("training/evolution.lua")
local Opponents = dofile("training/opponents.lua")
local Json = dofile("training/json.lua")
local Seeds = dofile("training/seeds.lua")
local PlayerTraces = dofile("training/player_traces.lua")
local Recommendations = dofile("training/recommendations.lua")

local function write(path, value)
	local file = assert(io.open(path, "wb"))
	file:write(value)
	file:close()
end

local function load_table(path)
	local chunk, load_error = loadfile(path)
	assert(chunk, load_error)
	local value = chunk()
	assert(type(value) == "table", path .. " must return a table")
	return value
end

local function setting(name)
	local value = rawget(_G, name) or os.getenv(name)
	return value ~= "" and value or nil
end

local config_path = setting("MULTIBOTS_TRAIN_CONFIG") or "training/config.lua"
local config = load_table(config_path)
config.output_dir = assert(setting("MULTIBOTS_TRAIN_OUTPUT"), "MULTIBOTS_TRAIN_OUTPUT is required")
config.resume_checkpoint = setting("MULTIBOTS_TRAIN_RESUME")
local mode = (setting("MULTIBOTS_TRAIN_MODE") or "baseline"):lower()
local start_weights_path = setting("MULTIBOTS_TRAIN_START_WEIGHTS")
if start_weights_path then
	local weights, errors = modules.Weights.validate(load_table(start_weights_path))
	assert(weights, table.concat(errors, "; "))
	config.baseline_weights = weights
end
local player_log_paths = setting("MULTIBOTS_TRAIN_PLAYER_LOGS")
local player_traces
local resolved_player_log_paths = {}
if player_log_paths then
	player_traces = {}
	for path in player_log_paths:gmatch("[^;]+") do
		local trace, trace_error = PlayerTraces.load(path)
		assert(trace, trace_error)
		player_traces[#player_traces + 1] = trace
		resolved_player_log_paths[#resolved_player_log_paths + 1] = path
	end
	assert(#player_traces > 0, "MULTIBOTS_TRAIN_PLAYER_LOGS contains no log paths")
	config.opponent = { kind = "trace_set", traces = player_traces }
	print(string.format("Training against %d recorded player score traces", #player_traces))
end
config.evolution = config.evolution or {}
config.evolution.population_size = tonumber(setting("MULTIBOTS_TRAIN_POPULATION"))
	or config.evolution.population_size
config.evolution.generations = tonumber(setting("MULTIBOTS_TRAIN_GENERATIONS"))
	or config.evolution.generations
local opponent = Opponents.from_config(config.opponent)
local previous_progress_line_length = 0
local function positive_count(value, fallback)
	return math.max(1, math.floor(tonumber(value) or fallback))
end
local function planned_match_count()
	if mode ~= "train" then return 0 end
	local seed_options = config.seed_generation or {}
	local training_count = seed_options.enabled ~= false
		and positive_count(seed_options.training_count, 16) or #(config.training_seeds or {})
	local validation_count = seed_options.enabled ~= false
		and positive_count(seed_options.validation_count, 8) or #(config.validation_seeds or {})
	local test_count = seed_options.enabled ~= false
		and positive_count(seed_options.test_count, 16) or #(config.test_seeds or {})
	local seed_selection_count = 0
	if not config.resume_checkpoint and seed_options.enabled ~= false
		and seed_options.difficulty_bands_enabled ~= false then
		local multiplier = positive_count(seed_options.difficulty_pool_multiplier, 4)
		seed_selection_count = (validation_count + test_count) * multiplier
	end
	local evolution = config.evolution
	local population = math.max(2, tonumber(evolution.population_size) or 8)
	local generations = math.max(1, tonumber(evolution.generations) or 10)
	local selection = config.selection or {}
	local validation_candidates = math.max(1, math.min(population,
		tonumber(selection.validation_candidates_per_generation) or 3))
	return seed_selection_count + training_count + validation_count
		+ generations * ((population + 1) * training_count
			+ validation_candidates * validation_count)
		+ 2 * test_count
end
local progress = { completed = 0, total = planned_match_count() }
config.on_match_progress = function(label, event, index, total, seed, elapsed, success,
		generation, generation_total, completed_matches, generation_match_total)
	label = label or "Evaluation"
	if mode == "train" then
		if event == "start" then
			print(string.format("[Match] %s: starting %d/%d seed=%s",
				label, index, total, tostring(seed)))
		else
			progress.completed = progress.completed + 1
			print(string.format("[Match] %s: finished %d/%d in %.2fs (%s)",
				label, index, total, elapsed or 0, success and "ok" or "crash"))
			print(string.format("TRAIN_PROGRESS=%d/%d", progress.completed, progress.total))
		end
	end
	if generation and generation_total and generation_match_total > 0 then
		local percent = math.floor(completed_matches * 100 / generation_match_total)
		local filled = math.floor(completed_matches * 20 / generation_match_total)
		local bar = string.rep("#", filled) .. string.rep("-", 20 - filled)
		local status = event == "start"
			and string.format("running %d/%d seed %s", index, total, tostring(seed))
			or string.format("done %d/%d in %.2fs (%s)", index, total, elapsed or 0,
				success and "ok" or "crash")
		local line = string.format("[Generation %d/%d] [%s] %3d%% %d/%d %s: %s",
			generation, generation_total, bar, percent, completed_matches, generation_match_total,
			label, status)
		io.stdout:write("\r" .. line .. string.rep(" ",
			math.max(0, previous_progress_line_length - #line)))
		previous_progress_line_length = #line
	elseif mode ~= "train" and event == "start" then
		print(string.format("[%s] starting match %d/%d (seed %s)", label, index, total, tostring(seed)))
	elseif mode ~= "train" then
		print(string.format("[%s] finished match %d/%d in %.2fs (%s)",
			label, index, total, elapsed or 0, success and "ok" or "crash"))
	end
	if io.stdout and io.stdout.flush then io.stdout:flush() end
end
local seed_manifest
if config.resume_checkpoint then
	local checkpoint = assert(loadfile(config.resume_checkpoint))()
	local experiment = assert(checkpoint.experiment, "checkpoint has no seed manifest")
	config.training_seeds = assert(experiment.training_seeds, "checkpoint has no training seeds")
	config.validation_seeds = assert(experiment.validation_seeds, "checkpoint has no validation seeds")
	config.test_seeds = assert(experiment.test_seeds, "checkpoint has no test seeds")
	config.experiment_seed = experiment.experiment_seed
	seed_manifest = {
		experiment_seed = config.experiment_seed or "legacy-checkpoint", generated = config.experiment_seed ~= nil,
		training_seeds = config.training_seeds, validation_seeds = config.validation_seeds,
		test_seeds = config.test_seeds,
	}
else
	seed_manifest = Seeds.apply(config, modules.PRNG,
		setting("MULTIBOTS_TRAIN_EXPERIMENT_SEED") or (config.seed_generation and config.seed_generation.master_seed))
	local seed_options = config.seed_generation or {}
	if seed_options.difficulty_bands_enabled ~= false then
		local validation_evaluation = Fitness.evaluate(modules.Weights.copy(), config.validation_seed_pool,
			config, modules, opponent, "Selecting validation seeds")
		local test_evaluation = Fitness.evaluate(modules.Weights.copy(), config.test_seed_pool,
			config, modules, opponent, "Selecting test seeds")
		local validation_counts, test_counts
		config.validation_seeds, validation_counts = Seeds.select_difficulty_spread(validation_evaluation,
			seed_options.validation_count or 8, config.max_ante)
		config.test_seeds, test_counts = Seeds.select_difficulty_spread(test_evaluation,
			seed_options.test_count or 16, config.max_ante)
		seed_manifest.validation_seeds, seed_manifest.test_seeds = config.validation_seeds, config.test_seeds
		seed_manifest.difficulty_bands = { validation_pool = validation_counts, test_pool = test_counts }
	end
end
seed_manifest.rotate_training_each_generation = config.seed_generation
	and config.seed_generation.rotate_training_each_generation ~= false or false
write(config.output_dir .. "/seed-manifest.json", Json.encode(seed_manifest) .. "\n")
print("Experiment seed: " .. tostring(seed_manifest.experiment_seed))
print(string.format("Seed sets: training=%d validation=%d test=%d",
	#config.training_seeds, #config.validation_seeds, #config.test_seeds))
print("Training batches rotate by generation: " .. tostring(seed_manifest.rotate_training_each_generation))
local services = { Fitness = Fitness, Json = Json, Seeds = Seeds, opponent = opponent }

local function evaluate(weights, include_test)
	local result = {
		training = Fitness.evaluate(weights, config.training_seeds, config, modules, opponent, "Training"),
		validation = Fitness.evaluate(weights, config.validation_seeds, config, modules, opponent, "Validation"),
	}
	if include_test then
		result.test = Fitness.evaluate(weights, config.test_seeds, config, modules, opponent, "Test")
	end
	return result
end

local function print_metrics(label, evaluation)
	local metrics = evaluation.metrics
	print(string.format("%s fitness: %.3f", label, evaluation.fitness))
	print(string.format("  clear=%.3f avg_ante=%.3f survival=%.3f avg_margin=%.3f avg_money=%.3f",
		metrics.blind_clear_rate, metrics.average_ante, metrics.survival_rate,
		metrics.average_score_margin, metrics.average_ending_money))
	print(string.format("  failed=%d unused_hands=%d unused_discards=%d unused_consumables=%d invalid=%d crashes=%d",
		metrics.failed_blinds, metrics.failed_with_unused_hands,
		metrics.failed_with_unused_discards, metrics.failed_with_unused_consumables,
		metrics.invalid_actions, metrics.crashes))
end

local function print_paired(label, paired)
	print(label)
	print(string.format("  seeds=%d candidate_wins=%d baseline_wins=%d ties=%d",
		paired.seeds, paired.candidate_wins, paired.baseline_wins, paired.ties))
	print(string.format("  mean_delta=%+.3f median_delta=%+.3f stddev=%.3f 95%%_ci=[%+.3f, %+.3f]",
		paired.mean_delta, paired.median_delta, paired.delta_stddev,
		paired.confidence_95_low, paired.confidence_95_high))
end

if mode == "baseline" then
	local result = evaluate(modules.Weights.copy(config.baseline_weights), true)
	write(config.output_dir .. "/baseline.json", Json.encode(result) .. "\n")
	print_metrics("Baseline training", result.training)
	print_metrics("Baseline validation", result.validation)
	print_metrics("Baseline test", result.test)
elseif mode == "compare" then
	local path = assert(setting("MULTIBOTS_TRAIN_WEIGHTS"), "compare mode requires MULTIBOTS_TRAIN_WEIGHTS")
	local candidate, errors = modules.Weights.validate(load_table(path))
	assert(candidate, table.concat(errors, "; "))
	local result = { baseline = evaluate(modules.Weights.copy(), true), candidate = evaluate(candidate, true) }
	for _, split in ipairs({ "training", "validation", "test" }) do
		result[split .. "_paired"] = Fitness.compare_evaluations(result.baseline[split],
			result.candidate[split], config.paired_objective)
	end
	result.validation_improved = result.candidate.validation.fitness > result.baseline.validation.fitness
	result.auto_promoted = false
	write(config.output_dir .. "/comparison.json", Json.encode(result) .. "\n")
	print_metrics("Baseline validation", result.baseline.validation)
	print_metrics("Candidate validation", result.candidate.validation)
	print_metrics("Baseline test", result.baseline.test)
	print_metrics("Candidate test", result.candidate.test)
	print_paired("VALIDATION PAIRED RESULTS", result.validation_paired)
	print_paired("TEST PAIRED RESULTS", result.test_paired)
	print("Validation improved: " .. tostring(result.validation_improved))
elseif mode == "tournament" then
	local paths = assert(setting("MULTIBOTS_TRAIN_CHAMPIONS"),
		"tournament mode requires MULTIBOTS_TRAIN_CHAMPIONS")
	local tournament_options = config.tournament or {}
	local count = tonumber(tournament_options.seed_count) or 128
	local multiplier = tonumber(tournament_options.difficulty_pool_multiplier) or 4
	local pool = Seeds.generate(modules.PRNG, seed_manifest.experiment_seed, "tournament-pool", count * multiplier)
	local pool_baseline = Fitness.evaluate(modules.Weights.copy(), pool, config, modules, opponent,
		"Selecting tournament seeds")
	local tournament_seeds, difficulty_counts = Seeds.select_difficulty_spread(pool_baseline, count, config.max_ante)
	local baseline = Fitness.evaluate(modules.Weights.copy(), tournament_seeds, config, modules, opponent,
		"Tournament baseline")
	local result = { seeds = tournament_seeds, difficulty_bands = difficulty_counts,
		baseline = baseline, candidates = {}, auto_promoted = false }
	for path in paths:gmatch("[^;]+") do
		local weights, errors = modules.Weights.validate(load_table(path))
		assert(weights, table.concat(errors, "; "))
		local evaluation = Fitness.evaluate(weights, tournament_seeds, config, modules, opponent,
			"Tournament " .. path)
		local total_fitness = 0
		for _, row in ipairs(evaluation.per_seed or {}) do total_fitness = total_fitness + row.fitness end
		result.candidates[#result.candidates + 1] = {
			path = path, total_fitness = total_fitness, aggregate_fitness = evaluation.fitness,
			evaluation = evaluation,
			paired = Fitness.compare_evaluations(baseline, evaluation, config.paired_objective),
		}
	end
	table.sort(result.candidates, function(a, b)
		if a.paired.objective_score == b.paired.objective_score then return a.path < b.path end
		return a.paired.objective_score > b.paired.objective_score
	end)
	for rank, candidate_result in ipairs(result.candidates) do
		candidate_result.rank = rank
		print(string.format("Rank %d: %s total_fitness=%.3f survival=%.3f clear=%.3f ante=%.3f margin=%.3f crashes=%d invalid=%d",
			rank, candidate_result.path, candidate_result.total_fitness,
			candidate_result.evaluation.metrics.survival_rate,
			candidate_result.evaluation.metrics.blind_clear_rate,
			candidate_result.evaluation.metrics.average_ante,
			candidate_result.evaluation.metrics.average_score_margin,
			candidate_result.evaluation.metrics.crashes,
			candidate_result.evaluation.metrics.invalid_actions))
		print_paired("  PAIRED VS BASELINE", candidate_result.paired)
	end
	write(config.output_dir .. "/tournament.json", Json.encode(result) .. "\n")
elseif mode == "train" then
	config.on_generation = function(item)
		if previous_progress_line_length > 0 then
			io.stdout:write("\r\n")
			previous_progress_line_length = 0
		end
		local plateau = item.plateau_detected
			and string.format(" plateau=%d", item.validation_plateau_generations) or ""
		print(string.format("Generation %d: selected=%s training=%.3f validation=%.3f global=%s/%.3f%s",
			item.generation, item.best_id, item.training_fitness, item.validation_fitness,
			item.global_selected_id, item.global_selected_validation_fitness, plateau))
	end
	local result = Evolution.run(config, modules, services)
	write(config.output_dir .. "/weight-recommendations.txt",
		Recommendations.render(result, modules.Weights, resolved_player_log_paths))
	if progress.total ~= progress.completed then
		progress.total = progress.completed
		print(string.format("TRAIN_PROGRESS=%d/%d", progress.completed, progress.total))
		if io.stdout and io.stdout.flush then io.stdout:flush() end
	end
	print_metrics("Baseline training", result.baseline.training)
	print_metrics("Baseline validation", result.baseline.validation)
	print_metrics("Baseline test", result.baseline.test)
	print_metrics("Best training candidate / training", result.best_training_candidate.training)
	print(string.format("  gain versus its generation baseline: %.3f",
		result.best_training_candidate.training_gain_vs_generation_baseline or 0))
	print_metrics("Best training candidate / validation", result.best_training_candidate.validation)
	print_metrics("Best validation candidate / validation", result.best_validation_candidate.validation)
	print_metrics("Selected candidate / training", result.selected_candidate.training)
	print_metrics("Selected candidate / validation", result.selected_candidate.validation)
	print_metrics("Selected candidate / test", result.selected_candidate.test)
	print_paired("TRAINING PAIRED RESULTS", result.selected_candidate.training_paired)
	print_paired("VALIDATION PAIRED RESULTS", result.selected_candidate.validation_paired)
	print_paired("TEST PAIRED RESULTS", result.selected_candidate.test_paired)
	print(string.format("Selection: %s; training floor %.3f; validation floor %.3f",
		result.selection.mode, result.selection.training_floor, result.selection.validation_floor))
	if result.plateau.detected then
		print(string.format("Validation plateau: %d generations without meaningful improvement%s",
			result.plateau.no_improvement_generations,
			result.plateau.early_stopped and "; training stopped early" or ""))
	end
	print("Changes vs baseline:")
	local changed = false
	for _, key in ipairs(modules.Weights.keys()) do
		local difference = result.changes[key]
		if difference then
			changed = true
			print(string.format("  %s %.6f -> %.6f", key, difference.baseline, difference.candidate))
		end
	end
	if not changed then print("  none") end
	print("Validation improved: " .. tostring(result.validation_improved))
	print("Untouched test improved: " .. tostring(result.test_improved))
	print("PROMOTION ELIGIBLE: " .. tostring(result.promotion_eligible))
	print("Candidate saved but not promoted: " .. config.output_dir .. "/best-weights.lua")
else
	error("unknown training mode: " .. mode)
end
