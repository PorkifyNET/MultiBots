return {
	difficulty = "expert",
	max_ante = 8,
	stop_on_failed_blind = true,
	-- tools/train.ps1 supplies a fresh experiment seed for every new run.
	-- Generated sets are saved in seed-manifest.json and restored on resume.
	seed_generation = {
		enabled = true,
		rotate_training_each_generation = true,
		training_count = 16,
		validation_count = 8,
		test_count = 16,
		difficulty_bands_enabled = true,
		difficulty_pool_multiplier = 4,
	},
	-- Fallback fixtures used only when seed_generation.enabled=false.
	training_seeds = {
		"TRAIN-001", "TRAIN-002", "TRAIN-003", "TRAIN-004",
		"TRAIN-005", "TRAIN-006", "TRAIN-007", "TRAIN-008",
	},
	validation_seeds = {
		"VALID-101", "VALID-102", "VALID-103", "VALID-104",
	},
	test_seeds = {
		"TEST-201", "TEST-202", "TEST-203", "TEST-204",
	},
	opponent = { kind = "scripted", score_ratios = { 0.70, 0.90, 1.05, 1.15 } },
	fitness_weights = {
		blind_clear_rate = 4000,
		average_ante = 500,
		survival_rate = 1800,
		average_score_margin = 300,
		failed_blind_deficit = -900,
		failed_with_unused_hands = -300,
		failed_with_unused_discards = -120,
		failed_with_unused_consumables = -150,
		average_ending_money = 2,
		pvp_win_rate = 1800,
		invalid_actions = -100000,
		crashes = -1000000,
		known_regression_failures = -50000,
	},
	evolution = {
		population_size = 8,
		elite_count = 2,
		generations = 10,
		mutation_rate = 0.35,
		mutation_magnitude = 0.18,
		rng_seed = "MULTIBOTS-EVOLUTION-1",
	},
	paired_objective = {
		-- Primary evolutionary signal for rotating batches.
		objective = "mean_with_consistency_penalty",
		consistency_penalty = 0.10,
		tie_epsilon = 0,
	},
	selection = {
		-- Validate several strong paired-training candidates. Final selection uses
		-- paired validation performance while enforcing minimum robust gains.
		mode = "max_paired_validation_with_training_floor",
		validation_candidates_per_generation = 3,
		minimum_mean_paired_delta = 0,
		minimum_paired_win_rate = 0.50,
		minimum_training_confidence_95_low = 0,
		minimum_validation_mean_paired_delta = 0,
		minimum_validation_paired_win_rate = 0.50,
		minimum_validation_confidence_95_low = 0,
		minimum_validation_improvement = 0,
		maximum_validation_regression = 0,
		-- Used only when mode = "weighted".
		training_weight = 0.25,
		validation_weight = 0.75,
	},
	promotion = {
		minimum_validation_mean_paired_delta = 0,
		minimum_validation_paired_win_rate = 0.50,
		minimum_validation_confidence_95_low = 0,
		minimum_validation_improvement = 1,
		minimum_test_mean_paired_delta = 0,
		minimum_test_paired_win_rate = 0.50,
		minimum_test_confidence_95_low = 0,
		maximum_survival_regression = 0,
		maximum_clear_rate_regression = 0,
	},
	tournament = {
		seed_count = 128,
		difficulty_pool_multiplier = 4,
	},
	early_stopping = {
		enabled = false,
		meaningful_validation_improvement = 1,
		plateau_generations = 3,
		patience = 8,
		minimum_generations = 5,
	},
}
