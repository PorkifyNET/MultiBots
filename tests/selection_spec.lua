local Evolution = dofile("training/evolution.lua")

local function evaluation(fitness) return { fitness = fitness, metrics = {} } end
local baseline = {
	weights = { marker = 0 }, training = evaluation(6000), validation = evaluation(6026.246),
}
local generation9 = {
	id = "09-07", weights = { marker = 9 },
	training = evaluation(8094.162), validation = evaluation(6645.790),
}
local generation10 = {
	id = "10-06", weights = { marker = 10 },
	training = evaluation(8096.435), validation = evaluation(6164.542),
}
local weak_overfit = {
	id = "08-99", weights = { marker = 99 },
	training = evaluation(6100), validation = evaluation(7000),
}
local result = Evolution.select_candidates({ generation9, generation10, weak_overfit }, baseline, {
	mode = "max_validation_with_training_floor",
	minimum_training_fraction_of_best = 0.98,
	minimum_training_improvement = 0,
	maximum_validation_regression = 0,
})
assert(result.best_training.id == "10-06", "best training candidate was not tracked separately")
assert(result.best_validation.id == "08-99", "best raw validation candidate was not tracked separately")
assert(result.selected.id == "09-07", "generalization-aware selection should choose generation 9")
assert(result.training_objective_floor > weak_overfit.training.fitness - baseline.training.fitness,
	"paired training objective floor did not reject weak candidate")
print("selection_spec: ok")
