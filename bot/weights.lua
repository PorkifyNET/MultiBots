local Weights = {}

-- These are preference multipliers, not game rules. A value of 1 preserves the
-- pre-training behavior exactly; trainers mutate only this table.
Weights.defaults = {
	immediate_score = 1.0,
	future_value = 1.0,
	discard_potential = 1.0,
	card_preservation = 1.0,
	survival_pressure = 1.0,
	plan_alignment = 1.0,
	joker_value = 1.0,
	joker_synergy = 1.0,
	economy_value = 1.0,
	interest_preservation = 1.0,
	pack_value = 1.0,
	deck_manipulation = 1.0,
	consumable_value = 1.0,
	risk_tolerance = 1.0,
}

Weights.minimum = 0.25
Weights.maximum = 2.5

function Weights.keys()
	local keys = {}
	for key in pairs(Weights.defaults) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

function Weights.copy(source)
	local result = {}
	for key, default in pairs(Weights.defaults) do
		local value = source and tonumber(source[key]) or nil
		result[key] = value or default
	end
	return result
end

function Weights.validate(source)
	local result, errors = Weights.copy(source), {}
	for key in pairs(source or {}) do
		if Weights.defaults[key] == nil then errors[#errors + 1] = tostring(key) .. " is not a trainable weight" end
	end
	for _, key in ipairs(Weights.keys()) do
		local value = tonumber(source and source[key])
		if source and source[key] ~= nil and not value then
			errors[#errors + 1] = key .. " must be numeric"
		elseif value and (value < Weights.minimum or value > Weights.maximum) then
			errors[#errors + 1] = string.format("%s must be between %.2f and %.2f", key, Weights.minimum, Weights.maximum)
		end
	end
	return #errors == 0 and result or nil, errors
end

function Weights.get(state_or_weights, key)
	local values = state_or_weights and (state_or_weights.weights or state_or_weights) or nil
	return tonumber(values and values[key]) or Weights.defaults[key] or 1
end

function Weights.is_default(source)
	for key, default in pairs(Weights.defaults) do
		if math.abs((tonumber(source and source[key]) or default) - default) > 1e-12 then return false end
	end
	return true
end

return Weights
