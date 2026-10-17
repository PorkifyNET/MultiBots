local PRNG = dofile("bot/prng.lua")

local labels = {
	"pack_contents:1:1:p_celestial_normal_3",
	"pack_contents:1:2:p_celestial_normal_3",
	"pack_contents:2:4:p_celestial_normal_3",
	"pack_contents:3:6:p_celestial_normal_4",
	"pack_contents:3:8:p_celestial_jumbo_1",
	"pack_contents:4:11:p_celestial_normal_3",
	"pack_contents:4:11:p_celestial_normal_4",
}

local appearances = {}
for _, label in ipairs(labels) do
	local stream = PRNG.new("*HUYEGHC1"):fork(label)
	local available = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
	local choices = label:find("jumbo", 1, true) and 5 or 3
	for _ = 1, choices do
		local index = stream:integer(1, #available)
		local value = table.remove(available, index)
		appearances[value] = (appearances[value] or 0) + 1
	end
end

for value, count in pairs(appearances) do
	assert(count < #labels,
		"similar pack stream labels must not force candidate " .. value .. " into every pack")
end

local a = PRNG.new("same-seed")
local b = PRNG.new("same-seed")
for _ = 1, 10 do assert(a:next() == b:next(), "stronger seed mixing must remain deterministic") end

print("prng_spec: ok")
