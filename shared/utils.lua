--[[
utils.lua

Shared utility functions for the WordGame project.
No state, no dependencies, just pure helper functions.
Compatible with Defold's Lua 5.1 runtime.
]]--

local utils = {}

-- ──────────────────────────────────────────────────
-- UTF-8 helpers
-- ──────────────────────────────────────────────────

-- UTF-8 character length.
function utils.utf8_len(s)
	if s == nil then
		return 0
	end

	local ok, result = pcall(function()
		return utf8.len(s)
	end)

	if ok and result then
		return result
	end

	-- Fallback for ASCII-only environments.
	return #s
end

-- UTF-8 substring by character indices (1-based).
function utils.utf8_sub(s, i, j)
	if s == nil or s == "" then
		return ""
	end

	local len = utils.utf8_len(s)
	i = i or 1
	j = j or len

	if i < 1 then
		i = 1
	end
	if j > len then
		j = len
	end
	if i > j then
		return ""
	end

	-- In Defold's Lua 5.1, utf8 module might not be available.
	-- If available, use utf8.offset. Otherwise use simple byte scan.
	local start_byte, end_byte

	if utf8 and utf8.offset then
		start_byte = utf8.offset(s, i)
		end_byte = utf8.offset(s, j + 1)
	else
		-- Simple byte scan (works correctly for 1-byte chars, i.e. ASCII + Latin).
		start_byte = i
		end_byte = j + 1
	end

	if not start_byte then
		return ""
	end

	if end_byte then
		return s:sub(start_byte, end_byte - 1)
	else
		return s:sub(start_byte)
	end
end

-- Count occurrences of a plain substring.
-- Used for QU detection.
function utils.count_substring(haystack, needle)
	local count = 0
	local start_pos = 1

	while true do
		local i = haystack:find(needle, start_pos, true)
		if not i then
			break
		end
		count = count + 1
		start_pos = i + #needle
	end

	return count
end

-- Tile length of a word: QU counts as one tile.
function utils.tile_len(word)
	local raw_len = utils.utf8_len(word)
	local qu_count = utils.count_substring(word, "QU")
	return raw_len - qu_count
end

-- ──────────────────────────────────────────────────
-- Coordinate helpers
-- ──────────────────────────────────────────────────

function utils.coord_key(x, y)
	return x .. "|" .. y
end

function utils.copy_cell(cell)
	if cell == nil then
		return nil
	end

	return {
		char = cell.char,
		is_target = cell.is_target == true,
		is_booster = cell.is_booster == true,
		joker_type = cell.joker_type
	}
end

function utils.copy_path(path)
	local out = {}
	for i = 1, #path do
		out[i] = {
			x = path[i].x,
			y = path[i].y
		}
	end
	return out
end

-- ──────────────────────────────────────────────────
-- Array helpers
-- ──────────────────────────────────────────────────

function utils.array_max(arr)
	local m = arr[1]
	for i = 2, #arr do
		if arr[i] > m then
			m = arr[i]
		end
	end
	return m
end

function utils.copy_array(arr)
	local out = {}
	for i = 1, #arr do
		out[i] = arr[i]
	end
	return out
end

function utils.array_contains(arr, value)
	for i = 1, #arr do
		if arr[i] == value then
			return true
		end
	end
	return false
end

function utils.array_remove_value(arr, value)
	for i = #arr, 1, -1 do
		if arr[i] == value then
			table.remove(arr, i)
		end
	end
end

-- ──────────────────────────────────────────────────
-- Set helpers
-- ──────────────────────────────────────────────────

function utils.set_to_sorted_array(set_table)
	local out = {}
	for key, _ in pairs(set_table) do
		out[#out + 1] = key
	end
	table.sort(out)
	return out
end

function utils.set_keys(set_table)
	local out = {}
	for key, _ in pairs(set_table) do
		out[#out + 1] = key
	end
	return out
end

function utils.set_size(set_table)
	local count = 0
	for _ in pairs(set_table) do
		count = count + 1
	end
	return count
end

-- ──────────────────────────────────────────────────
-- Weighted random choice
-- ──────────────────────────────────────────────────

function utils.weighted_choice(items, weights)
	local total = 0.0

	for i = 1, #weights do
		total = total + weights[i]
	end

	if total <= 0 then
		return items[#items]
	end

	local roll = math.random() * total
	local cumulative = 0.0

	for i = 1, #items do
		cumulative = cumulative + weights[i]
		if roll < cumulative then
			return items[i]
		end
	end

	return items[#items]
end

return utils