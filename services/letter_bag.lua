--[[
letter_bag.lua

Частотный мешок букв (BR-F04).

Заранее подготовленный пул букв, из которого извлекаются клетки.
Заполняется случайно-взвешенным выбором по spawn_weight(letter) (BR-V02).
При исчерпании ниже минимума — пересоздаётся.

API:
  bag = letter_bag.create(dictionary, cell_count, difficulty, cfg, target_letters_set)
  letter = letter_bag.draw(bag, restrict_set?)   -- restrict_set ограничивает выбор подмножеством
  letter_bag.return_letter(bag, letter)          -- (необязательно) вернуть в мешок
  letter_bag.refresh(bag) -- пересоздать с теми же параметрами
  letter_bag.stats(bag)   -- {size, total_drawn, letter_counts}

Поля bag:
  letters         -- массив оставшихся букв
  letter_counts   -- {[letter]=count}
  dictionary, cell_count, difficulty, cfg, target_letters_set, allowed_set
  rare_threshold  -- зафиксированный для логов (BR-G02 §76)
]]--

local utils = require("shared.utils")
local dictionary_service = require("services.dictionary_service")

local letter_bag = {}

local function build_letters_pool(dictionary, allowed)
	local letters = {}
	local weights = {}
	for L, ok in pairs(allowed) do
		if ok then
			letters[#letters + 1] = L
			weights[#weights + 1] = dictionary.spawn_weights[L] or 0
		end
	end
	return letters, weights
end

local function build_bag_array(letters, weights, size)
	-- Случайно-взвешенный выбор N раз с пополнением.
	local out = {}
	local counts = {}
	-- Накопительные веса.
	local total = 0
	for i = 1, #weights do total = total + weights[i] end
	if total <= 0 then
		-- Дефолтный путь: равномерно.
		for i = 1, size do
			local L = letters[((i - 1) % #letters) + 1]
			out[i] = L
			counts[L] = (counts[L] or 0) + 1
		end
		return out, counts
	end
	for i = 1, size do
		local L = utils.weighted_choice(letters, weights)
		out[i] = L
		counts[L] = (counts[L] or 0) + 1
	end
	return out, counts
end

function letter_bag.create(dictionary, cell_count, difficulty, cfg, target_letters_set)
	cfg = cfg or {}
	local size = math.max(64, (cfg.bag_size_multiplier or 100) * (cell_count or 50))

	local allowed, threshold = dictionary_service.allowed_letters(
		dictionary, difficulty or 0, cfg, target_letters_set
	)

	local letters, weights = build_letters_pool(dictionary, allowed)
	if #letters == 0 then
		-- BR-G02 §74: вернуть самые частотные исключённые.
		local alphabet = dictionary.alphabet
		for i = 1, math.min(5, #alphabet) do
			letters[#letters + 1] = alphabet[i]
			weights[#weights + 1] = dictionary.spawn_weights[alphabet[i]] or 1
			allowed[alphabet[i]] = true
		end
	end

	local arr, counts = build_bag_array(letters, weights, size)

	return {
		letters = arr,
		letter_counts = counts,
		size = size,
		dictionary = dictionary,
		cell_count = cell_count,
		difficulty = difficulty,
		cfg = cfg,
		target_letters_set = target_letters_set,
		allowed_set = allowed,
		rare_threshold = threshold,
		total_drawn = 0
	}
end

-- Пересоздать мешок (BR-F04 §57, §58).
function letter_bag.refresh(bag)
	local fresh = letter_bag.create(
		bag.dictionary, bag.cell_count, bag.difficulty, bag.cfg, bag.target_letters_set
	)
	bag.letters = fresh.letters
	bag.letter_counts = fresh.letter_counts
	bag.allowed_set = fresh.allowed_set
	bag.rare_threshold = fresh.rare_threshold
	return bag
end

local function need_refill(bag)
	local min_fraction = bag.cfg.bag_refill_min_fraction or 0.1
	return #bag.letters <= math.floor(bag.size * min_fraction)
end

-- Извлечь букву из мешка.
-- restrict_set: опционально, выбираем только буквы из множества (для BR-G01 vowel-control).
function letter_bag.draw(bag, restrict_set)
	if need_refill(bag) then letter_bag.refresh(bag) end

	local arr = bag.letters
	if #arr == 0 then return nil end

	local idx
	if restrict_set then
		-- Линейный поиск подходящей буквы.
		local matches = {}
		for i = 1, #arr do
			if restrict_set[arr[i]] then matches[#matches + 1] = i end
		end
		if #matches == 0 then
			-- В мешке нет нужной категории — берём первый удачный по весу из restrict_set
			-- через словарные веса.
			local letters_list, weights_list = {}, {}
			for L in pairs(restrict_set) do
				letters_list[#letters_list + 1] = L
				weights_list[#weights_list + 1] = bag.dictionary.spawn_weights[L] or 0.0001
			end
			if #letters_list == 0 then
				idx = math.random(1, #arr)
			else
				local picked = utils.weighted_choice(letters_list, weights_list)
				bag.total_drawn = bag.total_drawn + 1
				return picked
			end
		else
			idx = matches[math.random(1, #matches)]
		end
	else
		idx = math.random(1, #arr)
	end

	local L = arr[idx]
	-- swap-remove.
	arr[idx] = arr[#arr]
	arr[#arr] = nil
	bag.letter_counts[L] = math.max(0, (bag.letter_counts[L] or 1) - 1)
	bag.total_drawn = bag.total_drawn + 1
	return L
end

function letter_bag.return_letter(bag, letter)
	bag.letters[#bag.letters + 1] = letter
	bag.letter_counts[letter] = (bag.letter_counts[letter] or 0) + 1
end

function letter_bag.stats(bag)
	return {
		size = #bag.letters,
		max_size = bag.size,
		total_drawn = bag.total_drawn,
		rare_threshold = bag.rare_threshold,
		allowed_set = bag.allowed_set
	}
end

return letter_bag
