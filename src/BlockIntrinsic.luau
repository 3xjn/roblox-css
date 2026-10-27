--!strict

local Types = require(script.Parent.Types)
local TextSegments = require(script.Parent.TextSegments)
local Measurements = require(script.Parent.Measurements)
local BoxModel = require(script.Parent.BoxModel)
local LogicalProperties = require(script.Parent.LogicalProperties)
local SizingValue = require(script.Parent.SizingValue)
local Display = require(script.Parent.Display)
local BoxChildren = require(script.Parent.BoxChildren)
local FlexScene = require(script.Parent.FlexScene)
local FlexText = require(script.Parent.FlexText)
local GeneratedContent = require(script.Parent.GeneratedContent)
local Whitespace = require(script.Parent.Whitespace)
local FlexIntrinsic = require(script.Parent.FlexIntrinsic)
local AspectRatio = require(script.Parent.AspectRatio)

export type Options = FlexText.Options & {
	getLengths: (Types.ComputedStyle) -> Measurements.Context,
	flexIntrinsic: FlexScene.Provider?,
}

local BlockIntrinsic = {}
type Widths = { minimum: number, maximum: number }
local formattingDefaults: { [string]: string } = {
	["writing-mode"] = "horizontal-tb",
	float = "none",
	contain = "none",
	["content-visibility"] = "visible",
	["column-count"] = "auto",
	["column-width"] = "auto",
}

local function word(style: Types.ComputedStyle, property: string, initial: string): string?
	if style.unresolved[property] then
		return nil
	end
	local tokens = style.properties[property]
	return if not tokens
		then initial
		elseif #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value)
		else nil
end

