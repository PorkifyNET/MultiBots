local PlayerTraces = {}

local function finite_number(value)
	local number = tonumber(value)
	if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
	return number
end

function PlayerTraces.parse(contents, source)
	local by_ante, last_ante = {}, 0
	for line in tostring(contents or ""):gmatch("[^\r\n]+") do
		if line:match("%sPVP%s") then
			local values = {}
			for key, value in line:gmatch("([%w_]+)=([^%s]+)") do values[key] = value end
			local ante, score = finite_number(values.ante), finite_number(values.player_score)
			if ante and ante >= 1 and ante % 1 == 0 and score and score >= 0 then
				by_ante[ante] = score
				last_ante = math.max(last_ante, ante)
			end
		end
	end
	if last_ante == 0 then
		return nil, tostring(source or "player log") .. " contains no valid PvP player scores"
	end
	local first_score
	for ante = 1, last_ante do
		if by_ante[ante] then first_score = by_ante[ante]; break end
	end
	local scores, previous = {}, first_score
	for ante = 1, last_ante do
		if by_ante[ante] then previous = by_ante[ante] end
		scores[ante] = previous
	end
	return scores
end

function PlayerTraces.load(path)
	local file, open_error = io.open(path, "rb")
	if not file then return nil, open_error end
	local contents = file:read("*a")
	file:close()
	return PlayerTraces.parse(contents, path)
end

return PlayerTraces
