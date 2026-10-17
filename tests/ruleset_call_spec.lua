-- Regression test for the Lua multi-return bug that caused LoadReworks to see
-- the replacement count from string.gsub as its optional center key.
local observed = nil

local function load_reworks(ruleset, key)
	observed = { ruleset = ruleset, key = key }
end

local replay = { ruleset = "ruleset_mp_blitz" }
local ruleset_name = replay.ruleset:gsub("^ruleset_mp_", "")
load_reworks(ruleset_name)

assert(observed.ruleset == "blitz", "ruleset prefix should be removed")
assert(observed.key == nil, "gsub replacement count must not leak into the key argument")

print("ruleset_call_spec: ok")
