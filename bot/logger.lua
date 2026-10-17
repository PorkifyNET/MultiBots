local Logger = { path = nil, snapshot_path = nil, debug_path = nil, report_path = nil }

local function clean(value)
	return tostring(value == nil and "" or value):gsub("[\r\n]", " ")
end

-- Percent encoding keeps every record on one line and makes whitespace-safe
-- key=value parsing possible without a JSON dependency in the game runtime.
local function encode(value)
	return (clean(value):gsub("[%%%s=]", function(character)
		return string.format("%%%02X", string.byte(character))
	end))
end

local function fields(values)
	local out = {}
	for key, value in pairs(values or {}) do
		if value ~= nil then out[#out + 1] = tostring(key) .. "=" .. encode(value) end
	end
	table.sort(out)
	return table.concat(out, " ")
end

local function split_csv(value)
	local out = {}
	for token in tostring(value or ""):gmatch("[^,]+") do
		if token ~= "" and token ~= "none" then out[#out + 1] = token end
	end
	return out
end

local function plan_key(values)
	local primary = values.plan_primary or values.plan
	local secondary = values.plan_secondary
	if not secondary or secondary == "" or secondary == "none" then return primary end
	primary, secondary = tostring(primary or ""), tostring(secondary)
	return primary < secondary and primary .. "/" .. secondary or secondary .. "/" .. primary
end

local function new_summary(metadata)
	return {
		threshold = tonumber(metadata and metadata.high_regret_threshold) or 25,
		variance_ratio = tonumber(metadata and metadata.score_variance_ratio) or 4,
		reorder_threshold = tonumber(metadata and metadata.reorder_threshold) or 3,
		unknown = {}, seen_shops = {}, failures = {}, pvp = {}, lifecycle = {}, high_regret = {},
		seen_unknown_vouchers = {},
		final = {},
		player_actions = {},
		reorders = {}, invalid = {}, variance = {}, previous_play = nil, last_hand = nil,
	}
end

local function held_count(value)
	return #split_csv(value)
end

local economy_consumables = {
	c_hermit = true,
	c_temperance = true,
}

local function actionable_consumables(failure)
	local keys = split_csv(failure.consumables)
	if #keys == 0 then return failure.consumables_remaining end
	local count = 0
	for _, key in ipairs(keys) do
		if not economy_consumables[key] then count = count + 1 end
	end
	return count
end

local function failure_anomalies(failure)
	local flags = {}
	local consumables = actionable_consumables(failure)
	if failure.deficit < 5 then flags[#flags + 1] = "near miss <5%"
	elseif failure.deficit < 10 then flags[#flags + 1] = "near miss <10%" end
	if failure.hands_remaining > 0 then flags[#flags + 1] = "unused hands=" .. failure.hands_remaining end
	if failure.discards_remaining > 0 then flags[#flags + 1] = "unused discards=" .. failure.discards_remaining end
	if consumables > 0 then
		flags[#flags + 1] = "unused consumables=" .. consumables
	end
	local half_discards = failure.discards_available > 0
		and failure.discards_remaining >= math.ceil(failure.discards_available / 2)
	if failure.hands_remaining > 0 or half_discards
		or (failure.deficit < 10 and (failure.discards_remaining > 0 or consumables > 0)) then
		flags[#flags + 1] = "suspicious resource conservation"
	end
	return flags
end

local function observe(kind, values)
	local summary = Logger.summary
	if not summary then return end
	values = values or {}
	local regret = tonumber(values.regret)
	local best_utility = tonumber(values.best_utility)
	local regret_percent = regret and best_utility and best_utility > 0
		and regret / best_utility * 100 or regret
	if regret_percent and regret_percent >= summary.threshold then
		summary.high_regret[#summary.high_regret + 1] = {
			id = values.decision_id, regret = regret_percent, action = values.action or values.chosen,
			snapshot_id = values.snapshot_id,
		}
	end
	if kind == "SHOP_DECISION" then
		if values.replacement and values.replacement ~= "" then
			summary.lifecycle[#summary.lifecycle + 1] = "replace:" .. tostring(values.replacement)
				.. "->" .. tostring(values.chosen or "unknown")
		end
		if values.shop_id and summary.seen_shops[values.shop_id] then return end
		if values.shop_id then summary.seen_shops[values.shop_id] = true end
		local supported = {}
		for _, key in ipairs(split_csv(values.supported)) do supported[key] = (supported[key] or 0) + 1 end
		for _, key in ipairs(split_csv(values.offered)) do
			if (supported[key] or 0) > 0 then supported[key] = supported[key] - 1
			elseif not key:match("^v_") or not summary.seen_unknown_vouchers[key] then
				summary.unknown[key] = (summary.unknown[key] or 0) + 1
				if key:match("^v_") then summary.seen_unknown_vouchers[key] = true end
			end
		end
	elseif kind == "BLIND_FAILURE" or (kind == "DECISION" and values.action == "fail_round") then
		local score, target = tonumber(values.score) or 0, tonumber(values.target) or 0
		local last = summary.last_hand or {}
		local hands_remaining = tonumber(values.hands_remaining)
		if hands_remaining == nil and last.action == "play" then
			hands_remaining = math.max(0, (tonumber(last.hands_remaining) or 1) - 1)
		end
		local failure = {
			ante = values.ante, blind = values.blind or values.round,
			deficit = target > 0 and math.max(0, (target - score) / target * 100) or 0,
			hands_remaining = hands_remaining or 0,
			hands_available = tonumber(values.hands_available) or 0,
			discards_remaining = tonumber(values.discards_remaining)
				or tonumber(last.discards_remaining) or 0,
			discards_available = tonumber(values.discards_available) or 0,
			consumables_remaining = tonumber(values.consumables_remaining)
				or held_count(values.consumables),
			consumables_available = tonumber(values.consumables_available) or 0,
			consumables = values.consumables,
			snapshot_id = values.snapshot_id,
		}
		failure.anomalies = failure_anomalies(failure)
		summary.failures[#summary.failures + 1] = failure
	elseif kind == "PVP" then
		local bot, player = tonumber(values.bot_score) or 0, tonumber(values.player_score) or 0
		summary.pvp[#summary.pvp + 1] = { won = bot >= player, margin = bot - player, ante = values.ante }
	elseif kind == "FINAL_BOT" then
		summary.final.bot = values
	elseif kind == "FINAL_PLAYER" then
		summary.final.player = values
	elseif kind == "PLAYER_ACTION" then
		local action = tostring(values.action or "unknown")
		summary.player_actions[action] = (summary.player_actions[action] or 0) + 1
		summary.player_action_samples = summary.player_action_samples or {}
		if #summary.player_action_samples < 30 then
			summary.player_action_samples[#summary.player_action_samples + 1] = values
		end
	elseif kind == "DECISION" then
		local action = values.action
		if action == "buy_pack" and values.revealed then
			local modeled = {}
			for entry in tostring(values.modeled or ""):gmatch("[^,]+") do
				modeled[entry:match("^([^:]+)") or entry] = true
			end
			local supported = {}
			for _, key in ipairs(split_csv(values.supported)) do supported[key] = true end
			for _, key in ipairs(split_csv(values.revealed)) do
				if key:match("^[jcpv]_") and not modeled[key] and not supported[key] then
					summary.unknown[key] = (summary.unknown[key] or 0) + 1
				end
			end
		end
		if action == "buy_joker" or action == "sell_joker" or action == "destroy_joker"
			or action == "create_joker" then
			summary.lifecycle[#summary.lifecycle + 1] = tostring(action) .. ":" .. tostring(values.value or "")
		elseif action == "reorder_jokers" then
			local key = tostring(values.ante or "?") .. ":" .. tostring(values.round or "?")
			local entry = summary.reorders[key] or { count = 0, copy = false, ante = values.ante, round = values.round }
			entry.count = entry.count + 1
			local order = tostring(values.from or "") .. "," .. tostring(values.to or "")
			entry.copy = entry.copy or order:find("j_blueprint", 1, true) ~= nil
				or order:find("j_brainstorm", 1, true) ~= nil
			summary.reorders[key] = entry
		elseif action == "play" then
			local score = tonumber(values.score) or 0
			local current_plan = plan_key(values)
			local previous = summary.previous_play
			if previous and previous.plan ~= current_plan and previous.score > 0 and score > 0
				and previous.ante == values.ante and previous.round == values.round
				and previous.jokers == values.jokers then
				local ratio = math.max(score / previous.score, previous.score / score)
				if ratio >= summary.variance_ratio then summary.variance[#summary.variance + 1] = {
					id = values.decision_id, ratio = ratio, from = previous.plan, to = current_plan,
				} end
			end
			summary.previous_play = {
				score = score, plan = current_plan, ante = values.ante,
				round = values.round, jokers = values.jokers,
			}
		end
		if action == "play" or action == "discard" then summary.last_hand = values end
	elseif kind == "INVALID" or kind == "CRASH" then
		summary.invalid[#summary.invalid + 1] = values.kind or values.error or kind
	end
end

local function count_map(values)
	local total = 0
	for _, count in pairs(values or {}) do total = total + count end
	return total
end

local function unique_count(values)
	local total = 0
	for _ in pairs(values or {}) do total = total + 1 end
	return total
end

local function sorted_keys(values)
	local keys = {}
	for key in pairs(values or {}) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

local function split(value, separator)
	local out = {}
	for token in tostring(value or ""):gmatch("[^" .. separator .. "]+") do
		if token ~= "" and token ~= "none" then out[#out + 1] = token end
	end
	return out
end

local function card_frequencies(deck)
	local counts = {}
	for _, card in ipairs(split(deck, ";")) do counts[card] = (counts[card] or 0) + 1 end
	local ranked = {}
	for card, count in pairs(counts) do ranked[#ranked + 1] = { card = card, count = count } end
	table.sort(ranked, function(a, b)
		return a.count == b.count and a.card < b.card or a.count > b.count
	end)
	return ranked
end

local function append_final_build(lines, label, final)
	final = final or {}
	lines[#lines + 1] = ""
	lines[#lines + 1] = label .. " final build:"
	local details = split(final.joker_details, ",")
	if #details == 0 then details = split(final.jokers, ",") end
	if #details == 0 then
		lines[#lines + 1] = "- Jokers: none"
	else
		lines[#lines + 1] = "Jokers:"
		for _, detail in ipairs(details) do lines[#lines + 1] = "- " .. detail end
	end
	lines[#lines + 1] = string.format("Top deck cards (%s total):", tostring(final.deck_count or 0))
	local ranked = card_frequencies(final.deck)
	if #ranked == 0 then lines[#lines + 1] = "- none" end
	for index = 1, math.min(3, #ranked) do
		lines[#lines + 1] = string.format("- %s: %d", ranked[index].card, ranked[index].count)
	end
end

local function render_report(result, values)
	local summary, priority = Logger.summary, {}
	for _, failure in ipairs(summary.failures) do
		local suffix = #failure.anomalies > 0 and " (" .. table.concat(failure.anomalies, "; ") .. ")" or ""
		priority[#priority + 1] = string.format("Ante %s %s failed by %.1f%%%s",
			tostring(failure.ante), tostring(failure.blind), failure.deficit, suffix)
	end
	for _, item in ipairs(summary.high_regret) do priority[#priority + 1] = string.format(
		"Decision %s had regret %.1f%%", tostring(item.id), item.regret) end
	for _, reorder in pairs(summary.reorders) do
		if reorder.copy and reorder.count >= summary.reorder_threshold then priority[#priority + 1] = string.format(
			"Copy Joker caused %d reorder events in Ante %s %s", reorder.count,
			tostring(reorder.ante), tostring(reorder.round)) end
	end
	local unknown_total = count_map(summary.unknown)
	local unknown_unique = unique_count(summary.unknown)
	if unknown_total > 0 then priority[#priority + 1] = string.format(
		"%d unique unsupported objects across %d encounters", unknown_unique, unknown_total) end
	for _, variance in ipairs(summary.variance) do priority[#priority + 1] = string.format(
		"Decision %s followed a plan change with %.1fx score variance", tostring(variance.id), variance.ratio) end
	local lines = { "MATCH QUALITY REPORT", "", string.format("Result: %s, Ante %s", tostring(result),
		tostring(values and values.ante or "?")), "", "High-priority review:", "" }
	lines[#lines + 1] = "Player-win review:"
	lines[#lines + 1] = "Observed player actions:"
	local player_action_count = 0
	for _, action in ipairs(sorted_keys(summary.player_actions)) do
		player_action_count = player_action_count + summary.player_actions[action]
		lines[#lines + 1] = string.format("- %s: %d", action, summary.player_actions[action])
	end
	if player_action_count == 0 then
		lines[#lines + 1] = "- No player actions were captured."
		lines[#lines + 1] = "No weight review is possible without player action evidence."
	else
		local review_weights = {}
		for action, count in pairs(summary.player_actions) do
			if action == "play" or action == "discard" then
				for _, key in ipairs({ "immediate_score", "discard_potential", "card_preservation", "survival_pressure" }) do
					review_weights[key] = (review_weights[key] or 0) + count
				end
			elseif action == "buy" or action == "buy_and_use" or action == "sell" then
				for _, key in ipairs({ "joker_value", "joker_synergy", "economy_value" }) do
					review_weights[key] = (review_weights[key] or 0) + count
				end
			end
		end
		local ranked_weights = {}
		for key, count in pairs(review_weights) do ranked_weights[#ranked_weights + 1] = { key = key, count = count } end
		table.sort(ranked_weights, function(a, b)
			return a.count == b.count and a.key < b.key or a.count > b.count
		end)
		if #ranked_weights > 0 then
			lines[#lines + 1] = "Weight areas to review (behavior counts only; no direction inferred):"
			for index = 1, math.min(3, #ranked_weights) do
				lines[#lines + 1] = "- " .. ranked_weights[index].key
			end
		end
		lines[#lines + 1] = "Action samples (pre-action state):"
		for _, sample in ipairs(summary.player_action_samples or {}) do
			lines[#lines + 1] = string.format("- Ante %s %s %s: selected=%s target=%s hand=%s",
				tostring(sample.ante or "?"), tostring(sample.blind or "?"), tostring(sample.action),
				tostring(sample.selected or "none"), tostring(sample.target or "none"),
				tostring(sample.hand or "none"))
		end
		lines[#lines + 1] = "Action counts cannot estimate numeric weight changes."
		lines[#lines + 1] = "Run the trainer to measure candidate values against recorded player scores."
	end
	if #priority == 0 then lines[#lines + 1] = "No high-priority strategy issues detected." end
	for index, item in ipairs(priority) do lines[#lines + 1] = tostring(index) .. ". " .. item end
	lines[#lines + 1] = #summary.invalid == 0 and "No crashes or invalid actions"
		or (#summary.invalid .. " crashes or invalid actions")
	local wins, losses = 0, 0
	for _, item in ipairs(summary.pvp) do if item.won then wins = wins + 1 else losses = losses + 1 end end
	lines[#lines + 1] = ""
	lines[#lines + 1] = string.format("PvP: %d wins, %d losses", wins, losses)
	for _, item in ipairs(summary.pvp) do lines[#lines + 1] = string.format(
		"- Ante %s: %s by %.0f", tostring(item.ante), item.won and "win" or "loss", math.abs(item.margin)) end
	append_final_build(lines, "Bot", summary.final.bot)
	append_final_build(lines, "Player", summary.final.player)
	lines[#lines + 1] = string.format("Joker lifecycle events: %d", #summary.lifecycle)
	for _, item in ipairs(summary.lifecycle) do lines[#lines + 1] = "- " .. item end
	lines[#lines + 1] = string.format("Unsupported objects: %d unique, %d encounters", unknown_unique, unknown_total)
	for _, key in ipairs(sorted_keys(summary.unknown)) do lines[#lines + 1] = string.format(
		"- %s: %d", tostring(key), summary.unknown[key]) end
	lines[#lines + 1] = "Joker reorder groups:"
	for _, key in ipairs(sorted_keys(summary.reorders)) do
		local item = summary.reorders[key]
		if item.count >= 2 then lines[#lines + 1] = string.format("- %s: %d%s", key, item.count,
			item.copy and " (Blueprint/Brainstorm)" or "") end
	end
	lines[#lines + 1] = string.format("High-regret threshold: %.1f%%", summary.threshold)
	return table.concat(lines, "\n") .. "\n"
end

function Logger.start(metadata)
	Logger.path, Logger.snapshot_path, Logger.debug_path, Logger.report_path = nil, nil, nil, nil
	Logger.summary = nil
	if not NFS or not SMODS or not SMODS.Mods or not SMODS.Mods.MultiBots then return nil end
	local directory = SMODS.Mods.MultiBots.path .. "logs/"
	local ok = NFS.createDirectory(directory)
	if ok == false then return nil end
	local stamp = os.date("%Y.%m.%d-%H.%M.%S")
	local identity = tostring(metadata and metadata.name or ""):gsub("[^%w%-_]", "-"):gsub("%-+", "-")
	if identity ~= "" then stamp = stamp .. "-" .. identity end
	Logger.path = directory .. "multibots-" .. stamp .. ".log"
	Logger.snapshot_path = directory .. "multibots-" .. stamp .. ".snapshots.log"
	Logger.report_path = directory .. "multibots-" .. stamp .. ".report.txt"
	Logger.pending_debug_path = directory .. "multibots-debug-" .. stamp .. ".log"
	NFS.remove(Logger.report_path)
	Logger.metadata = metadata or {}
	Logger.summary = new_summary(metadata)
	NFS.write(Logger.path, "MULTIBOTS_LOG v2 encoding=percent " .. fields(metadata) .. "\n")
	NFS.write(Logger.snapshot_path, "MULTIBOTS_SNAPSHOTS v1 encoding=percent\n")
	return Logger.path
end

function Logger.write(kind, values)
	if not Logger.path or not NFS then return end
	local logged = {}
	for key, value in pairs(values or {}) do logged[key] = value end
	if logged.snapshot and logged.decision_id then
		logged.snapshot_id = logged.decision_id
		NFS.append(Logger.snapshot_path, os.date("%H:%M:%S") .. " SNAPSHOT " .. fields({
			snapshot_id = logged.snapshot_id, snapshot = logged.snapshot,
		}) .. "\n")
		logged.snapshot = nil
	end
	observe(kind, logged)
	local encoded = fields(logged)
	NFS.append(Logger.path, os.date("%H:%M:%S") .. " " .. clean(kind)
		.. (#encoded > 0 and " " .. encoded or "") .. "\n")
end

-- Technical output is lazy: normal training matches create no debug log.
function Logger.write_debug(kind, values)
	if not Logger.path or not NFS then return end
	if tostring(kind):find("ERROR", 1, true) or kind == "INVALID" or kind == "CRASH" then
		observe("INVALID", values)
	end
	if not Logger.debug_path then
		Logger.debug_path = Logger.pending_debug_path
		NFS.write(Logger.debug_path, "MULTIBOTS_DEBUG v1 " .. fields(Logger.metadata) .. "\n")
	end
	local encoded = fields(values)
	NFS.append(Logger.debug_path, os.date("%H:%M:%S") .. " " .. clean(kind)
		.. (#encoded > 0 and " " .. encoded or "") .. "\n")
end

function Logger.finish(result, values)
	if not Logger.path or not Logger.summary or not NFS then return nil end
	values = values or {}
	values.result = result
	Logger.write("SUMMARY", {
		unknown = count_map(Logger.summary.unknown),
		unsupported_encounters = count_map(Logger.summary.unknown),
		unsupported_unique = unique_count(Logger.summary.unknown), failures = #Logger.summary.failures,
		pvp_rounds = #Logger.summary.pvp, joker_events = #Logger.summary.lifecycle,
		high_regret = #Logger.summary.high_regret, invalid = #Logger.summary.invalid,
		variance = #Logger.summary.variance, threshold = Logger.summary.threshold,
	})
	Logger.write("END", values)
	if result == "loseGame" and Logger.report_path then
		NFS.write(Logger.report_path, render_report(result, values))
	end
	local path = Logger.path
	Logger.path = nil
	return path
end

return Logger
