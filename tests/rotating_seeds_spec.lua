local Evolution = dofile("training/evolution.lua")
local Seeds = dofile("training/seeds.lua")
local Json = dofile("training/json.lua")
local calls = {}
local Fitness = { evaluate = function(weights, seeds)
	local first = tostring(seeds[1])
	calls[first] = (calls[first] or 0) + 1
	return { fitness = 100 + (weights.x or 0), metrics = {} }
end }
local Weights = {
	minimum = 0.25, maximum = 2.5,
	keys = function() return { "x" } end,
	copy = function(source) return { x = source and source.x or 1 } end,
}
local PRNG = dofile("bot/prng.lua")
local config = {
	experiment_seed = "ROTATING-SPEC",
	seed_generation = { enabled = true, rotate_training_each_generation = true },
	training_seeds = { "TRAIN-REFERENCE-A", "TRAIN-REFERENCE-B" },
	validation_seeds = { "VALID-A" }, test_seeds = { "TEST-A" },
	fitness_weights = {}, evolution = {
		population_size = 2, elite_count = 1, generations = 2,
		mutation_rate = 1, mutation_magnitude = 0.1, rng_seed = "ROTATE",
	},
	selection = { validation_candidates_per_generation = 1 },
	early_stopping = { enabled = false },
}
Evolution.run(config, { Weights = Weights, PRNG = PRNG }, {
	Fitness = Fitness, Json = Json, Seeds = Seeds, opponent = {},
})
local generated, frequencies = 0, {}
for seed, count in pairs(calls) do
	if seed:find("*AUTO-TRAINING", 1, true) then
		generated = generated + 1
		frequencies[#frequencies + 1] = count
	end
end
assert(generated == 2, "each generation should use a different generated training batch")
for _, count in ipairs(frequencies) do
	-- Two population candidates plus that generation's baseline see one common batch.
	assert(count == 3, "candidates within a generation did not share the same training batch")
end
print("rotating_seeds_spec: ok")
