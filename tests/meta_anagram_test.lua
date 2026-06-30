local meta_anagram = require("services.meta_anagram")

local tests_run = 0
local tests_passed = 0
local tests_failed = {}

local function assert(cond, msg)
	if not cond then
		error(tostring(msg), 2)
	end
end

local function assert_not(cond, msg)
	if cond then
		error(tostring(msg), 2)
	end
end

local function test(name, fn)
	tests_run = tests_run + 1
	local ok, err = pcall(fn)
	if ok then
		tests_passed = tests_passed + 1
		io.write("  ✓ " .. name .. "\n")
	else
		table.insert(tests_failed, {name = name, err = err})
		io.write("  ✗ " .. name .. ": " .. tostring(err) .. "\n")
	end
end

-- Mock dictionary: uppercase Russian nouns.
-- Includes normalize_yo: words with Ё stored as Е.
local MOCK_DICT = {
	["КОРОВА"]=true, ["МОЛОКО"]=true, ["МАМА"]=true,
	["ПАПА"]=true, ["ДОМ"]=true, ["ЛЕС"]=true,
	["СОБАКА"]=true, ["КОШКА"]=true, ["РЫБА"]=true,
	["КНИГА"]=true, ["РУЧКА"]=true, ["СТОЛ"]=true,
	["СТУЛ"]=true, ["ОКНО"]=true, ["ДВЕРЬ"]=true,
	["ЗЕРКАЛО"]=true,
	["ЕЛКА"]=true,
	["КАША"]=true, ["МАШИНА"]=true,
}

local MOCK_DICT_PAYLOAD = { valid_words = MOCK_DICT }

local function is_anagram(a, b)
	if utf8.len(a) ~= utf8.len(b) then return false end
	local count = {}
	for _, cp in utf8.codes(a) do
		local c = utf8.char(cp)
		count[c] = (count[c] or 0) + 1
	end
	for _, cp in utf8.codes(b) do
		local c = utf8.char(cp)
		count[c] = (count[c] or 0) - 1
		if count[c] < 0 then return false end
	end
	return true
end

io.write("=== meta_anagram tests ===\n\n")

-- ── Basics ────────────────────────────────────────

