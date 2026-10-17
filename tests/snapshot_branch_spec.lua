local Branch = dofile("training/snapshot_branch.lua")
local snapshot = { seed = "S", hand = "A,B", draw = "C,D" }
local actions = { { key = "play" }, { key = "discard" } }
local adapter = { simulate = function(_, action, context)
	return { value = (action.key == "discard" and 20 or 10) + context.rollout }
end }
local comparison = Branch.compare(snapshot, actions, adapter, { rollouts = 3, seed = "BRANCH" })
assert(comparison.offline_only and comparison.best.action.key == "discard", "wrong snapshot branch winner")
assert(comparison.results[1].simulated_regret == 10, "wrong simulated regret")
assert(comparison.results[2].simulated_regret == 0, "best action should have zero regret")
print("snapshot_branch_spec: ok")
