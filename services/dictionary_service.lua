--[[
dictionary_service.lua

Подготовка словаря под BR-V01..V04.

Возвращает таблицу:
  {
    valid_words      = {[word]=true},          -- все валидные слова всех пулов (≥3 букв, флаг 1)
    prefixes         = {[prefix]=true},        -- для отсечения DFS
    word_frequencies = {[word]=freq},
    word_pool        = {[word]="A"|"B"|"C"},   -- BR-V01 §6
    word_length      = {[word]=len},
    pool_a_words     = {word, word, ...},      -- отсортированы по freq desc
    pool_b_words     = {...},
    pool_c_words     = {...},

    alphabet         = {"А","Б",...} или {"A","B",...},
    spawn_weights    = {[letter]=weight},       -- BR-V02
    vowel_set        = {[letter]=true},
    vowel_ratio      = number,                  -- BR-V04
    document_frequency = {[letter]=value},
    letter_frequency   = {[letter]=value},
    target_letters     = {[letter]=true}        -- зарезервированные цели (BR-V02 §15)
  }

Использование:
  local dictionary = dictionary_service.init({
    csv_path = "...",
    entries = {{word=...,freq=...,flag=...}, ...},
    alphabet = {...},                  -- опц.
    vowels = {"А","Е","Ё","И","О","У","Ы","Э","Ю","Я"},
    target_letters = {"А", "С"},
    pool_a_limit = 3000,
    pool_b_limit = 8000,
    letter_weight_df = 0.7,
    letter_weight_lf = 0.3,
    force_ascii_upper = true,
    language = "ru" -- для пер-языкового хранения весов
  })
]]--

local utils = require("shared.utils")

local dictionary_service = {}

local DEFAULT_ALPHABET = {
	"A","B","C","D","E","F","G","H","I","J","K","L","M",
	"N","O","P","Q","R","S","T","U","V","W","X","Y","Z"
}

local DEFAULT_VOWELS = {"A","E","I","O","U","Y"}

local RU_ALPHABET = {
	"А","Б","В","Г","Д","Е","Ё","Ж","З","И","Й",
	"К","Л","М","Н","О","П","Р","С","Т","У","Ф","Х","Ц","Ч","Ш","Щ","Ъ","Ы","Ь","Э","Ю","Я"
}
local RU_VOWELS = {"А","Е","Ё","И","О","У","Ы","Э","Ю","Я"}

dictionary_service.DEFAULT_ALPHABET = DEFAULT_ALPHABET
dictionary_service.DEFAULT_VOWELS = DEFAULT_VOWELS
dictionary_service.RU_ALPHABET = RU_ALPHABET
dictionary_service.RU_VOWELS = RU_VOWELS

-- ── Низкоуровневые помощники ──────────────────────

