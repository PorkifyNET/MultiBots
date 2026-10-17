local Fitness = dofile("training/fitness.lua")
local Evolution = dofile("training/evolution.lua")
local Seeds = dofile("training/seeds.lua")

local baseline_evaluation = {
	fitness = 100,
	metrics = { survival_rate = 0.5, blind_clear_rate = 0.7 },
	per_seed = {
		{ seed = "A", fitness = 100, survival = 1, clear_rate = 1, ante_reached = 5,
			failed_blind_deficit = 0, average_score_margin = 0.2 },
		{ seed = "B", fitness = 100, survival = 0, clear_rate = 0.7, ante_reached = 3,
			failed_blind_deficit = 0.2, average_score_margin = -0.1 },
		{ seed = "C", fitness = 100, survival = 0, clear_rate = 0.4, ante_reached = 2,
			failed_blind_deficit = 0.5, average_score_margin = -0.5 },
	},
}
local candidate_evaluation = {
	fitness = 110,
	metrics = { survival_rate = 0.6, blind_clear_rate = 0.8 },
	per_seed = {
		{ seed = "A", fitness = 110, survival = 1, clear_rate = 1, ante_reached = 5,
			failed_blind_deficit = 0, average_score_margin = 0.3 },
		{ seed = "B", fitness = 90, survival = 0, clear_rate = 0.6, ante_reached = 3,
			failed_blind_deficit = 0.3, average_score_margin = -0.2 },
		{ seed = "C", fitness = 130, survival = 0, clear_rate = 0.6, ante_reached = 3,
			failed_blind_deficit = 0.3, average_score_margin = -0.2 },
	},
}
local paired = Fitness.compare_evaluations(baseline_evaluation, candidate_evaluation, {
	objective = "mean_with_consistency_penalty", consistency_penalty = 0.1,
})
assert(paired.candidate_wins == 2 and paired.baseline_wins == 1 and paired.ties == 0,
	"paired winners were counted incorrectly")
assert(math.abs(paired.mean_delta - 10) < 1e-9 and paired.median_delta == 10,
	"paired mean or median is incorrect")
assert(paired.delta_stddev == 20 and paired.standard_error > 0,
	"paired variability is incorrect")
assert(#paired.per_seed == 3 and paired.per_seed[1].baseline_survival == 1,
	"per-seed comparison rows are incomplete")

local baseline = { weights = {}, training = baseline_evaluation, validation = baseline_evaluation,
	training_paired = Fitness.compare_evaluations(baseline_evaluation, baseline_evaluation),
	validation_paired = Fitness.compare_evaluations(baseline_evaluation, baseline_evaluation) }
local consistent = { id = "consistent", weights = {}, training = candidate_evaluation,
	validation = candidate_evaluation, training_paired = paired, validation_paired = paired }
local volatile_pair = {
	mean_delta = 11, median_delta = -1, delta_stddev = 200, objective_score = -9,
	win_rate = 0.34, candidate_wins = 1, baseline_wins = 2, ties = 0, per_seed = {}, seeds = 3,
}
local volatile = { id = "volatile", weights = {}, training = { fitness = 1000, metrics = {} },
	validation = { fitness = 1000, metrics = {} }, training_paired = volatile_pair,
	validation_paired = volatile_pair }
local selection = Evolution.select_candidates({ volatile, consistent }, baseline, {
	minimum_mean_paired_delta = 0, minimum_paired_win_rate = 0.5,
	minimum_validation_mean_paired_delta = 0, minimum_validation_paired_win_rate = 0.5,
})
assert(selection.selected.id == "consistent", "raw fitness overrode consistent paired performance")

local FakeFitness = { compare_evaluations = Fitness.compare_evaluations }
function FakeFitness.evaluate(weights, seeds)
	local changed = (weights.x or 1) ~= 1
	local rows = {}
	for _, seed in ipairs(seeds) do rows[#rows + 1] = {
		seed = seed, fitness = changed and 20 or 10, survival = changed and 1 or 0,
		clear_rate = changed and 1 or 0.5, ante_reached = 1,
		failed_blind_deficit = changed and 0 or 0.5, average_score_margin = 0,
	} end
	return { fitness = changed and -100 or 100, per_seed = rows,
		metrics = { survival_rate = changed and 1 or 0, blind_clear_rate = changed and 1 or 0.5 } }
end
local fake_rng = { calls = 0 }
function fake_rng:next()
	self.calls = self.calls + 1
	return self.calls % 2 == 1 and 0 or 0.75
end
function fake_rng:integer() return 1 end
local evolved = Evolution.run({
	baseline_weights = { x = 1 }, training_seeds = { "T" }, validation_seeds = { "V" },
	test_seeds = { "X" }, fitness_weights = {}, paired_objective = { consistency_penalty = 0.1 },
	evolution = { population_size = 2, elite_count = 1, generations = 1,
		mutation_rate = 1, mutation_magnitude = 0.1 },
	selection = { validation_candidates_per_generation = 1 }, early_stopping = { enabled = false },
}, {
	Weights = { minimum = 0.25, maximum = 2.5, keys = function() return { "x" } end,
		copy = function(source) return { x = source and source.x or 1 } end },
	PRNG = { new = function() return fake_rng end },
}, { Fitness = FakeFitness, opponent = {} })
assert(evolved.best_training_candidate.weights.x ~= 1,
	"evolution ranked raw aggregate fitness above paired seed gains")

local spread, counts = Seeds.select_difficulty_spread({ per_seed = {
	{ seed = "E", survival = 1, clear_rate = 1, ante_reached = 5 },
	{ seed = "M", survival = 0, clear_rate = 0.8, ante_reached = 4 },
	{ seed = "H", survival = 0, clear_rate = 0.6, ante_reached = 3 },
	{ seed = "V", survival = 0, clear_rate = 0.1, ante_reached = 1 },
} }, 4, 5)
assert(#spread == 4 and counts.easy == 1 and counts.medium == 1
	and counts.hard == 1 and counts.very_hard == 1, "difficulty spread omitted a populated band")

print("paired_training_spec: ok")
