local Opponents = {}

local function opponent(kind, scorer, description)
	return { kind = kind, score = scorer, description = description }
end

function Opponents.none()
	return opponent("none", function() return 0 end, "No PvP pressure")
end

function Opponents.scripted(options)
	options = options or {}
	local ratios = options.score_ratios or { 0.70, 0.90, 1.05, 1.15 }
	return opponent("scripted", function(context)
		local index = math.max(1, math.min(#ratios, (tonumber(context.ante) or 2) - 1))
		local base = tonumber(context.base_score) or 0
		return math.floor(base * 2 * (tonumber(ratios[index]) or 1) + 0.5)
	end, "Deterministic score ratios by Ante")
end

function Opponents.trace(scores)
	scores = scores or {}
	return opponent("trace", function(context)
		return tonumber(scores[context.ante]) or tonumber(scores[#scores]) or 0
	end, "Recorded opponent score trace")
end

local function trace_index(seed, count)
	local hash = 0
	for index = 1, #seed do
		hash = (hash * 33 + seed:byte(index)) % 2147483647
	end
	return hash % count + 1
end

function Opponents.trace_set(traces)
	assert(type(traces) == "table" and #traces > 0, "recorded opponent traces are required")
	return opponent("trace_set", function(context)
		local state = context.state or {}
		local trace = traces[trace_index(tostring(state.seed or ""), #traces)] or {}
		return tonumber(trace[context.ante]) or tonumber(trace[#trace]) or 0
	end, "Seed-paired recorded player score traces")
end

function Opponents.from_config(config)
	config = config or {}
	if config.kind == "none" then return Opponents.none() end
	if config.kind == "trace" then return Opponents.trace(config.scores) end
	if config.kind == "trace_set" then return Opponents.trace_set(config.traces) end
	return Opponents.scripted(config)
end

return Opponents
