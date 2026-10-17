local Json = {}

local function escape(value)
	return tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
		:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

local function is_array(value)
	local maximum, count = 0, 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
		maximum, count = math.max(maximum, key), count + 1
	end
	return maximum == count
end

local function encode(value, seen)
	local kind = type(value)
	if kind == "nil" then return "null" end
	if kind == "boolean" then return value and "true" or "false" end
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then return "null" end
		return string.format("%.12g", value)
	end
	if kind == "string" then return '"' .. escape(value) .. '"' end
	if kind ~= "table" then return '"' .. escape(tostring(value)) .. '"' end
	seen = seen or {}
	if seen[value] then error("cannot encode cyclic table") end
	seen[value] = true
	local out = {}
	if is_array(value) then
		for index = 1, #value do out[#out + 1] = encode(value[index], seen) end
		seen[value] = nil
		return "[" .. table.concat(out, ",") .. "]"
	end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do
		out[#out + 1] = encode(tostring(key), seen) .. ":" .. encode(value[key], seen)
	end
	seen[value] = nil
	return "{" .. table.concat(out, ",") .. "}"
end

function Json.encode(value) return encode(value) end

return Json
