local Generator = {}
local dependencies = nil

Generator.difficulty_order = { "easy", "normal", "hard", "expert" }
Generator.difficulties = {
	easy = {
		name = "Easy",
		tldr = "Casual and unpredictable.",
		description = "The bot is not just a clown, it is the whole Mega Buffoon Pack.",
	},
	normal = {
		name = "Normal",
		tldr = "A balanced opponent.",
		description = "Usually follows its build plan, but still makes noticeable mistakes.",
	},
	hard = {
		name = "Hard",
		tldr = "Strong and consistent.",
		description = "Rarely deviates from strong actions and searches more possible discard outcomes.",
	},
	expert = {
		name = "Expert",
		tldr = "Relentless, with no deliberate mistakes.",
		description = "Always takes its highest-rated action and uses the deepest available discard search.",
	},
}

function Generator.configure(value)
	dependencies = value
end

local function require_dependencies()
	if not dependencies then error("MultiBots generator dependencies have not been configured") end
	for _, name in ipairs({ "PRNG", "Cards", "Evaluator", "Policy", "Simulator" }) do
		if not dependencies[name] then error("MultiBots generator is missing dependency " .. name) end
	end
	return dependencies
end

function Generator.base_score(ante)
	return require_dependencies().Simulator.base_score(ante)
end

function Generator.score_string(value)
	if value < 1e15 then return string.format("%.0f", value) end
	return string.format("%.12e", value)
end

function Generator.build(options)
	options = options or {}
	local deps = require_dependencies()
	local difficulty_key = Generator.difficulties[options.difficulty] and options.difficulty or "normal"
	local difficulty = Generator.difficulties[difficulty_key]
	local seed = tostring(options.seed or "MULTBOT")
	local simulation_seed = tostring(options.bot_seed or seed)
	if options.the_order == true and simulation_seed:sub(1, 1) ~= "*" then simulation_seed = "*" .. simulation_seed end
	local snapshots, final_state = deps.Simulator.run({
		seed = simulation_seed,
		difficulty = difficulty_key,
		decision_temperature = options.decision_temperature,
		max_ante = tonumber(options.max_ante) or 64,
		the_order = options.the_order == true,
		banned_jokers = options.banned_jokers or {},
		deck = options.deck or "Red Deck",
		weights = options.weights,
	}, deps)

	return {
		seed = seed,
		stake = tonumber(options.stake) or 1,
		deck = options.deck or "Red Deck",
		ruleset = options.ruleset or "ruleset_mp_blitz",
		gamemode = options.gamemode or "gamemode_mp_attrition",
		player_name = options.player_name or "Player",
		nemesis_name = options.bot_name or "MultiBot (" .. difficulty.name .. ")",
		ante_snapshots = snapshots,
		_multibots = true,
		_multibots_difficulty = difficulty_key,
		_multibots_decision_temperature = tonumber(options.decision_temperature),
		_multibots_bot_seed = simulation_seed,
		_multibots_weight_profile = options.weight_profile or "defaults",
		_multibots_state = final_state,
	}
end

return Generator
