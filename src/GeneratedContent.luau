--!strict

local Types = require(script.Parent.Types)
local Display = require(script.Parent.Display)

local GeneratedContent = {}

-- Empty content still generates a real box. It must not be conflated with
-- normal/none, which generate no before/after box.
function GeneratedContent.resolve(style: Types.ComputedStyle): (string?, string?)
	local display, failure = Display.resolve(style)
	if not display then
		return nil, failure
	elseif display == "none" then
		return "none", nil
	elseif style.unresolved.content then
		return nil, style.unresolved.content
	end
	local tokens = style.properties.content
	if not tokens then
		return "none", nil
	elseif #tokens == 1 then
		local token = tokens[1]
		if token.kind == "word" then
			local name = string.lower(token.value)
			if name == "none" or name == "normal" then
				return "none", nil
			end
		elseif token.kind == "string" and token.value == "" then
			return "empty", nil
		end
	end
	return nil, "generated-content-value-provider-required"
end

return GeneratedContent