local function utf8_chars(s)
	-- Разрезает UTF-8 строку на массив графем (без NFC, простая byte-by-byte).
	if utils.utf8_chars then return utils.utf8_chars(s) end
	local out = {}
	local i = 1
	local len = #s
	while i <= len do
		local b = string.byte(s, i)
		local size
		if b < 0x80 then size = 1
		elseif b < 0xC0 then size = 1 -- битый, шагаем по байту
		elseif b < 0xE0 then size = 2
		elseif b < 0xF0 then size = 3
		else size = 4 end
		out[#out + 1] = string.sub(s, i, i + size - 1)
		i = i + size
	end
	return out
end

local function utf8_len(s)
	return #utf8_chars(s)
end

local function utf8_upper(s, force_ascii)
	if force_ascii then return string.upper(s) end
	-- Без полноценной локали — оставляем как есть для не-ASCII.
	return string.upper(s)
end

local function utf8_prefixes(chars, max_len, out)
	local acc = ""
	local limit = math.min(#chars, max_len or #chars)
	for j = 1, limit do
		acc = acc .. chars[j]
		out[acc] = true
	end
end

local function parse_csv_line(line)
	local fields = {}
	local i, n = 1, #line
	while i <= n do
		local comma = string.find(line, ",", i, true)
		if not comma then
			fields[#fields + 1] = string.sub(line, i)
			break
		end
		fields[#fields + 1] = string.sub(line, i, comma - 1)
		i = comma + 1
	end
	if #line >= 1 and string.sub(line, -1) == "," then
		fields[#fields + 1] = ""
	end
	return fields
end

local function load_csv(csv_path)
	local out = {}
	local data, err
	if sys and sys.load_resource then
		data, err = sys.load_resource(csv_path)
	else
		local f = io.open(csv_path, "rb")
		if not f then return out, "cannot open " .. tostring(csv_path) end
		data = f:read("*a")
		f:close()
	end
	if not data then return out, err or "no data" end

	local first = true
	local line_start = 1
	while line_start <= #data do
		local line_end = string.find(data, "\n", line_start, true) or (#data + 1)
		local line = string.sub(data, line_start, line_end - 1)
		line_start = line_end + 1
		if string.byte(line, -1) == 13 then line = string.sub(line, 1, -2) end
		if first then
			first = false
		elseif line ~= "" then
			local f = parse_csv_line(line)
			out[#out + 1] = {
				word = f[1],
				length = tonumber(f[2]),
				freq = tonumber(f[3]),
				flag = tonumber(f[4])
			}
		end
	end
	return out, nil
end

-- ── Основная функция ─────────────────────────────

function dictionary_service.init(options)
	options = options or {}

	local force_ascii = options.force_ascii_upper ~= false
	local alphabet = options.alphabet or utils.copy_array(DEFAULT_ALPHABET)
	local vowels_list = options.vowels or DEFAULT_VOWELS

	local vowel_set = {}
	for i = 1, #vowels_list do vowel_set[vowels_list[i]] = true end

	local target_letters_set = {}
	if options.target_letters then
		for i = 1, #options.target_letters do
			local t = tostring(options.target_letters[i])
			if force_ascii then t = string.upper(t) end
			target_letters_set[t] = true
		end
	end

	local pool_a_limit = options.pool_a_limit or 3000
	local pool_b_limit = options.pool_b_limit or 8000

	-- 1) Собрать сырые записи (BR-V01 §1-3).
	local raw = {}

	local function push(word, freq, flag)
		if not word or word == "" then return end
		if force_ascii then word = string.upper(word) end
		-- BR-V01 §2: исключить < 3 букв.
		if utf8_len(word) < 3 then return end
		-- BR-V01 §3: исключить flag != 1 если флаг присутствует.
		if flag ~= nil and flag ~= 1 then return end
		raw[#raw + 1] = {word = word, freq = tonumber(freq) or 0}
	end

	if options.entries then
		for i = 1, #options.entries do
			local e = options.entries[i]
			push(e.word, e.freq, e.flag)
		end
	end

	if options.csv_path then
		local rows, err = load_csv(options.csv_path)
		if err then
			-- Логируем в event_logger если доступен, иначе тихо.
			local ok, logger = pcall(require, "services.event_logger")
			if ok then logger.log("dictionary_load_error", {path = options.csv_path, err = err}) end
		end
		for i = 1, #rows do
			local r = rows[i]
			push(r.word, r.freq, r.flag)
		end
	end

	-- 2) Дедуп: при коллизии оставляем большую freq.
	local best = {}
	for i = 1, #raw do
		local r = raw[i]
		if not best[r.word] or best[r.word] < r.freq then
			best[r.word] = r.freq
		end
	end

	-- 3) Сортировка (BR-V01 §4) и разделение на пулы (BR-V01 §5).
	local sorted = {}
	for w, f in pairs(best) do sorted[#sorted + 1] = {word = w, freq = f} end
	table.sort(sorted, function(a, b)
		if a.freq ~= b.freq then return a.freq > b.freq end
		return a.word < b.word
	end)

	local payload = {
		valid_words = {},
		prefixes = {},
		word_frequencies = {},
		word_pool = {},
		word_length = {},
		pool_a_words = {},
		pool_b_words = {},
		pool_c_words = {},
		alphabet = alphabet,
		vowel_set = vowel_set,
		target_letters = target_letters_set,
		language = options.language
	}

	for i = 1, #sorted do
		local rec = sorted[i]
		local word = rec.word
		local freq = rec.freq
		local chars = utf8_chars(word)
		local wlen = #chars

		payload.valid_words[word] = true
		payload.word_frequencies[word] = freq
		payload.word_length[word] = wlen
		utf8_prefixes(chars, wlen, payload.prefixes)

		local pool
		if i <= pool_a_limit then pool = "A"
		elseif i <= pool_b_limit then pool = "B"
		else pool = "C" end
		payload.word_pool[word] = pool

		if pool == "A" then payload.pool_a_words[#payload.pool_a_words + 1] = word
		elseif pool == "B" then payload.pool_b_words[#payload.pool_b_words + 1] = word
		else payload.pool_c_words[#payload.pool_c_words + 1] = word end
	end

	-- 4) BR-V02: корпус для частот букв.
	local lf_min = options.letter_freq_corpus_min_len or 3
	local lf_max = options.letter_freq_corpus_max_len or 5
	local df_count = {}        -- documents per letter
	local letter_count = {}    -- occurrences per letter
	local total_letter_chars = 0
	local total_documents = 0

	for i = 1, #sorted do
		local word = sorted[i].word
		local wlen = payload.word_length[word]
		if wlen >= lf_min and wlen <= lf_max
		   and (payload.word_pool[word] == "A" or payload.word_pool[word] == "B") then
			total_documents = total_documents + 1
			local chars = utf8_chars(word)
			local seen_in_doc = {}
			for j = 1, #chars do
				local c = chars[j]
				letter_count[c] = (letter_count[c] or 0) + 1
				total_letter_chars = total_letter_chars + 1
				if not seen_in_doc[c] then
					seen_in_doc[c] = true
					df_count[c] = (df_count[c] or 0) + 1
				end
			end
		end
	end

	local document_frequency = {}
	local letter_frequency = {}
	for i = 1, #alphabet do
		local L = alphabet[i]
		document_frequency[L] = total_documents > 0 and (df_count[L] or 0) / total_documents or 0
		letter_frequency[L] = total_letter_chars > 0 and (letter_count[L] or 0) / total_letter_chars or 0
	end

	-- BR-V02 §13: spawn_weight = 0.7·df + 0.3·lf.
	local wdf = options.letter_weight_df or 0.7
	local wlf = options.letter_weight_lf or 0.3
	local spawn_weights = {}
	for i = 1, #alphabet do
		local L = alphabet[i]
		spawn_weights[L] = wdf * document_frequency[L] + wlf * letter_frequency[L]
	end
	-- BR-V02 §15: цели всегда сохраняются в допустимом множестве, даже если ниже порога.
	-- (Здесь только хранение; фильтрация — в letter_bag/cell_factory.)

	payload.document_frequency = document_frequency
	payload.letter_frequency = letter_frequency
	payload.spawn_weights = spawn_weights

	-- 5) BR-V04: vowel_ratio.
	local vr_min = options.vowel_ratio_corpus_min_len or 3
	local vr_max = options.vowel_ratio_corpus_max_len or 6
	local vowels_in_corpus = 0
	local letters_in_corpus = 0
	for i = 1, #sorted do
		local word = sorted[i].word
		local wlen = payload.word_length[word]
		if wlen >= vr_min and wlen <= vr_max then
			local chars = utf8_chars(word)
			for j = 1, #chars do
				letters_in_corpus = letters_in_corpus + 1
				if vowel_set[chars[j]] then
					vowels_in_corpus = vowels_in_corpus + 1
				end
			end
		end
	end
	payload.vowel_ratio = letters_in_corpus > 0 and vowels_in_corpus / letters_in_corpus or 0.4

	-- 6) Удобные индексы по длине (для anchor-first и repair).
	payload.words_by_length = {}
	for i = 1, #sorted do
		local word = sorted[i].word
		local wlen = payload.word_length[word]
		payload.words_by_length[wlen] = payload.words_by_length[wlen] or {}
		table.insert(payload.words_by_length[wlen], word)
	end

	payload.utf8_chars = utf8_chars
	payload.utf8_len = utf8_len

	return payload
end

-- ── BR-V03: порог редких букв по сложности ────────

-- Возвращает множество букв, разрешённых при данной сложности,
-- с обязательным включением target_letters_set.
function dictionary_service.allowed_letters(dictionary, difficulty, cfg, target_letters_set)
	cfg = cfg or {}
	local low = cfg.rare_letter_low_diff_cap or 0.35
	local high = cfg.rare_letter_high_diff_cap or 0.55
	local max_thresh = cfg.rare_letter_max_threshold or 0.05

	local threshold
	if difficulty <= low then
		threshold = max_thresh
	elseif difficulty >= high then
		threshold = 0.0
	else
		threshold = max_thresh * (high - difficulty) / (high - low)
	end

	local allowed = {}
	local alphabet = dictionary.alphabet
	local weights = dictionary.spawn_weights
	for i = 1, #alphabet do
		local L = alphabet[i]
		if (weights[L] or 0) >= threshold then
			allowed[L] = true
		end
	end
	-- BR-V02 §15 / BR-V03 §19: вернуть target letters.
	if target_letters_set then
		for L in pairs(target_letters_set) do allowed[L] = true end
	end
	for L in pairs(dictionary.target_letters or {}) do allowed[L] = true end

	return allowed, threshold
end

return dictionary_service
