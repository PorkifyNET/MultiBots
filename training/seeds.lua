local Seeds = {}

local function positive_integer(value, fallback)
	return math.max(1, math.floor(tonumber(value) or fallback))
end

function Seeds.generate(PRNG, experiment_seed, split, count)
	local stream = PRNG.new(tostring(experiment_seed) .. ":" .. tostring(split))
	local result, seen = {}, {}
	while #result < positive_integer(count, 1) do
		local high = stream:integer(0, 2147483646)
		local low = stream:integer(0, 2147483646)
		-- The leading * mirrors live Multiplayer's ordered bot-seed convention.
		local seed = string.format("*AUTO-%s-%08X%08X", tostring(split):upper(), high, low)
		if not seen[seed] then seen[seed], result[#result + 1] = true, seed end
	end
	return result
end

function Seeds.apply(config, PRNG, experiment_seed)
	local options = config.seed_generation or {}
	if options.enabled == false then return {
		experiment_seed = experiment_seed or "explicit", generated = false,
		training_seeds = config.training_seeds, validation_seeds = config.validation_seeds,
		test_seeds = config.test_seeds,
	} end
	assert(experiment_seed and tostring(experiment_seed) ~= "", "an experiment seed is required")
	config.training_seeds = Seeds.generate(PRNG, experiment_seed, "training",
		positive_integer(options.training_count, 16))
	local validation_count = positive_integer(options.validation_count, 8)
	local test_count = positive_integer(options.test_count, 16)
	local pool_multiplier = options.difficulty_bands_enabled ~= false
		and positive_integer(options.difficulty_pool_multiplier, 4) or 1
	config.validation_seed_pool = Seeds.generate(PRNG, experiment_seed, "validation-pool",
		validation_count * pool_multiplier)
	config.test_seed_pool = Seeds.generate(PRNG, experiment_seed, "test-pool", test_count * pool_multiplier)
	config.validation_seeds = {}
	config.test_seeds = {}
	for index = 1, validation_count do config.validation_seeds[index] = config.validation_seed_pool[index] end
	for index = 1, test_count do config.test_seeds[index] = config.test_seed_pool[index] end
	config.experiment_seed = tostring(experiment_seed)
	return {
		experiment_seed = config.experiment_seed, generated = true,
		training_seeds = config.training_seeds, validation_seeds = config.validation_seeds,
		test_seeds = config.test_seeds,
	}
end

function Seeds.difficulty_band(row, max_ante)
	if tonumber(row.survival) and tonumber(row.survival) > 0
		or (tonumber(row.clear_rate) or 0) >= 0.95 then return "easy" end
	if (tonumber(row.clear_rate) or 0) >= 0.75 then return "medium" end
	if (tonumber(row.clear_rate) or 0) >= 0.50
		or (tonumber(row.ante_reached) or 0) >= math.max(1, (tonumber(max_ante) or 5) * 0.5)
		or (tonumber(row.failed_blind_deficit) or 1) <= 0.25 then
		return "hard"
	end
	return "very_hard"
end

function Seeds.select_difficulty_spread(evaluation, count, max_ante)
	local names = { "easy", "medium", "hard", "very_hard" }
	local buckets = { easy = {}, medium = {}, hard = {}, very_hard = {} }
	for _, row in ipairs(evaluation.per_seed or {}) do
		local band = Seeds.difficulty_band(row, max_ante)
		row.difficulty_band = band
		buckets[band][#buckets[band] + 1] = row
	end
	local selected, cursors = {}, { easy = 1, medium = 1, hard = 1, very_hard = 1 }
	while #selected < positive_integer(count, 1) do
		local added = false
		for _, name in ipairs(names) do
			local row = buckets[name][cursors[name]]
			if row and #selected < count then
				selected[#selected + 1] = row.seed
				cursors[name], added = cursors[name] + 1, true
			end
		end
		if not added then break end
	end
	local counts = {}
	for _, name in ipairs(names) do counts[name] = #buckets[name] end
	return selected, counts
end

return Seeds
