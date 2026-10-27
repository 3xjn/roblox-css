--!strict

local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local BoxModel = require(script.Parent.BoxModel)
local NativeEditor = require(script.Parent.NativeEditor)

export type Request = {
	node: Types.Node,
	style: Types.ComputedStyle,
	metrics: BoxModel.Metrics,
	geometry: BoxModel.Geometry,
	editor: NativeEditor.Data,
}
export type Provider = (Request) -> (SceneTypes.Baselines?, string?)

local EditorBaselines = {}

-- Offsets are from the used border-box top in CSS pixels. Native text bounds
-- do not establish this calibration. Nil edges remain unknown; finite offsets
-- outside the box are valid (e.g. overflowing text or negative leading).
function EditorBaselines.resolve(
	box: SceneTypes.Box,
	style: Types.ComputedStyle,
	provider: Provider
): (SceneTypes.Baselines?, string?)
	local current, editor = box.baselines, box.editor
	if not editor or not current or (current.first ~= nil and current.last ~= nil) then
		return current, nil
	end
	local ok, supplied, failure = pcall(provider, {
		node = box.node,
		style = style,
		metrics = box.metrics,
		geometry = BoxModel.fromBorderBox(box.metrics, box.width, box.height),
		editor = table.clone(editor),
	})
	if not ok then
		return nil, `editor-baseline-provider:{tostring(supplied)}`
	end
	if failure then
		return nil, failure
	end
	if supplied == nil then
		return current, nil
	end
	if type(supplied) ~= "table" then
		return nil, "invalid-editor-baselines"
	end
	for name, value in supplied :: { [string]: unknown } do
		if name ~= "first" and name ~= "last" then
			return nil, "invalid-editor-baseline-field"
		end
		if type(value) ~= "number" or value ~= value or math.abs(value) >= math.huge then
			return nil, "invalid-editor-baselines"
		end
	end
	local result = table.clone(current)
	if result.first == nil then
		result.first = supplied.first
	end
	if result.last == nil then
		result.last = supplied.last
	end
	return result, nil
end

return EditorBaselines
