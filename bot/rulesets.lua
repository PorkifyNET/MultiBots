local Rulesets = {}

-- Known keys cover older Multiplayer builds; current builds also expose the
-- selection group on registered rulesets.
local matchmaking = {
	standard_ranked = true,
	legacy_ranked = true,
	smallworld = true,
	sandbox = true,
}

local function key_of(ruleset)
	local key = type(ruleset) == "table" and ruleset.key or ruleset
	if type(key) ~= "string" then return nil end
	return key:gsub("^ruleset_mp_", "")
end

function Rulesets.is_matchmaking(ruleset)
	if type(ruleset) == "table" and ruleset.selection_group_key == "k_matchmaking" then return true end
	local key = key_of(ruleset)
	return key ~= nil and matchmaking[key] == true
end

function Rulesets.allows_bot(ruleset)
	return key_of(ruleset) ~= nil and not Rulesets.is_matchmaking(ruleset)
end

return Rulesets
