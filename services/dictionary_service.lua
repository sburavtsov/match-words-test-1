--[[
dictionary_service.lua

Handles:
- Loading and parsing word entries from CSV or raw data
- Building prefix sets for DFS pruning
- Providing alphabet and word frequency tables
- No game state, pure data preparation

Usage:
local dictionary = dictionary_service.init({
	entries = {{word = "CAT", freq = 100}, ...},
	force_ascii_upper = true
})

local dictionary = dictionary_service.init({
	csv_path = "custom_resources/words/WordList_RU.csv"
})
]]--

local utils = require("shared.utils")

local dictionary_service = {}

-- ──────────────────────────────────────────────────
-- Default English alphabet and weights
-- ──────────────────────────────────────────────────

local DEFAULT_ALPHABET = {
	"A","B","C","D","E","F","G","H","I","J","K","L","M",
	"N","O","P","Q","R","S","T","U","V","W","X","Y","Z"
}

RU_ALPHABET = {
	"А","Б","В","Г","Д","Е","Ж","З","И","Й",
	"К","Л","М","Н","О","П","Р","С","Т","У","Ф","Х","Ц","Ч","Ш","Щ","Ъ","Ы","Ь","Э","Ю","Я"}

DEFAULT_BG_WEIGHTS = {
	vowels = {
		letters = {"E","A","O","I","U","Y"},
		weights = {40, 30, 25, 20, 8, 3}
	},
	consonants = {
		letters = {"S","T","R","N","L","D","C","M","P","H","G","B","F","W","K","V","J","X","Z","Q"},
		weights = {30, 30, 25, 25, 20, 15, 15, 12, 12, 10, 8, 6, 5, 5, 3, 1, 1, 1, 1, 1}
	}
}

local RU_BG_WEIGHTS = {
	vowels = {
		letters = {"О","Е","А","И","У","Я","Ы","Ю","Э","Ё"},
		weights = {40, 30, 25, 20, 8, 5, 5, 3, 2, 1}
	},
	consonants = {
		letters = {"Н","Т","Р","С","Л","В","К","П","М","Д","Б","Г","З","Ч","Й","Х","Ж","Ш","Ц","Щ","Ф","Ь"},
		weights = {30, 30,  25, 25, 20, 15, 15, 12, 12, 10, 8,  6,  6,  5,  5,  3,  2,  2,  1,  1,  1,  1}
	}
}

-- ──────────────────────────────────────────────────
-- Public API
-- ──────────────────────────────────────────────────

function dictionary_service.init(options)
	options = options or {}

	local payload = {
		valid_words = {},
		prefixes = {},
		word_frequencies = {},
		alphabet = options.alphabet or utils.copy_array(DEFAULT_ALPHABET),
		bg_weights = options.bg_weights or {
			vowels = {
				letters = utils.copy_array(DEFAULT_BG_WEIGHTS.vowels.letters),
				weights = utils.copy_array(DEFAULT_BG_WEIGHTS.vowels.weights)
			},
			consonants = {
				letters = utils.copy_array(DEFAULT_BG_WEIGHTS.consonants.letters),
				weights = utils.copy_array(DEFAULT_BG_WEIGHTS.consonants.weights)
			}
		}
	}

	local function add_word(pl, word, freq, filter_q)
		word = tostring(word)

		if options.force_ascii_upper ~= false then
			word = string.upper(word)
		end

		local word_len = utils.utf8_len(word)

		if word_len >= 3 then

			if filter_q then
				local has_q = word:find("Q", 1, true) ~= nil
				local has_qu = word:find("QU", 1, true) ~= nil

				if has_q and not has_qu then
					return
				end
			end

			pl.valid_words[word] = true
			pl.word_frequencies[word] = tonumber(freq) or 1.0

			for j = 1, word_len do
				local prefix = utils.utf8_sub(word, 1, j)
				pl.prefixes[prefix] = true
			end

		end
	end

	local function parse_csv_line(line)
		local fields = {}
		local field_start = 1
		local field_idx = 0

		while field_start <= #line do
			local comma_pos = line:find(",", field_start, true)

			if not comma_pos then
				comma_pos = #line + 1
			end

			field_idx = field_idx + 1
			fields[field_idx] = line:sub(field_start, comma_pos - 1)
			field_start = comma_pos + 1
		end

		return fields
	end

	local entries = options.entries or {}

	for i = 1, #entries do
		local entry = entries[i]
		local word = tostring(entry.word or "")

		add_word(payload, word, entry.freq, true)
	end

	if options.csv_path then
		local csv_data, err = sys.load_resource(options.csv_path)

		if csv_data then
			local line_start = 1
			local line_num = 0

			while line_start <= #csv_data do
				local line_end = csv_data:find("\n", line_start, true)

				if not line_end then
					line_end = #csv_data + 1
				end

				local line = csv_data:sub(line_start, line_end - 1)
				line_start = line_end + 1
				line_num = line_num + 1

				if line_num > 1 then
					local last_byte = line:byte(-1)

					if last_byte == 13 then
						line = line:sub(1, -2)
					end

					if line ~= "" then
						local fields = parse_csv_line(line)
						local word = fields[1]
						local leng = tonumber(fields[2])
						local freq = tonumber(fields[3])
						local flag = tonumber(fields[4])

						if word and flag == 1 and leng and leng >= 3 then
							add_word(payload, word, freq or 0, false)
						end

					end

				end

			end

		else
			print("[dictionary_service] Failed to load CSV: " .. tostring(err))

		end

	end

	return payload
end

return dictionary_service