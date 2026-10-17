local SnapshotBranch = {}

local function decode(value)
	return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function parse_flat_snapshot(value)
	local snapshot = { raw = value }
	for entry in tostring(value or ""):gmatch("[^|]+") do
		local key, item = entry:match("^([^:]+):(.*)$")
		if key then snapshot[key] = item end
	end
	return snapshot
end

function SnapshotBranch.load_store(path)
	local file = assert(io.open(path, "rb"))
	local snapshots = {}
	for line in file:lines() do
		if line:find(" SNAPSHOT ", 1, true) then
			local id = line:match("snapshot_id=([^%s]+)")
			local encoded = line:match("snapshot=([^%s]+)")
			if id and encoded then
				local raw = decode(encoded)
				snapshots[decode(id)] = parse_flat_snapshot(raw)
			end
		end
	end
	file:close()
	return snapshots
end

-- The adapter is deliberately injected by the offline trainer. Live gameplay
-- never imports this module and cannot inspect stored draw/deck information.
function SnapshotBranch.compare(snapshot, actions, adapter, options)
	assert(type(snapshot) == "table", "snapshot is required")
	assert(type(adapter) == "table" and type(adapter.simulate) == "function",
		"an offline snapshot simulation adapter is required")
	options = options or {}
	local rollouts = math.max(1, tonumber(options.rollouts) or 1)
	local results, best = {}, nil
	for _, action in ipairs(actions or {}) do
		local total, outcomes = 0, {}
		for rollout = 1, rollouts do
			local outcome = adapter.simulate(snapshot, action, {
				rollout = rollout,
				seed = tostring(options.seed or snapshot.seed or "snapshot") .. ":" .. rollout,
				offline_hidden_state = true,
			})
			local value = tonumber(outcome and (outcome.value or outcome.score)) or 0
			total = total + value
			outcomes[#outcomes + 1] = outcome
		end
		local result = { action = action, expected_outcome = total / rollouts, outcomes = outcomes }
		results[#results + 1] = result
		if not best or result.expected_outcome > best.expected_outcome then best = result end
	end
	for _, result in ipairs(results) do
		result.simulated_regret = best and best.expected_outcome - result.expected_outcome or 0
	end
	return { offline_only = true, results = results, best = best }
end

return SnapshotBranch
