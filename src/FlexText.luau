--!strict

local FlexScene = require(script.Parent.FlexScene)
local TextSegments = require(script.Parent.TextSegments)
local BoxChildren = require(script.Parent.BoxChildren)
local Fonts = require(script.Parent.Fonts)
local Typography = require(script.Parent.Typography)
local Whitespace = require(script.Parent.Whitespace)
local TextLine = require(script.Parent.TextLine)
local TextParagraph = require(script.Parent.TextParagraph)
local Display = require(script.Parent.Display)
local TextIntrinsic = require(script.Parent.TextIntrinsic)

export type Options = {
	fonts: Fonts.Provider?,
	geometry: TextLine.GeometryProvider?,
	nativeTextLine: boolean?,
	fontMetrics: Typography.MetricsProvider?,
}

local FlexText = {}

-- Nil without a reason means this is not a supported intrinsic text shape.
-- It leaves explicit CSS sizing or the consumer's provider in control.
function FlexText.resolve(request: FlexScene.Request, options: Options): (FlexScene.Intrinsic?, string?)
	local node, style = request.node, request.style
	if TextSegments.has(node.textAfter) then
		return nil, nil
	end
	local children, childrenFailure = BoxChildren.resolve(node, request.snapshot)
	if not children then
		return nil, childrenFailure
	end
	if node.text == "" then
		return nil, nil
	end
	-- Out-of-flow decorations do not contribute to the text's intrinsic size.
	-- The scene still formats and validates them through its positioned path.
	-- In-flow children require the mixed-content formatter instead.
	for _, child in children do
		local childStyle = request.snapshot.styles[child]
		if not childStyle then
			return nil, "missing-flex-text-child-style"
		end
		local display, failure = Display.forNode(childStyle, child)
		if not display then
			return nil, failure
		end
		if display == "none" then
			continue
		end
		if childStyle.unresolved.position then
			return nil, childStyle.unresolved.position
		end
		local position = childStyle.properties.position
		if not position or #position ~= 1 or position[1].kind ~= "word" then
			return nil, nil
		end
		local name = string.lower(position[1].value)
		if name ~= "absolute" and name ~= "fixed" then
			return nil, nil
		end
	end
	if style.unresolved.content then
		return nil, nil
	end
	local content = style.properties.content
	if
		content
		and not (
			#content == 1
			and content[1].kind == "word"
			and (content[1].value == "normal" or content[1].value == "none")
		)
	then
		return nil, nil
	end
	local display, displayFailure = Display.resolve(style)
	if not display then
		return nil, displayFailure
	end
	if display == "flex" or display == "inline-flex" then
		if not request.snapshot.anonymousStyle then
			return nil, "anonymous-style-provider-required"
		end
		local anonymous, failure = request.snapshot.anonymousStyle(node)
		if not anonymous then
			return nil, failure
		end
		-- A flex container's direct text uses anonymous inheritance, so its
		-- non-inherited text properties must not leak onto that text item.
		style = anonymous
	end
	local policy, policyFailure = Whitespace.resolve(style)
	if not policy then
		return nil, policyFailure
	end
	if not options.fonts then
		return nil, "flex-text-font-provider-required"
	end
	-- Intrinsic shaping receives only this text run. Keep logical children and
	-- selector ancestry untouched; positioned descendants are formatted later.
	-- A retained wrapping callback must keep its text-only projection even if
	-- the logical node later gains an out-of-flow decoration.
	local textNode = table.clone(node)
	textNode.children = {}
	local atoms, atomFailure = Whitespace.process({ { source = textNode, text = node.text, policy = policy } })
	if not atoms then
		return nil, atomFailure
	end
	if policy.wrap == "wrap" then
		local intrinsic, failure = TextIntrinsic.resolve(textNode, style, atoms, {
			width = 0,
			fonts = options.fonts,
			fontMetrics = if options.fontMetrics then options.fontMetrics(style) else options.fonts:getMetrics(style),
			measureText = request.snapshot.measureText,
			geometry = options.geometry,
			nativeTextLine = options.nativeTextLine,
		})
		if not intrinsic then
			return nil, failure
		end
		return {
			minContentWidth = intrinsic.minimum + request.metrics.horizontalInset,
			maxContentWidth = intrinsic.maximum + request.metrics.horizontalInset,
			flexBase = if request.flow == "row" or request.flow == "row-reverse"
				then intrinsic.maximum + request.metrics.horizontalInset
				else nil,
			measure = intrinsic.measure,
		},
			nil
	end
	local line, failure = TextParagraph.resolve(textNode, style, atoms, {
		width = 0,
		fonts = options.fonts,
		fontMetrics = if options.fontMetrics then options.fontMetrics(style) else options.fonts:getMetrics(style),
		measureText = request.snapshot.measureText,
		geometry = options.geometry,
		nativeTextLine = options.nativeTextLine,
	})
	if not line then
		return nil, failure
	end
	local width = line.advance + request.metrics.horizontalInset
	local height = line.height + request.metrics.verticalInset
	local horizontal = request.flow == "row" or request.flow == "row-reverse"
	return {
		minContentWidth = width,
		maxContentWidth = width,
		minContentHeight = height,
		flexBase = if horizontal then width else height,
		hypotheticalCrossSize = if horizontal then height else width,
	},
		nil
end

return FlexText
