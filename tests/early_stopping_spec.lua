local Evolution = dofile("training/evolution.lua")
local Json = dofile("training/json.lua")
local calls = {}
local Fitness = { evaluate = function(_, seeds)
	calls[#calls + 1] = table.concat(seeds, ",")
	return { fitness = 100, metrics = {} }
end }
local Weights = {
	minimum = 0.25, maximum = 2.5,
	keys = function() return { "x" } end,
	copy = function(source) return { x = source and source.x or 1 } end,
}
local PRNG = { new = function()
	return {
		state = 1,
		next = function(self) self.state = self.state + 1; return 0.5 end,
		integer = function() return 1 end,
	}
end }
local config = {
	training_seeds = { "TRAIN-A", "TRAIN-B" },
	validation_seeds = { "VALID-A" }, test_seeds = { "TEST-A", "TEST-B" },
	fitness_weights = {}, evolution = {
		population_size = 2, elite_count = 1, generations = 5,
		mutation_rate = 1, mutation_magnitude = 0.1, rng_seed = "STOP",
	},
	selection = { validation_candidates_per_generation = 2 },
	early_stopping = {
		enabled = true, meaningful_validation_improvement = 1,
		plateau_generations = 1, patience = 2, minimum_generations = 1,
	},
}
local result = Evolution.run(config, { Weights = Weights, PRNG = PRNG }, {
	Fitness = Fitness, Json = Json, opponent = {},
})
assert(result.plateau.detected, "validation plateau was not detected")
assert(result.plateau.early_stopped and result.plateau.stopped_generation == 2,
	"training did not stop at configured plateau patience")
assert(#result.history == 2, "early stopping ran extra generations")
assert(calls[#calls - 1] == "TEST-A,TEST-B" and calls[#calls] == "TEST-A,TEST-B",
	"test seeds must only evaluate baseline and the frozen selected candidate at the end")
for index = 1, #calls - 2 do
	assert(not calls[index]:find("TEST", 1, true), "test seed leaked into evolution or selection")
end
print("early_stopping_spec: ok")
