local Recommendations = {}

local function append_paired(lines, name, result)
	local paired = result or {}
	local seeds = tonumber(paired.seeds) or 0
	local wins = tonumber(paired.candidate_wins) or 0
	lines[#lines + 1] = string.format(
		"%s: mean paired delta=%+.3f; candidate wins=%d/%d; 95%% CI=[%+.3f, %+.3f]",
		name, tonumber(paired.mean_delta) or 0, wins, seeds,
		tonumber(paired.confidence_95_low) or 0, tonumber(paired.confidence_95_high) or 0)
end

function Recommendations.render(result, Weights, player_log_paths)
	local lines = {
		"WEIGHT TUNING REPORT",
		"",
		"Candidate values are optimizer results, not automatic changes to live weights.",
	}
	if player_log_paths and #player_log_paths > 0 then
		lines[#lines + 1] = "Player score traces:"
		for _, path in ipairs(player_log_paths) do lines[#lines + 1] = "- " .. tostring(path) end
	end
	lines[#lines + 1] = ""
	append_paired(lines, "Validation", result.selected_candidate.validation_paired)
	append_paired(lines, "Untouched test", result.selected_candidate.test_paired)
	lines[#lines + 1] = "Promotion eligible: " .. tostring(result.promotion_eligible)
	lines[#lines + 1] = "Validation improved: " .. tostring(result.validation_improved)
	lines[#lines + 1] = "Untouched test improved: " .. tostring(result.test_improved)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Selected candidate weight changes from starting profile:"
	local changed = false
	for _, key in ipairs(Weights.keys()) do
		local difference = result.changes[key]
		if difference then
			changed = true
			lines[#lines + 1] = string.format("- %s: %.6f -> %.6f (%+.6f)",
				key, difference.baseline, difference.candidate,
				difference.candidate - difference.baseline)
		end
	end
	if not changed then lines[#lines + 1] = "- none; keep current values" end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Test this candidate before changing live weights."
	return table.concat(lines, "\n") .. "\n"
end

return Recommendations
