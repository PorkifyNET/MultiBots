local config = dofile("training/config.lua")
config.max_ante = 1
config.seed_generation.training_count = 1
config.seed_generation.validation_count = 1
config.seed_generation.test_count = 1
config.evolution.population_size = 2
config.evolution.elite_count = 1
config.evolution.generations = 1
config.selection.validation_candidates_per_generation = 1
config.early_stopping.enabled = false
config.tournament.seed_count = 4
config.tournament.difficulty_pool_multiplier = 2
return config
