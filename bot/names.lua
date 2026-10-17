local Names = {}

Names.first_words = {
	"Abandoned ", "Abstract ", "Arcana ", "Artificial ", "Amber ", "Arcane ", "Astral ", "Black ", "Bold ", "Blue ", "Buffoon ", "Business ", "Celestial ", "Ceremonial ", "Cerulean ", "Chaotic ", "Checkered ", "Clever ", "Conjoined ", "Cosmic ", "Crafty ", "Crazy ", "Crimson ", "Crystal ", "Dapper ", "Dave ", "Dead ", "Defensive ", "Deja ", "Devious ", "Doctor ", "Droll ", "Ecto", "Electric ", "Emerald ", "Erratic ", "Even ", "Evil ", "Fabled ", "Faceless ", "Fishy ", "Fizzy ", "Fortune ", "Froggy ", "General ", "Ghost ", "Gluttonous ", "Gold ", "Golden ", "Grand ", "Greedy ", "Green ", "Gros ", "Hanging ", "Hatsune ", "Hidden ", "High ", "John ", "Jolly ", "Local", "Lucky ", "Lunar ", "Lusty ", "Mad ", "Magic ", "Major ", "Marble ", "Mellow ", "Minor ", "Ms. ", "Mr. ", "Mystic ", "Nebula", "Neon ", "Neuro", "Nimble ", "Odd ", "Ono ", "Orange ", "Ouija ", "Painted ", "Photo", "Pink ", "Plasma ", "Polished ", "Porky ", "Purple ", "Red ", "Royal ", "Roffle", "Scarlet ", "Scary ", "Shy ", "Shrewd ", "Silver ", "Skill ", "Skilled ", "Sly ", "Smiley ", "Sneaky ", "Solar ", "Solid ", "Space ", "Standard ", "Strong ", "The ", "Trans ", "Velvet ", "Verdant ", "Violet ", "White ", "Wild ", "Wily ", "Witty ", "Wrathful ", "Yellow ", "Zany ", "Zealous ", 
}

Names.second_words = {
	"Ace", "Acorn", "Anaglyph", "Ankh", "Arm", "Aura", "Balatro", "Baron", "Bean", "Bell", "Blind", "Blueprint", "Board", "Bot", "Burglar", "Canio", "Card", "Cavendish", "Chad", "Chariot", "Chicot", "Chip", "Club", "Comet", "Constellation", "Cryptid", "Dagger", "Dave", "Death", "Deck", "Devil", "Diamond", "Drunkard", "Ectoplasm", "Egg", "Emperor", "Empress", "Eye", "Face", "Familiar", "Fish", "Flint", "Flush", "Fool", "Fortune", "Frog", "Gambit", "Gambler", "Ghost", "Goad", "Goat", "Graph", "Grim", "Head", "Heart", "Hermit", "Hex", "Hierophant", "Hiker", "Hole", "Hook", "House", "Immolate", "Incantation", "Intelligence", "Issue", "Jester", "Joker", "Judgement", "Juggler", "Justice", "King", "Leaf", "Lite", "Live", "Lovers", "Luchador", "Magician", "Man", "Manacle", "Mark", "Medium", "Michel", "Midas", "Miku", "Mime", "Mis", "Moon", "Mouth", "Nebula", "Needle", "Ninja", "Nose", "Obelisk", "Omen", "Orbit", "Ox", "Pair", "Perkeo", "Pig", "Pillar", "Pincher", "Pizza", "Planet", "Plant", "Plasma", "Poker", "Priestess", "Psychic", "Queen", "Rat", "Reroll", "Robot", "Rocket", "Runner", "Sama", "Seal", "Serpent", "Shuffle", "Sigil", "Sirens", "Soul", "Snake", "Spade", "Spectral", "Speedrunner", "Star", "Steven", "Straight", "Sultan", "Sun", "Talisman", "Tarot", "Taxes", "Temperance", "Thunk", "Todd", "Tooth", "Tower", "Trance", "Triboulet", "Trick", "Vessel", "Voucher", "Vu", "Wall", "Water", "Wheel", "Wildcard", "Window", "Wolf", "World", "Worm", "Wraith", "Yard", "Yorick", "Zebra", "Zodiac",
}

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function Names.sanitize(value)
	-- Multiplayer reserves '~N' as its blind-colour suffix. Control characters
	-- also make poor lobby names, so neither may enter a bot's visible identity.
	return trim(tostring(value or ""):gsub("[%c~]", ""))
end

function Names.classic(difficulty_name)
	return "MultiBot (" .. tostring(difficulty_name or "Normal") .. ")"
end

function Names.generate(random_index)
	random_index = random_index or function(maximum) return math.random(maximum) end
	local first = Names.first_words[random_index(#Names.first_words)] or Names.first_words[1]
	local second = Names.second_words[random_index(#Names.second_words)] or Names.second_words[1]
	return first .. second
end


function Names.resolve(options, difficulty_name)
	options = options or {}
	local mode = options.name_mode or "classic"
	if mode == "generated" then
		local generated = Names.sanitize(options.generated_name)
		return generated ~= "" and generated or Names.generate(options.random_index)
	elseif mode == "custom" then
		local custom = Names.sanitize(options.custom_name)
		return custom ~= "" and custom or Names.classic(difficulty_name)
	end
	return Names.classic(difficulty_name)
end

return Names
