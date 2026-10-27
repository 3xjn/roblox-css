--!strict

local Types = require(script.Parent.Types)
type Token = Types.ValueToken

local FontFeatures = {}
local numeric: { [string]: { [string]: number } } = {
	["lining-nums"] = { lnum = 1, onum = 0 },
	["oldstyle-nums"] = { onum = 1, lnum = 0 },
	["proportional-nums"] = { pnum = 1, tnum = 0 },
	["tabular-nums"] = { tnum = 1 },
	["diagonal-fractions"] = { frac = 1, afrc = 0 },
	["stacked-fractions"] = { afrc = 1, frac = 0 },
	ordinal = { ordn = 1 },
	["slashed-zero"] = { zero = 1 },
}
local ligatures: { [string]: { [string]: number } } = {
	["common-ligatures"] = { liga = 1, clig = 1 },
	["no-common-ligatures"] = { liga = 0, clig = 0 },
	["discretionary-ligatures"] = { dlig = 1 },
	["no-discretionary-ligatures"] = { dlig = 0 },
	["historical-ligatures"] = { hlig = 1 },
	["no-historical-ligatures"] = { hlig = 0 },
	contextual = { calt = 1 },
	["no-contextual"] = { calt = 0 },
	none = { liga = 0, clig = 0, dlig = 0, hlig = 0, calt = 0 },
}

local function significant(tokens: { Token }): { Token }
	local result = {}
	for _, token in tokens do
		if token.kind ~= "space" and token.kind ~= "comment" then
			table.insert(result, token)
		end
	end
	return result
end

function FontFeatures.resolve(style: Types.ComputedStyle, defaults: { [string]: number }?): (string?, string?)
	local features: { [string]: number } = {}
	for _, entry in
		{
			{ property = "font-variant-numeric", mappings = numeric },
			{ property = "font-variant-ligatures", mappings = ligatures },
		}
	do
		local property = entry.property
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		for _, token in significant(style.properties[property] or {}) do
			local name = if token.kind == "word" then string.lower(token.value) else ""
			if name == "normal" then
				continue
			end
			local mapped = entry.mappings[name]
			if not mapped then
				return nil, `unsupported-{property}:{token.value}`
			end
			for tag, value in mapped do
				features[tag] = value
			end
		end
	end
	local kerning = significant(style.properties["font-kerning"] or {})
	if style.unresolved["font-kerning"] then
		return nil, style.unresolved["font-kerning"]
	end
	if #kerning > 0 then
		if #kerning ~= 1 or kerning[1].kind ~= "word" then
			return nil, "invalid-font-kerning"
		end
		local name = string.lower(kerning[1].value)
		if name == "normal" then
			features.kern = 1
		elseif name == "none" then
			features.kern = 0
		elseif name ~= "auto" then
			return nil, `unsupported-font-kerning:{name}`
		end
	end
	-- Low-level font-feature-settings take precedence over the high-level variants.
	if style.unresolved["font-feature-settings"] then
		return nil, style.unresolved["font-feature-settings"]
	end
	local tokens = significant(style.properties["font-feature-settings"] or {})
	if not (#tokens == 1 and tokens[1].kind == "word" and string.lower(tokens[1].value) == "normal") then
		local index = 1
		while index <= #tokens do
			local token = tokens[index]
			if token.kind ~= "string" or #token.value ~= 4 or token.value:find("[^ -~]") then
				return nil, "invalid-opentype-tag"
			end
			local tag = token.value
			index += 1
			local value = 1
			local setting = tokens[index]
			if setting and not (setting.kind == "div" and setting.value == ",") then
				if setting.kind == "word" and string.lower(setting.value) == "on" then
					value = 1
				elseif setting.kind == "word" and string.lower(setting.value) == "off" then
					value = 0
				elseif setting.kind == "number" then
					local number = tonumber(setting.value)
					if not number or number < 0 or number == math.huge or number % 1 ~= 0 then
						return nil, "invalid-opentype-setting"
					end
					value = number
				else
					return nil, "invalid-opentype-setting"
				end
				index += 1
			end
			features[tag] = value
			if index <= #tokens then
				if tokens[index].kind ~= "div" or tokens[index].value ~= "," or index == #tokens then
					return nil, "invalid-opentype-list"
				end
				index += 1
			end
		end
	end
	local tags: { string } = {}
	for tag in features do
		if defaults and defaults[tag] == features[tag] then
			continue
		end
		-- Native feature strings cannot safely encode CSS tags containing syntax.
		if not tag:match("^%w%w%w%w$") then
			return nil, "native-opentype-tag-encoding-required"
		end
		table.insert(tags, tag)
	end
	table.sort(tags)
	local output = {}
	for _, tag in tags do
		table.insert(output, `{tag}={features[tag]}`)
	end
	return table.concat(output, ","), nil
end

return FontFeatures
