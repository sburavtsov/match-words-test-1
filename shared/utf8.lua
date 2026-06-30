local utf8 = {}

local function utf8_charbytes(b)
	if b < 0x80 then return 1
	elseif b < 0xC0 then return 1
	elseif b < 0xE0 then return 2
	elseif b < 0xF0 then return 3
	elseif b < 0xF8 then return 4
	else return 1 end
end

function utf8.len(s)
	local n = 0
	local i = 1
	while i <= #s do
		local b = string.byte(s, i)
		local size = utf8_charbytes(b)
		if size == 1 and b >= 0x80 then return nil, i end
		i = i + size
		n = n + 1
	end
	return n
end

function utf8.char(...)
	local out = {}
	for i = 1, select("#", ...) do
		local cp = select(i, ...)
		if cp < 0x80 then
			out[#out + 1] = string.char(cp)
		elseif cp < 0x800 then
			out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
		elseif cp < 0x10000 then
			out[#out + 1] = string.char(
				0xE0 + math.floor(cp / 0x1000),
				0x80 + (math.floor(cp / 0x40) % 0x40),
				0x80 + (cp % 0x40)
			)
		else
			out[#out + 1] = string.char(
				0xF0 + math.floor(cp / 0x40000),
				0x80 + (math.floor(cp / 0x1000) % 0x40),
				0x80 + (math.floor(cp / 0x40) % 0x40),
				0x80 + (cp % 0x40)
			)
		end
	end
	return table.concat(out)
end

function utf8.codes(s)
	local i = 1
	return function()
		if i > #s then return nil end
		local pos = i
		local b = string.byte(s, i)
		local size = utf8_charbytes(b)
		local cp
		if size == 1 then
			cp = b
		elseif size == 2 then
			cp = (b - 0xC0) * 0x40 + string.byte(s, i + 1) - 0x80
		elseif size == 3 then
			cp = (b - 0xE0) * 0x1000 + (string.byte(s, i + 1) - 0x80) * 0x40 + string.byte(s, i + 2) - 0x80
		else
			cp = (b - 0xF0) * 0x40000 + (string.byte(s, i + 1) - 0x80) * 0x1000 + (string.byte(s, i + 2) - 0x80) * 0x40 + string.byte(s, i + 3) - 0x80
		end
		i = i + size
		return pos, cp
	end
end

function utf8.sub(s, i, j)
	local out = {}
	local pos = 1
	local n = 0
	while pos <= #s do
		local b = string.byte(s, pos)
		local size = utf8_charbytes(b)
		n = n + 1
		if n >= i then
			out[#out + 1] = string.sub(s, pos, pos + size - 1)
		end
		pos = pos + size
		if j and n >= j then break end
	end
	return table.concat(out)
end

function utf8.byte(s, i, j)
	i = i or 1
	j = j or i
	local out = {}
	local pos = 1
	local n = 0
	while pos <= #s and n < j do
		local b = string.byte(s, pos)
		local size = utf8_charbytes(b)
		n = n + 1
		if n >= i then
			local cp
			if size == 1 then cp = b
			elseif size == 2 then cp = (b - 0xC0) * 0x40 + string.byte(s, pos + 1) - 0x80
			elseif size == 3 then cp = (b - 0xE0) * 0x1000 + (string.byte(s, pos + 1) - 0x80) * 0x40 + string.byte(s, pos + 2) - 0x80
			else cp = (b - 0xF0) * 0x40000 + (string.byte(s, pos + 1) - 0x80) * 0x1000 + (string.byte(s, pos + 2) - 0x80) * 0x40 + string.byte(s, pos + 3) - 0x80 end
			out[#out + 1] = cp
		end
		pos = pos + size
	end
	if #out == 1 then return out[1] end
	return unpack(out)
end

_G.utf8 = utf8
return utf8