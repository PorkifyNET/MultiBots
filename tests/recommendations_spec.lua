local Weights = dofile("bot/weights.lua")
local Recommendations = dofile("training/recommendations.lua")

local report = Recommendations.render({
	changes = {
		card_preservation = { baseline = 1, candidate = 1.125 },
	},
	promotion_eligible = false, validation_improved = true, test_improved = false,
	selected_candidate = {
		validation_paired = { seeds = 8, candidate_wins = 5, mean_delta = 12.5,
			confidence_95_low = 1.25, confidence_95_high = 23.75 },
		test_paired = { seeds = 16, candidate_wins = 7, mean_delta = -2.5,
			confidence_95_low = -12.75, confidence_95_high = 7.75 },
	},
}, Weights, { "player-run.log" })

assert(report:find("card_preservation: 1.000000 -> 1.125000 (+0.125000)", 1, true)
	and report:find("Validation: mean paired delta=+12.500", 1, true)
	and report:find("Untouched test: mean paired delta=-2.500", 1, true)
	and report:find("Promotion eligible: false", 1, true)
	and report:find("player-run.log", 1, true),
	"weight report should show candidate magnitude and held-out evidence")

print("recommendations_spec: ok")
