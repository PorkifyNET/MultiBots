local Rulesets = dofile("bot/rulesets.lua")

for _, key in ipairs({
	"standard_ranked",
	"legacy_ranked",
	"smallworld",
	"sandbox",
}) do
	assert(Rulesets.is_matchmaking(key), key .. " should be matchmaking")
	assert(Rulesets.is_matchmaking("ruleset_mp_" .. key), key .. " registered key should be matchmaking")
	assert(Rulesets.is_matchmaking({ key = key }), key .. " object should be matchmaking")
	assert(not Rulesets.allows_bot(key), key .. " should reject bots")
end

assert(Rulesets.is_matchmaking({ key = "future_queue", selection_group_key = "k_matchmaking" }),
	"new matchmaking-group rulesets should reject bots without a hard-coded key")

for _, key in ipairs({ "traditional", "vanilla", "blitz", "experimental" }) do
	assert(not Rulesets.is_matchmaking(key), key .. " should not be matchmaking")
	assert(Rulesets.allows_bot({ key = key }), key .. " should allow bots")
end

assert(not Rulesets.allows_bot(nil), "missing ruleset should fail closed")

print("rulesets_spec: ok")