-- Inline-axis measurement only. The scene supplies width-sensitive height
-- measurement through its formatter, preserving wrapping and margin collapse.
function BlockIntrinsic.resolve(request: FlexScene.Request, options: Options): (FlexScene.Intrinsic?, string?)
	if request.flow ~= "row" and request.flow ~= "row-reverse" then
		return nil, nil
	end
	local function contents(
		node: Types.Node,
		style: Types.ComputedStyle,
		metrics: BoxModel.Metrics,
		context: Measurements.Context,
		blockify: boolean
	): (Widths?, string?)
		local display, failure = Display.resolve(style, blockify)
		if not display then
			return nil, failure
		end
		local role = display
		display = Display.format(display)
		local flex = display == "flex" or display == "inline-flex"
		if display ~= "block" and display ~= "flow-root" and not flex then
			return nil, nil
		end
		for property, initial in formattingDefaults do
			if word(style, property, initial) ~= initial then
				return nil, nil
			end
		end
		local content = GeneratedContent.resolve(style)
		if content ~= "none" then
			return nil, nil
		end
		if request.snapshot.pseudoStyle then
			for _, name in { "before", "after" } do
				local pseudo = request.snapshot.pseudoStyle(node, name)
				if pseudo and GeneratedContent.resolve(pseudo) ~= "none" then
					local position = word(pseudo, "position", "static")
					if position ~= "absolute" and position ~= "fixed" then
						return nil, nil
					end
				end
			end
		end
		-- The caller has already consulted the provider for the request root.
		-- Nested resources use the same provider when their raw inline sizes
		-- are actually needed, before preferred/min/max contribution constraints.
		if node ~= request.node and options.flexIntrinsic then
			local probe = table.clone(request)
			probe.node, probe.style, probe.metrics, probe.lengths = node, style, metrics, context
			probe.width, probe.widthDefinite, probe.height = 0, false, nil
			probe.flow, probe.inlineSizeRequired = "row", true
			local supplied, providerFailure = options.flexIntrinsic(probe)
			if providerFailure then
				return nil, providerFailure
			end
			if supplied then
				local low, high = supplied.minContentWidth, supplied.maxContentWidth
				if low == nil or high == nil then
					return nil, "nested-intrinsic-inline-sizes-required"
				end
				if
					type(low) ~= "number"
					or type(high) ~= "number"
					or low < 0
					or high < low
					or low ~= low
					or high ~= high
					or high >= math.huge
				then
					return nil, "invalid-nested-intrinsic-inline-sizes"
				end
				return { minimum = low, maximum = high }, nil
			end
		end
		if node.tag == "img" or node.tag == "input" or node.tag == "textarea" then
			return nil, nil
		end
		local children, childrenFailure = BoxChildren.resolve(node, request.snapshot)
		if not children then
			return nil, childrenFailure
		end
		local anonymous: { [Types.Node]: Types.ComputedStyle }? = nil
		if
			flex
			and (#children > 0 or TextSegments.has(node.textAfter))
			and (node.text ~= "" or TextSegments.has(node.textAfter))
		then
			anonymous = {}
			local textStyle: Types.ComputedStyle? = nil
			local ordered, reason = BoxChildren.withText(node, children, function(_index, text)
				if text:match("^[ \t\n\r]*$") then
					return nil, nil
				end
				if not request.snapshot.anonymousStyle then
					return nil, "anonymous-style-provider-required"
				end
				if not textStyle then
					local inherited, failure = request.snapshot.anonymousStyle(node)
					if not inherited then
						return nil, failure or "anonymous-style-provider-required"
					end
					local normalized = table.clone(inherited)
					normalized.properties = table.clone(inherited.properties)
					normalized.properties.display = { { kind = "word", value = "block" } }
					textStyle = normalized
				end
				local fragment: Types.Node = {
					tag = "#text",
					className = "",
					classes = {},
					attributes = {},
					states = {},
					text = text,
					parent = node,
					children = {},
				}
				assert(anonymous)[fragment] = assert(textStyle)
				return fragment, nil
			end)
			if not ordered then
				return nil, reason
			end
			children = ordered
		elseif TextSegments.has(node.textAfter) then
			return nil, nil
		end
		if #children == 0 then
			if node.text == "" then
				return { minimum = metrics.horizontalInset, maximum = metrics.horizontalInset }, nil
			end
			local leaf = table.clone(request)
			leaf.node, leaf.style, leaf.metrics, leaf.lengths = node, style, metrics, context
			local measured, textFailure = FlexText.resolve(leaf, options)
			if not measured or measured.minContentWidth == nil or measured.maxContentWidth == nil then
				return nil, textFailure
			end
			return { minimum = measured.minContentWidth, maximum = measured.maxContentWidth }, nil
		elseif node.text ~= "" and not anonymous then
			-- Mixed inline/block formatting needs the inline formatter.
			return nil, nil
		end
		local minWidth: number = 0
		local maxWidth: number = 0
		local pending = false
		local inlineMode: boolean? = nil
		local inlinePolicy: Whitespace.Policy? = nil
		local flexEntries: { FlexIntrinsic.Entry } = {}
		for _, child in children do
			local source = (anonymous and anonymous[child]) or request.snapshot.styles[child]
			if not source then
				return nil, "missing-intrinsic-child-style"
			end
			local physical, mappingFailure = LogicalProperties.view(source)
			if not physical then
				return nil, mappingFailure
			end
			local childDisplay, displayFailure = Display.resolve(physical, flex)
			if not childDisplay then
				return nil, displayFailure
			end
			childDisplay = Display.format(childDisplay)
			local position = word(physical, "position", "static")
			if childDisplay == "none" or position == "absolute" or position == "fixed" then
				continue
			end
			if position ~= "static" and position ~= "relative" then
				return nil, nil
			end
			local atomic = childDisplay == "inline-flex"
			if not atomic and childDisplay ~= "block" and childDisplay ~= "flow-root" and childDisplay ~= "flex" then
				return nil, nil
			end
			if not flex and inlineMode ~= nil and inlineMode ~= atomic then
				-- Anonymous block runs around inline content are not assembled yet.
				return nil, nil
			end
			inlineMode = atomic
			if not flex and atomic and not inlinePolicy then
				local policy, policyFailure = Whitespace.resolve(style)
				if not policy then
					return nil, policyFailure
				end
				if not Whitespace.usesNormalWrapping(policy.wrapStyle) then
					return nil, nil
				end
				inlinePolicy = policy
			end
			if word(physical, "float", "none") ~= "none" then
				return nil, nil
			end
			local childLengths = options.getLengths(physical)
			-- Cyclic margin/padding percentages resolve against zero for the
			-- intrinsic contribution, not the eventual containing-block width.
			local childMetrics, metricFailure = BoxModel.resolveMetrics(physical, {
				lengths = childLengths,
				containingInlineSize = 0,
			})
			if not childMetrics then
				return nil, metricFailure
			end
			local inset = childMetrics.horizontalInset
			local preferred, preferredFailure =
				SizingValue.resolve(physical, "width", childMetrics, childLengths, nil, inset)
			local ratio, ratioFailure = AspectRatio.resolve(physical, childMetrics)
			if ratioFailure then return nil, ratioFailure end
			if preferred == nil and ratio and not flex then
				local height, heightFailure = SizingValue.resolve(physical, "height", childMetrics, childLengths, nil, childMetrics.verticalInset)
				if heightFailure then return nil, heightFailure end
				if height ~= nil then
					preferred, preferredFailure = AspectRatio.transfer(ratio, height, "height", childMetrics)
				end
			end
			local minimum, minimumFailure =
				SizingValue.resolve(physical, "min-width", childMetrics, childLengths, nil, inset)
			local maximum, maximumFailure =
				SizingValue.resolve(physical, "max-width", childMetrics, childLengths, nil, inset)
			if preferredFailure or minimumFailure or maximumFailure then
				return nil, preferredFailure or minimumFailure or maximumFailure
			end
			local contribution: Widths?
			if preferred ~= nil and not flex then
				contribution = { minimum = preferred, maximum = preferred }
			else
				local raw: Widths?
				local rawFailure: string?
				raw, rawFailure = contents(child, physical, childMetrics, childLengths, flex)
				if rawFailure == "pending-text-measurement" then
					pending = true
					continue
				elseif raw == nil and rawFailure == nil and preferred ~= nil then
					-- A definite width still contributes when a descendant has no
					-- intrinsic provider (for example an aspect-ratio decoration).
					raw = { minimum = preferred + inset, maximum = preferred + inset }
				elseif raw == nil then
					return nil, rawFailure
				end
				assert(raw ~= nil)
				if flex then
					local low = if preferred ~= nil then preferred else math.max(0, raw.minimum - inset)
					local high = if preferred ~= nil then preferred else math.max(0, raw.maximum - inset)
					table.insert(flexEntries, {
						item = {
							node = child,
							style = physical,
							metrics = childMetrics,
							lengths = childLengths,
							minContentWidth = raw.minimum,
							flexBase = raw.maximum,
						},
						minimum = math.max(minimum or 0, math.min(low, maximum or math.huge)) + inset,
						maximum = math.max(minimum or 0, math.min(high, maximum or math.huge)) + inset,
					})
					continue
				end
				contribution =
					{ minimum = math.max(0, raw.minimum - inset), maximum = math.max(0, raw.maximum - inset) }
			end
			assert(contribution ~= nil)
			local margin = childMetrics.margin.left.value + childMetrics.margin.right.value
			local childMin = math.max(minimum or 0, math.min(contribution.minimum, maximum or math.huge))
				+ inset
				+ margin
			local childMax = math.max(minimum or 0, math.min(contribution.maximum, maximum or math.huge))
				+ inset
				+ margin
			if atomic then
				if childMetrics.margin.left.value < 0 or childMetrics.margin.right.value < 0 then
					return nil, nil
				end
				local policy = assert(inlinePolicy)
				minWidth = if policy.wrap == "nowrap" then minWidth + childMin else math.max(minWidth, childMin)
				maxWidth += childMax
			else
				minWidth = math.max(minWidth, childMin)
				maxWidth = math.max(maxWidth, childMax)
			end
		end
		if pending then
			return nil, "pending-text-measurement"
		end
		if flex then
			local flexStyle = style
			if role == "table-row" then
				flexStyle = table.clone(style)
				flexStyle.properties = table.clone(style.properties)
				flexStyle.properties.display = { { kind = "word", value = "flex" } }
			end
			local widths, flexFailure = FlexIntrinsic.resolve(flexStyle, flexEntries, context)
			if not widths then
				return nil, flexFailure
			end
			minWidth, maxWidth = widths.minimum, widths.maximum
		end
		minWidth += metrics.horizontalInset
		maxWidth = math.max(minWidth, maxWidth + metrics.horizontalInset)
		if
			minWidth ~= minWidth
			or maxWidth ~= maxWidth
			or math.abs(minWidth) == math.huge
			or math.abs(maxWidth) == math.huge
		then
			return nil, "block-intrinsic-width-overflow"
		end
		return { minimum = minWidth, maximum = maxWidth }, nil
	end
	local widths, failure = contents(request.node, request.style, request.metrics, request.lengths, true)
	if widths == nil then
		return nil, failure
	end
	-- Own preferred/min/max constraints are applied later by FlexSizing.
	return { minContentWidth = widths.minimum, maxContentWidth = widths.maximum, flexBase = widths.maximum }, nil
end

return BlockIntrinsic
