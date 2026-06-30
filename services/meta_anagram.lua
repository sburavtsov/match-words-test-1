local meta_anagram = {}

local META_UPPER = {
	["а"]="А", ["б"]="Б", ["в"]="В", ["г"]="Г", ["д"]="Д", ["е"]="Е", ["ё"]="Ё",
	["ж"]="Ж", ["з"]="З", ["и"]="И", ["й"]="Й", ["к"]="К", ["л"]="Л", ["м"]="М",
	["н"]="Н", ["о"]="О", ["п"]="П", ["р"]="Р", ["с"]="С", ["т"]="Т", ["у"]="У",
	["ф"]="Ф", ["х"]="Х", ["ц"]="Ц", ["ч"]="Ч", ["ш"]="Ш", ["щ"]="Щ", ["ъ"]="Ъ",
	["ы"]="Ы", ["ь"]="Ь", ["э"]="Э", ["ю"]="Ю", ["я"]="Я",
}

local function cyrillic_upper(str)
	local out = {}
	for _, cp in utf8.codes(str) do
		local c = utf8.char(cp)
		out[#out + 1] = META_UPPER[c] or c
	end
	return table.concat(out)
end

local VOWELS = {
	["А"]=true, ["Е"]=true, ["Ё"]=true, ["И"]=true, ["Й"]=true,
	["О"]=true, ["У"]=true, ["Ы"]=true, ["Э"]=true, ["Ю"]=true, ["Я"]=true,
}

local HARD_BAD_FIRST = {
	["Ь"]=true, ["Ъ"]=true, ["Ы"]=true,
}

local DIFFICULTY_BANDS = {
	easy   = {min=7,  max=999},
	normal = {min=3,  max=12},
	hard   = {min=-2, max=6},
}

local function normalize_yo(str)
	return str:gsub("Ё", "Е")
end

local function is_readable(chars)
	local n = #chars

	local first = chars[1]
	if HARD_BAD_FIRST[first] or first == "Й" then
		return false
	end

	for i = 1, n do
		local c = chars[i]
		if c == "Ь" or c == "Ъ" then
			if i == n then
				if c == "Ъ" then
					return false
				end
			elseif i > 1 and VOWELS[chars[i-1]] then
				return false
			end
		end
	end

	local max_consecutive = n <= 4 and 2 or 3
	local run = 0
	for i = 1, n do
		if not VOWELS[chars[i]] then
			run = run + 1
			if run > max_consecutive then
				return false
			end
		else
			run = 0
		end
	end

	run = 0
	for i = 1, n do
		if VOWELS[chars[i]] then
			run = run + 1
			if run >= 3 then
				return false
			end
		else
			run = 0
		end
	end

	if n >= 2 and VOWELS[chars[1]] and VOWELS[chars[2]] then
		return false
	end

	return true
end

local function compute_score(chars, original_chars)
	local n = #chars
	local s = 0

	if chars[1] == original_chars[1] then
		s = s + 3
	end

	if chars[n] == original_chars[n] then
		s = s + 2
	end

	local orig_bigrams = {}
	for i = 1, n - 1 do
		orig_bigrams[original_chars[i] .. original_chars[i+1]] = true
	end
	for i = 1, n - 1 do
		if orig_bigrams[chars[i] .. chars[i+1]] then
			s = s + 1.5
		end
	end

	local hamming = 0
	for i = 1, n do
		if chars[i] ~= original_chars[i] then
			hamming = hamming + 1
		end
	end

	if hamming <= 1 then
		s = s - 10
	elseif hamming >= 2 and hamming <= 4 then
		s = s + 2
	elseif hamming == n then
		s = s - 2
	end

	local pattern_score = 0
	for i = 1, n do
		if VOWELS[chars[i]] == VOWELS[original_chars[i]] then
			pattern_score = pattern_score + 1
		end
	end
	s = s + (pattern_score / n) * 2

	return s
end

local function generate_permutations(chars, start, callback)
	if start >= #chars then
		local perm = {}
		for i = 1, #chars do
			perm[i] = chars[i]
		end
		return callback(perm)
	end

	local seen = {}
	for i = start, #chars do
		local c = chars[i]
		if not seen[c] then
			seen[c] = true
			chars[start], chars[i] = chars[i], chars[start]
			generate_permutations(chars, start + 1, callback)
			chars[start], chars[i] = chars[i], chars[start]
		end
	end
end

---@param word string Исходное слово (будет приведено к верхнему регистру)
---@param dictionary table Словарь: {[word]=true, ...} или payload dictionary_service (с полем valid_words)
---@param difficulty "easy"|"normal"|"hard"
---@return string|nil
function meta_anagram.anagram_build(word, dictionary, difficulty)
	difficulty = difficulty or "normal"
	local band = DIFFICULTY_BANDS[difficulty]
	if not band then
		error("Unknown difficulty: " .. tostring(difficulty))
	end

	word = cyrillic_upper(word)

	local original_chars = {}
	for _, cp in utf8.codes(word) do
		original_chars[#original_chars + 1] = utf8.char(cp)
	end

	local n = #original_chars
	if n < 3 or n > 6 then
		return nil
	end

	local lookup = dictionary
	if dictionary.valid_words then
		lookup = dictionary.valid_words
	end

	local candidates = {}

	local function process_permutation(perm)
		local candidate = table.concat(perm)

		if candidate == word then
			return
		end

		if lookup[candidate] or lookup[normalize_yo(candidate)] then
			return
		end

		if not is_readable(perm) then
			return
		end

		local score = compute_score(perm, original_chars)

		if score >= band.min and score <= band.max then
			candidates[#candidates + 1] = {score = score, str = candidate}
		end
	end

	generate_permutations(original_chars, 1, process_permutation)

	if #candidates == 0 then
		return meta_anagram._fallback(word, original_chars, lookup)
	end

	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	local top_n = math.min(5, #candidates)
	local pick = candidates[math.random(top_n)]
	return pick.str
end

function meta_anagram._fallback(word, original_chars, lookup)
	local candidates = {}

	local function process_permutation(perm)
		local candidate = table.concat(perm)

		if candidate == word then
			return
		end

		if lookup[candidate] or lookup[normalize_yo(candidate)] then
			return
		end

		if not is_readable(perm) then
			return
		end

		local score = compute_score(perm, original_chars)
		candidates[#candidates + 1] = {score = score, str = candidate}
	end

	generate_permutations(original_chars, 1, process_permutation)

	if #candidates == 0 then
		return nil
	end

	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	return candidates[1].str
end

return meta_anagram