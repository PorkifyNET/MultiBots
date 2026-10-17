local modules = {
	PRNG = dofile("bot/prng.lua"), Weights = dofile("bot/weights.lua"),
	Cards = dofile("bot/cards.lua"), Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"), Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"), Simulator = dofile("bot/simulator.lua"),
}
local Fitness = dofile("training/fitness.lua")
local Evolution = dofile("training/evolution.lua")
local Opponents = dofile("training/opponents.lua")
local PlayerTraces = dofile("training/player_traces.lua")
local Json = dofile("training/json.lua")
local config = {
	difficulty = "expert", max_ante = 1, stop_on_failed_blind = true,
	training_seeds = { "TRAIN-SPEC" }, validation_seeds = { "VALID-SPEC" },
	test_seeds = { "TEST-SPEC" },
	fitness_weights = {
		blind_clear_rate = 100, average_ante = 10, survival_rate = 20,
		average_score_margin = 5, failed_blind_deficit = -10,
		invalid_actions = -100000, crashes = -1000000,
	},
	evolution = { population_size = 2, elite_count = 1, generations = 1,
		mutation_rate = 1, mutation_magnitude = 0.05, rng_seed = "TRAINING-SPEC" },
}
local progress_events = {}
config.on_match_progress = function(label, event, index, total, seed)
		progress_events[#progress_events + 1] = {
			label = label, event = event, index = index, total = total, seed = seed,
		}
end
local opponent = Opponents.scripted()
local traces, trace_error = PlayerTraces.parse(table.concat({
	"00:00:01 PVP ante=2 bot_score=800 margin=-200 player_score=1000",
	"00:01:01 PVP ante=4 bot_score=4000 margin=-500 player_score=4500",
}, "\n"), "fixture")
assert(traces and traces[1] == 1000 and traces[2] == 1000
	and traces[3] == 1000 and traces[4] == 4500,
	trace_error or string.format("player trace scores were %s/%s/%s/%s",
		tostring(traces and traces[1]), tostring(traces and traces[2]),
		tostring(traces and traces[3]), tostring(traces and traces[4])))
local invalid_trace, invalid_error = PlayerTraces.parse("no PvP scores here", "empty fixture")
assert(not invalid_trace and invalid_error:match("contains no valid PvP player scores"),
	"player trace parser should reject logs without valid opponent scores")
local trace_opponent = Opponents.trace_set({ { 0, 100, 200 }, { 0, 1000, 2000 } })
local trace_context = { ante = 2, state = { seed = "same-seed" } }
local first_score = trace_opponent.score(trace_context)
assert(first_score == trace_opponent.score(trace_context)
	and (first_score == 100 or first_score == 1000),
	"trace opponent choice must remain deterministic for paired evaluations")
local baseline = Fitness.evaluate(modules.Weights.defaults, config.training_seeds, config, modules, opponent,
		"Regression baseline")
assert(type(baseline.fitness) == "number" and baseline.metrics.runs == 1, "fitness did not evaluate seed")
assert(baseline.metrics.crashes == 0 and baseline.metrics.invalid_actions == 0,
		"baseline training scenario failed")
assert(#progress_events == 2 and progress_events[1].label == "Regression baseline"
		and progress_events[1].event == "start" and progress_events[2].event == "finish"
		and progress_events[2].index == 1 and progress_events[2].total == 1
		and progress_events[2].seed == config.training_seeds[1],
		"fitness evaluation should report match start and completion")
config.on_match_progress = nil
local services = { Fitness = Fitness, Json = Json, opponent = opponent }
local generation_progress = {}
config.on_match_progress = function(label, event, index, total, seed, elapsed, success,
		generation, generation_total, completed, generation_matches)
	if generation then
		generation_progress[#generation_progress + 1] = {
			label = label, event = event, index = index, total = total, seed = seed,
			generation = generation, generation_total = generation_total,
			completed = completed, generation_matches = generation_matches,
		}
	end
end
local first = Evolution.run(config, modules, services)
assert(#generation_progress == 10 and generation_progress[1].generation == 1
	and generation_progress[1].generation_total == 1
	and generation_progress[1].generation_matches == 5
	and generation_progress[#generation_progress].completed == 5,
	"evolution should report per-generation match progress through completion")
config.on_match_progress = nil
local second = Evolution.run(config, modules, services)
assert(first.best.validation.fitness == second.best.validation.fitness,
	"evolution is not deterministic")
for key, value in pairs(first.best.weights) do
	assert(value == second.best.weights[key], "deterministic evolution changed " .. key)
end
assert(first.auto_promoted == false, "training must never auto-promote")
assert(first.baseline.test and first.selected_candidate.test, "test split was not reported")
assert(first.best_training_candidate and first.best_validation_candidate and first.selected_candidate,
	"separate candidate concepts were not reported")
print("training_spec: ok")