test("returns a string for a 4-letter word", function()
	local result = meta_anagram.anagram_build("ДОМ", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil result")
	assert(type(result) == "string", "expected string, got " .. type(result))
end)

test("returns a different permutation (not the original)", function()
	local result = meta_anagram.anagram_build("ДОМ", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil result")
	assert(result ~= "ДОМ", "anagram must differ from original: " .. result)
end)

test("result is an anagram of the input", function()
	local result = meta_anagram.anagram_build("КОРОВА", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil result")
	assert(is_anagram("КОРОВА", result), result .. " is not an anagram of КОРОВА")
end)

test("result is not a real dictionary word", function()
	local result = meta_anagram.anagram_build("СТУЛ", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil result")
	assert(not MOCK_DICT[result], "anagram should not be a real word: " .. result)
end)

-- ── Difficulty levels ──────────────────────────────

test("easy difficulty returns a result", function()
	local result = meta_anagram.anagram_build("РЫБА", MOCK_DICT, "easy")
	assert(result ~= nil, "expected non-nil result for easy")
end)

test("hard difficulty returns a result", function()
	local result = meta_anagram.anagram_build("РЫБА", MOCK_DICT, "hard")
	assert(result ~= nil, "expected non-nil result for hard")
end)

-- ── Word length limits ────────────────────────────

test("returns nil for 2-letter word", function()
	local result = meta_anagram.anagram_build("АХ", MOCK_DICT, "normal")
	assert(result == nil, "expected nil for 2-letter word, got " .. tostring(result))
end)

test("returns nil for 7-letter word", function()
	local result = meta_anagram.anagram_build("ЗЕРКАЛО", MOCK_DICT, "normal")
	assert(result == nil, "expected nil for 7-letter word, got " .. tostring(result))
end)

test("works for 3-letter word", function()
	local result = meta_anagram.anagram_build("ДОМ", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil for 3-letter word")
	assert(utf8.len(result) == 3, "expected 3 chars, got " .. tostring(utf8.len(result)))
end)

test("works for 6-letter word", function()
	local result = meta_anagram.anagram_build("СОБАКА", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil for 6-letter word")
	assert(utf8.len(result) == 6, "expected 6 chars, got " .. tostring(utf8.len(result)))
end)

-- ── Repeated letters ──────────────────────────────

test("works with repeated letters (МАМА)", function()
	local result = meta_anagram.anagram_build("МАМА", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil for МАМА")
	assert(is_anagram("МАМА", result), result .. " is not an anagram of МАМА")
	assert(result ~= "МАМА", "anagram must differ from original")
end)

test("works with repeated letters (ПАПА)", function()
	local result = meta_anagram.anagram_build("ПАПА", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil for ПАПА")
	assert(is_anagram("ПАПА", result), result .. " is not an anagram of ПАПА")
end)

-- ── Ё normalization ──────────────────────────────

test("Ё normalization: word with Ё", function()
	-- ЕЛКА is in dictionary, but ЁЛКА is not — building from ЁЛКА should work
	-- and the result should not be ЕЛКА (real word)
	local result = meta_anagram.anagram_build("ЁЛКА", MOCK_DICT, "normal")
	-- May fail if all permutations are real words; that's fine
	if result then
		assert(is_anagram("ЁЛКА", result), result .. " is not an anagram of ЁЛКА")
		-- Should never produce ЕЛКА since it's a real word
		assert(result ~= "ЕЛКА", "anagram must not be ЕЛКА (real word from dict)")
		assert(result ~= "ЁЛКА", "anagram must differ from original")
	end
end)

-- ── dictionary_service payload format ────────────

test("accepts dictionary_service payload with valid_words", function()
	local result = meta_anagram.anagram_build("ДОМ", MOCK_DICT_PAYLOAD, "normal")
	assert(result ~= nil, "expected non-nil result")
	assert(is_anagram("ДОМ", result), result .. " is not an anagram of ДОМ")
end)

-- ── Input case handling ──────────────────────────

test("handles lowercase input", function()
	local result = meta_anagram.anagram_build("корова", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil result")
	assert(is_anagram("КОРОВА", result), result .. " is not an anagram of КОРОВА")
end)

test("handles mixed case input", function()
	local result = meta_anagram.anagram_build("РыБа", MOCK_DICT, "normal")
	assert(result ~= nil, "expected non-nil result for РыБа")
	assert(is_anagram("РЫБА", result), result .. " is not an anagram of РЫБА")
end)

-- ── is_readable constraint ────────────────────────

test("result is readable (no garbage output)", function()
	for _, word in ipairs({"ДОМ", "ЛЕС", "РЫБА", "КНИГА", "МОЛОКО"}) do
		local result = meta_anagram.anagram_build(word, MOCK_DICT, "normal")
		if result then
			local first
			for _, cp in utf8.codes(result) do
				first = utf8.char(cp)
				break
			end
			assert(first ~= "Ь", word .. " -> " .. result .. " starts with Ь")
			assert(first ~= "Ъ", word .. " -> " .. result .. " starts with Ъ")
			assert(first ~= "Ы", word .. " -> " .. result .. " starts with Ы")
		end
	end
end)

-- ── Fallback ──────────────────────────────────────

test("fallback returns best candidate when no band match", function()
	local result = meta_anagram._fallback("КОРОВА", {"К","О","Р","О","В","А"}, MOCK_DICT)
	assert(result ~= nil, "expected fallback to find something")
	assert(is_anagram("КОРОВА", result), result .. " is not an anagram of КОРОВА")
	assert(result ~= "КОРОВА", "fallback must differ from original")
end)

-- ── Edge cases ────────────────────────────────────

test("unknown difficulty raises error", function()
	local ok, err = pcall(meta_anagram.anagram_build, "ДОМ", MOCK_DICT, "impossible")
	assert(not ok, "expected error for unknown difficulty")
	assert(err:find("Unknown difficulty"), "error should mention Unknown difficulty")
end)

test("works with empty dictionary (no word filter)", function()
	local result = meta_anagram.anagram_build("ДОМ", {}, "normal")
	assert(result ~= nil, "expected non-nil with empty dictionary")
	assert(utf8.len(result) == 3, "expected 3 chars in result")
	assert(is_anagram("ДОМ", result), "result must be an anagram of ДОМ")
	assert(result ~= "ДОМ", "result must differ from original")
end)

test("deterministic with seeded RNG", function()
	math.randomseed(42)
	local r1 = meta_anagram.anagram_build("СОБАКА", MOCK_DICT, "normal")
	math.randomseed(42)
	local r2 = meta_anagram.anagram_build("СОБАКА", MOCK_DICT, "normal")
	assert(r1 == r2, "same seed should produce same result: " .. tostring(r1) .. " vs " .. tostring(r2))
end)

-- ── Summary ────────────────────────────────────────

io.write("\n=== Results ===\n")
io.write("Passed: " .. tests_passed .. "/" .. tests_run .. "\n")
if #tests_failed > 0 then
	io.write("Failed:\n")
	for _, f in ipairs(tests_failed) do
		io.write("  " .. f.name .. ": " .. tostring(f.err) .. "\n")
	end
	os.exit(1)
else
	io.write("All tests passed!\n")
end