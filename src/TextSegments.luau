--!strict

-- Text following a logical element child, indexed by that child's position.
-- Leading text remains Node.text; element-only selector ancestry is unchanged.
export type After = { [number]: string }
local TextSegments = {}

function TextSegments.copy(source: After?): After?
	if not source or next(source) == nil then
		return nil
	end
	local result: After = {}
	for index, text in source do
		assert(
			type(index) == "number" and index >= 1 and index < math.huge and index % 1 == 0,
			"Text segment index must be a positive integer"
		)
		assert(type(text) == "string", "Text segment content must be a string")
		result[index] = text
	end
	return result
end

function TextSegments.same(a: After?, b: After?): boolean
	if a == b then
		return true
	end
	if not a then
		return not b or next(b) == nil
	end
	if not b then
		return next(a) == nil
	end
	for index, text in a do
		if not b or b[index] ~= text then
			return false
		end
	end
	for index, text in b do
		if not a or a[index] ~= text then
			return false
		end
	end
	return true
end

function TextSegments.has(source: After?): boolean
	if not source then
		return false
	end
	for _, text in source do
		if text ~= "" then
			return true
		end
	end
	return false
end

function TextSegments.validate(source: After?, children: number): string?
	if not source then
		return nil
	end
	for index, text in source do
		if type(index) ~= "number" or index < 1 or index > children or index % 1 ~= 0 or type(text) ~= "string" then
			return "invalid-ordered-text-segment"
		end
	end
	return nil
end

return TextSegments
