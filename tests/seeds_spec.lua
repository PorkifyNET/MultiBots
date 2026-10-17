local PRNG = dofile("bot/prng.lua")
local Seeds = dofile("training/seeds.lua")

local first = { seed_generation = { training_count = 32, validation_count = 16, test_count = 32 } }
local second = { seed_generation = { training_count = 32, validation_count = 16, test_count = 32 } }
local third = { seed_generation = { training_count = 32, validation_count = 16, test_count = 32 } }
local manifest = Seeds.apply(first, PRNG, "EXPERIMENT-A")
Seeds.apply(second, PRNG, "EXPERIMENT-A")
Seeds.apply(third, PRNG, "EXPERIMENT-B")
assert(#first.training_seeds == 32 and #first.validation_seeds == 16 and #first.test_seeds == 32,
	"generated seed counts do not match configuration")
for index, seed in ipairs(first.training_seeds) do
	assert(seed == second.training_seeds[index], "same experiment seed was not reproducible")
end
assert(first.training_seeds[1] ~= third.training_seeds[1], "different experiments reused generated seeds")
local seen = {}
for _, group in ipairs({ first.training_seeds, first.validation_seeds, first.test_seeds }) do
	for _, seed in ipairs(group) do
		assert(seed:sub(1, 1) == "*", "generated seed does not mirror ordered Multiplayer seeds")
		assert(not seen[seed], "generated train/validation/test sets overlap")
		seen[seed] = true
	end
end
assert(manifest.generated and manifest.experiment_seed == "EXPERIMENT-A", "seed manifest is incomplete")
print("seeds_spec: ok")
