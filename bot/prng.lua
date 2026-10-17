local PRNG = {}
PRNG.__index = PRNG

local MODULUS = 2147483647
local MULTIPLIER = 48271

local function hash(value)
	local state = 216613626
	value = tostring(value or "")
	for i = 1, #value do
		state = (state * 131 + value:byte(i) + i) % MODULUS
	end
	-- Similar stream labels commonly differ only near their suffix (shop round,
	-- pack index, etc.). Extra Park-Miller rounds avalanche those late changes
	-- before the value becomes a stream seed, avoiding correlated first draws.
	for round = 1, 4 do
		state = (state * MULTIPLIER + round * 104729) % MODULUS
	end
	return math.max(1, state)
end

function PRNG.new(seed)
	return setmetatable({ state = hash(seed), seed = tostring(seed or "") }, PRNG)
end

function PRNG:next()
	self.state = (self.state * MULTIPLIER) % MODULUS
	return self.state / MODULUS
end

function PRNG:integer(low, high)
	if high < low then low, high = high, low end
	return low + math.floor(self:next() * (high - low + 1))
end

function PRNG:fork(label)
	return PRNG.new(self.seed .. ":" .. tostring(label))
end

function PRNG.hash(value)
	return hash(value)
end

return PRNG
