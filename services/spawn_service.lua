--[[
spawn_service.lua

Спавн новых букв с локальным vowel-control (BR-G01) и сложностной
фильтрацией (BR-G02). Использует letter_bag (BR-F04).

API:
  spawn_service.draw_for_cell(state, x, y) -> letter, meta
    -- Подбирает букву под клетку (x, y) с учётом локального баланса.
    meta:
      category     -- "vowels" | "consonants" | "any"
      local_vowel_ratio
      dictionary_vowel_ratio
      delta

  spawn_service.fill_empty_cells(state) -- BR-D04 §104
    -- Заполняет state.grid[x][y] == nil новыми клетками, собирает список новых клеток.
    -- Возвращает: { {x=x, y=y, letter=L}, ... }

Зависимости:
  state.dictionary
  state.bag         (letter_bag)
  state.board.cfg   (config snapshot)
]]--

local cell_factory = require("services.cell_factory")
local letter_bag = require("services.letter_bag")
local event_logger = require("services.event_logger")

local spawn_service = {}

-- ── BR-G01: локальная область вокруг колонки x ─────

local function compute_local_vowel_ratio(state, x)
	local board = state.board
	local vowel_set = state.dictionary.vowel_set
	local cf_is_ordinary = cell_factory.is_ordinary

	local cols = {x - 1, x, x + 1}
	local vowels = 0
	local ordinary = 0

	for ci = 1, #cols do
		local cx = cols[ci]
		if cx >= 1 and cx <= board.num_cols then
			for cy = 1, board.pattern[cx] do
				local cell = state.grid[cx][cy]
				if cf_is_ordinary(cell) then
					ordinary = ordinary + 1
					if vowel_set[cell.char] then
						vowels = vowels + 1
					end
				end
			end
		end
	end

	if ordinary == 0 then return nil, vowels, ordinary end
	return vowels / ordinary, vowels, ordinary
end

local function build_subset(allowed_set, vowel_set, want_vowels, dictionary, target_letters_set)
	local out = {}
	for L in pairs(allowed_set) do
		local is_v = vowel_set[L] == true
		if want_vowels == nil then
			out[L] = true
		elseif want_vowels and is_v then
			out[L] = true
		elseif (not want_vowels) and (not is_v) then
			out[L] = true
		end
	end
	-- BR-G01 §70: цели не исключаются.
	if target_letters_set then
		for L in pairs(target_letters_set) do out[L] = true end
	end
	-- BR-G01 §69: если категория пуста — расширяем за счёт следующих по частоте.
	if next(out) == nil then
		-- fallback: топ-N по spawn_weights в нужной категории.
		local alphabet = dictionary.alphabet
		local candidates = {}
		for i = 1, #alphabet do
			local L = alphabet[i]
			if want_vowels == nil
			   or (want_vowels and vowel_set[L])
			   or ((not want_vowels) and not vowel_set[L]) then
				candidates[#candidates + 1] = {L = L, w = dictionary.spawn_weights[L] or 0}
			end
		end
		table.sort(candidates, function(a, b) return a.w > b.w end)
		for i = 1, math.min(3, #candidates) do out[candidates[i].L] = true end
	end
	return out
end

-- BR-G01: основная функция.
function spawn_service.draw_for_cell(state, x, y)
	local dictionary = state.dictionary
	local board = state.board
	local cfg = board.cfg

	local local_ratio, lv, lo = compute_local_vowel_ratio(state, x)
	local dict_ratio = dictionary.vowel_ratio or 0.4
	local delta = cfg.vowel_control_delta or 0.05

	local want_vowels = nil -- nil = любая категория
	local category = "any"
	if local_ratio ~= nil then
		if local_ratio < dict_ratio - delta then
			want_vowels = true
			category = "vowels"
		elseif local_ratio > dict_ratio + delta then
			want_vowels = false
			category = "consonants"
		end
	end

	local subset
	if want_vowels ~= nil then
		subset = build_subset(
			state.bag.allowed_set, dictionary.vowel_set, want_vowels,
			dictionary, state.target_letters_set
		)
	end

	local letter = letter_bag.draw(state.bag, subset)
	if not letter then
		print("DEBUG: draw_for_cell: letter_bag.draw returned nil, x=" .. x .. " y=" .. y)
		letter = dictionary.alphabet[1]
		if not letter then
			print("DEBUG: draw_for_cell: alphabet[1] is also nil!")
		end
	end

	event_logger.log("letter_spawn", {
		x = x, y = y,
		letter = letter,
		category = category,
		local_vowel_ratio = local_ratio,
		dictionary_vowel_ratio = dict_ratio,
		delta = delta,
		freq = (dictionary.spawn_weights or {})[letter],
		rare_threshold = state.bag.rare_threshold
	})

	return letter, {
		category = category,
		local_vowel_ratio = local_ratio,
		dictionary_vowel_ratio = dict_ratio,
		delta = delta
	}
end

-- BR-D04 §104: заполнить пустые клетки сетки.
-- Возвращает список новых клеток (для delta-zone).
function spawn_service.fill_empty_cells(state)
	local new_cells = {}
	for x = 1, state.board.num_cols do
		for y = 1, state.board.pattern[x] do
			if state.grid[x][y] == nil then
				local letter = spawn_service.draw_for_cell(state, x, y)
				state.grid[x][y] = cell_factory.create_letter_cell(letter, {origin = "spawn"})
				new_cells[#new_cells + 1] = {x = x, y = y, letter = letter}
			end
		end
	end
	return new_cells
end

return spawn_service
