local modules = {
	PRNG = dofile("bot/prng.lua"),
	Weights = dofile("bot/weights.lua"),
	Cards = dofile("bot/cards.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
local Generator = dofile("generator.lua")
modules.Generator = Generator
Generator.configure(modules)

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
	end
end

local replay = Generator.build({ difficulty = "normal", seed = "TESTSEED", max_ante = 8 })
assert_equal(replay.seed, "TESTSEED", "seed")
assert_equal(replay.gamemode, "gamemode_mp_attrition", "gamemode")
assert_equal(replay.nemesis_name, "MultiBot (Normal)", "bot name")
assert_equal(replay._multibots_bot_seed, "TESTSEED", "default simulation seed")
assert_equal(replay._multibots_state.weights.immediate_score, 1, "default strategy weight")
assert_equal(#replay.ante_snapshots[1].hands, 4, "hand count")
local profiled = Generator.build({ difficulty = "expert", seed = "PROFILED", max_ante = 1,
	weights = { immediate_score = 0.75 }, weight_profile = "candidate-test" })
assert_equal(profiled._multibots_state.weights.immediate_score, 0.75, "trained strategy weight")
assert_equal(profiled._multibots_weight_profile, "candidate-test", "strategy profile label")

for ante = 1, 8 do
	local previous = 0
	local hands = replay.ante_snapshots[ante].hands
	assert(#hands > 0 and #hands <= 4, "a simulated round must play one to four hands")
	for hand_index, hand in ipairs(hands) do
		local score = tonumber(hand.score)
		assert(score and score > previous, "scores must increase within an ante")
		assert_equal(hand.hands_left, 4 - hand_index, "hands remaining")
		assert_equal(hand.side, "enemy", "replay side")
		assert(hand.hand_name and hand.hand_score > 0, "simulated hand metadata")
		previous = score
	end
end

local easy = Generator.build({ difficulty = "easy", seed = "SAMESEED", max_ante = 2 })
local expert = Generator.build({ difficulty = "expert", seed = "SAMESEED", max_ante = 2 })
assert(#easy._multibots_state.decisions > 0, "easy bot should record decisions")
assert(#expert._multibots_state.decisions > 0, "expert bot should record decisions")

local replay_again = Generator.build({ difficulty = "normal", seed = "TESTSEED", max_ante = 8 })
for ante = 1, 8 do
	local first = replay.ante_snapshots[ante].hands
	local second = replay_again.ante_snapshots[ante].hands
	assert_equal(#first, #second, "deterministic hand count")
	for index, hand in ipairs(first) do
		assert_equal(hand.score, second[index].score, "deterministic score")
		assert_equal(hand.hand_name, second[index].hand_name, "deterministic hand choice")
	end
end

local ordered = Generator.build({ difficulty = "normal", seed = "ORDERED", max_ante = 1, the_order = true })
assert_equal(ordered.seed, "ORDERED", "player-facing seed remains unprefixed")
assert_equal(ordered._multibots_bot_seed, "*ORDERED", "The Order simulation uses canonical prefixed seed")

local split_seed = Generator.build({
	difficulty = "normal",
	seed = "PLAYER",
	bot_seed = "BOT",
	max_ante = 1,
})
assert_equal(split_seed.seed, "PLAYER", "player seed")
assert_equal(split_seed._multibots_bot_seed, "BOT", "separate bot seed")

local named = Generator.build({ difficulty = "hard", seed = "NAMED", max_ante = 1, bot_name = "Lucky Joker" })
assert_equal(named.nemesis_name, "Lucky Joker", "custom bot name")

print("generator_spec: ok")
