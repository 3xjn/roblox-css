--!strict

local Types = require(script.Parent.Types)
local FlexTypes = require(script.Parent.FlexTypes)
local Measurements = require(script.Parent.Measurements)
local Typography = require(script.Parent.Typography)
local LogicalProperties = require(script.Parent.LogicalProperties)
local AspectRatio = require(script.Parent.AspectRatio)
local FlexibleLengths = require(script.Parent.FlexibleLengths)

local FlexSizing = {}
local aligns: { [string]: boolean } =
	{ auto = true, normal = true, stretch = true, ["flex-start"] = true, ["flex-end"] = true, center = true }

local function word(tokens: { Types.ValueToken }?): string?
	return if tokens and #tokens == 1 and tokens[1].kind == "word" then string.lower(tokens[1].value) else nil
end

local function finite(value: number): boolean
	return value >= 0 and value < math.huge
end

local function number(style: Types.ComputedStyle, property: string, initial: number): (number?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	if not tokens then
		return initial, nil
	end
	local value, failure = Measurements.resolve(tokens, {})
	if value and value.value < 0 and #tokens == 1 and tokens[1].kind == "function" then
		value.value = 0
	end
	if not value or value.dimension ~= "number" or not finite(value.value) then
		return nil, failure or `invalid-flex-factor:{property}`
	end
	return value.value, nil
end

-- The item owns this scratch context. Evaluation neither yields nor retains it;
-- width, height and basis calculations can set their percentage basis in turn.
local function length(tokens: { Types.ValueToken }, options: Measurements.Context, basis: number?): (number?, string?)
	options.allowRatio = nil
	options.percentageDimension = "length"
	options.percentageBasis = basis
	local value, failure = Measurements.resolve(tokens, options)
	if not value or (value.dimension ~= "length" and not (value.dimension == "number" and value.value == 0)) then
		return nil, failure or "flex-length-required"
	end
	local scalar = Measurements.toScalar(value, options)
	if scalar == nil and basis == nil and (value.percentage or 0) ~= 0 then
		return nil, "indefinite-flex-percentage"
	end
	if scalar == nil or scalar ~= scalar or math.abs(scalar) == math.huge then
		return nil, "invalid-flex-length"
	end
	if scalar < 0 and not (#tokens == 1 and tokens[1].kind == "function") then
		return nil, "negative-flex-length"
	end
	return math.max(0, scalar), nil
end

local function dimension(
	style: Types.ComputedStyle,
	property: string,
	initial: string,
	lengths: Measurements.Context,
	basis: number?,
	inset: number,
	borderBox: boolean,
	automatic: number?
): (number?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	local name = if tokens then word(tokens) else initial
	if name == "none" and property:sub(1, 4) == "max-" then
		return nil, nil
	end
	if name == "auto" then
		if property:sub(1, 4) == "min-" then
			if automatic == nil then
				return nil, `automatic-minimum-required:{property}`
			end
			if not finite(automatic) then
				return nil, `invalid-automatic-minimum:{property}`
			end
			return math.max(inset, automatic), nil
		end
		return nil, nil
	end
	if name then
		return nil, `intrinsic-size-provider-required:{property}:{name}`
	end
	if not tokens then
		return nil, `size-value-required:{property}`
	end
	local value, failure = length(tokens, lengths, basis)
	if
		basis == nil
		and Measurements.hasPercentage(tokens)
		and (value ~= nil or failure == "indefinite-flex-percentage" or failure == "percentage-basis-required")
	then
		-- Preserve percentage dependence even when its coefficient is zero.
		-- Unknown math still fails before the cyclic-percentage fallback.
		return if property:sub(1, 4) == "min-" then inset else nil, nil
	end
	if value == nil then
		return nil, `{property}:{failure or "invalid"}`
	end
	return if borderBox then value else value + inset, nil
end

local function alignment(style: Types.ComputedStyle, property: string, initial: string): (string?, string?)
	if style.unresolved[property] then
		return nil, `{property}:{style.unresolved[property]}`
	end
	local tokens = style.properties[property]
	local value = if tokens then word(tokens) else initial
	if not value or not aligns[value] then
		return nil, `flex-alignment-provider-required:{property}`
	end
	return value, nil
end

local function scrollableOverflow(style: Types.ComputedStyle): (boolean?, string?)
	local scrollable = false
	for _, axis in { "x", "y" } do
		local property = `overflow-{axis}`
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
		local tokens = style.properties[property]
		local value = if tokens then word(tokens) else "visible"
		if value == "hidden" or value == "auto" or value == "scroll" then
			scrollable = true
		elseif value ~= "visible" and value ~= "clip" then
			return nil, `flex-automatic-minimum-overflow-required:{axis}`
		end
	end
	return scrollable, nil
end

local function automaticMinimum(
	style: Types.ComputedStyle,
	explicit: number?,
	content: number?,
	preferred: number?,
	maximum: number?,
	transferred: number?,
	ratioMinimum: number?,
	ratioMaximum: number?
): (number?, string?)
	if explicit ~= nil then
		return explicit, nil
	end
	local scrollable, failure = scrollableOverflow(style)
	if scrollable == nil then
		return nil, failure
	end
	if scrollable then
		return 0, nil
	end
	if content == nil then
		return nil, nil
	end
	if not finite(content) then
		return nil, "invalid-flex-min-content-suggestion"
	end
	local suggestion = math.max(ratioMinimum or 0, math.min(content, ratioMaximum or math.huge))
	return math.min(math.max(suggestion, transferred or 0), preferred or math.huge, maximum or math.huge), nil
end

local function flexBasis(
	style: Types.ComputedStyle,
	lengths: Measurements.Context,
	mainBasis: number?,
	inset: number,
	borderBox: boolean
): (number?, boolean, string?)
	local tokens = style.properties["flex-basis"]
	local name = if tokens then word(tokens) else "auto"
	if name == "auto" then
		return nil, false, nil
	elseif name == "content" then
		return nil, true, nil
	elseif name or not tokens then
		return nil, false, "intrinsic-flex-basis-provider-required"
	end
	local value, failure = length(tokens, lengths, mainBasis)
	if
		mainBasis == nil
		and Measurements.hasPercentage(tokens)
		and (value ~= nil or failure == "indefinite-flex-percentage" or failure == "percentage-basis-required")
	then
		-- An unresolved percentage uses content, not the preferred main size.
		return nil, true, nil
	elseif value == nil then
		return nil, false, failure
	end
	return if borderBox then value else value + inset, false, nil
end

local function measureHeight(
	measure: FlexTypes.Measure,
	contentWidth: number,
	inset: number,
	diagnostic: string
): (number?, string?)
	local ok, measured, reason = pcall(function(): (number?, string?)
		local result, failure = measure({ width = contentWidth, widthMode = "exactly", heightMode = "undefined" })
		if not result then
			return nil, failure or `{diagnostic}-required`
		end
		if not finite(result.width) or not finite(result.height) or not finite(result.height + inset) then
			error(`invalid-{diagnostic}`, 0)
		end
		return result.height + inset, nil
	end)
	if not ok then
		return nil, `{diagnostic}:{tostring(measured)}`
	end
	return measured, reason
end

function FlexSizing.prepare(
	style: Types.ComputedStyle,
	items: { FlexTypes.Item },
	context: FlexTypes.Context
): (FlexTypes.Prepared?, string?)
	if not finite(context.width) or not finite(context.height) then
		return nil, "definite-flex-content-size-required"
	end
	for _, property in { "display", "writing-mode", "direction", "flex-direction", "flex-wrap" } do
		if style.unresolved[property] then
			return nil, `{property}:{style.unresolved[property]}`
		end
	end
	local properties = style.properties
	local display = word(properties.display)
	if display ~= "flex" and display ~= "inline-flex" then
		return nil, "flex-container-required"
	end
	local mode = word(properties["writing-mode"]) or "horizontal-tb"
	if mode ~= "horizontal-tb" then
		return nil, "vertical-flex-sizing-provider-required"
	end
	local direction = word(properties.direction) or "ltr"
	if direction ~= "ltr" and direction ~= "rtl" then
		return nil, "invalid-flex-directionality"
	end
	local flow = word(properties["flex-direction"]) or "row"
	if flow ~= "row" and flow ~= "row-reverse" and flow ~= "column" and flow ~= "column-reverse" then
		return nil, "invalid-flex-direction"
	end
	if (word(properties["flex-wrap"]) or "nowrap") ~= "nowrap" then
		return nil, "wrapped-flex-sizing-provider-required"
	end
	local horizontal = flow == "row" or flow == "row-reverse"
	local automaticHeight = context.autoHeight == true
	local autoCross = (automaticHeight or context.measureCross == true) and horizontal
	local autoMain = automaticHeight and not horizontal
	if automaticHeight then
		if context.minHeight ~= nil and not finite(context.minHeight) then
			return nil, "invalid-flex-cross-minimum"
		end
		if context.maxHeight ~= nil and not finite(context.maxHeight) then
			return nil, "invalid-flex-cross-maximum"
		end
	end
	local widthBasis = if context.widthDefinite == false then nil else context.width
	local mainBasis = if horizontal
		then widthBasis
		else (if automaticHeight or context.heightDefinite == false then nil else context.height)
	local alignItems, alignFailure = alignment(style, "align-items", "normal")
	if not alignItems then
		return nil, alignFailure
	end
	if alignItems == "auto" then
		return nil, "invalid-align-items"
	end
	local gapProperty = if horizontal then "column-gap" else "row-gap"
	if style.unresolved[gapProperty] then
		return nil, `{gapProperty}:{style.unresolved[gapProperty]}`
	end
	local gap = 0
	local gapTokens = properties[gapProperty]
	if gapTokens and word(gapTokens) ~= "normal" then
		-- Cyclic gap percentages contribute zero during intrinsic sizing;
		-- retain any absolute component of a supported math expression.
		local value, failure = length(gapTokens, table.clone(context.lengths), mainBasis or 0)
		if value == nil then
			return nil, failure
		end
		gap = value
	end
	local prepared: FlexTypes.Prepared = {
		width = context.width,
		height = context.height,
		direction = direction,
		flow = flow,
		alignItems = alignItems,
		gap = gap,
		items = {},
		autoCross = autoCross,
		autoMain = autoMain,
		minimumMain = if autoMain then context.minHeight else nil,
		maximumMain = if autoMain then context.maxHeight else nil,
		minimumCross = context.minHeight,
		maximumCross = context.maxHeight,
	}
	local seen: { [Types.Node]: boolean } = {}
	local pending = false
	for _, sourceItem in items do
		local item = sourceItem
		if item.flexBase ~= nil and not finite(item.flexBase) then
			return nil, "invalid-measured-flex-base"
		end
		if item.hypotheticalCrossSize ~= nil and not finite(item.hypotheticalCrossSize) then
			return nil, "invalid-hypothetical-cross-size"
		end
		if seen[item.node] then
			return nil, "duplicate-flex-item"
		end
		seen[item.node] = true
		local physical, mappingFailure = LogicalProperties.view(item.style)
		if not physical then
			return nil, mappingFailure
		end
		for property, failure in physical.unresolved do
			if
				property == "width"
				or property == "height"
				or property:sub(1, 4) == "min-"
				or property:sub(1, 4) == "max-"
				or property:sub(1, 5) == "flex-"
				or property == "align-self"
			then
				return nil, `{property}:{failure}`
			end
		end
		local values = physical.properties
		local childDisplay = word(values.display)
		local position = word(values.position) or "static"
		if childDisplay == "none" or childDisplay == "contents" or position ~= "static" and position ~= "relative" then
			return nil, "nonparticipating-flex-item"
		end
		if word(values.visibility) == "collapse" then
			return nil, "collapsed-flex-strut-provider-required"
		end
		local ratio, ratioFailure = AspectRatio.resolve(physical, item.metrics)
		if ratioFailure then
			return nil, ratioFailure
		end
		if ratio and (item.replaced or item.node.tag == "input" or item.node.tag == "textarea") then
			return nil, "replaced-flex-ratio-provider-required"
		end
		local metrics = item.metrics
		if metrics.boxSizing ~= "border-box" and metrics.boxSizing ~= "content-box" then
			return nil, "invalid-flex-box-sizing"
		end
		local options = table.clone(item.lengths or context.lengths)
		if not item.lengths then
			options.fontSize = Typography.fontSize(physical)
			options.lineHeight = Typography.lineHeight(physical, nil)
			if options.units then
				options.units = table.clone(options.units)
				for _, unit in { "ex", "ch", "cap", "ic" } do
					options.units[unit] = nil
				end
			end
		end
		local borderBox = metrics.boxSizing == "border-box"
		local fitWidth = not physical.unresolved.width and word(physical.properties.width) == "fit-content"
		local width: number?, widthFailure: string?
		if not fitWidth then
			width, widthFailure = dimension(physical, "width", "auto", options, widthBasis, metrics.horizontalInset, borderBox, nil)
		end
		local heightBasis = if automaticHeight or context.heightDefinite == false
			then nil
			else context.percentageHeightBasis or context.height
		local height, heightFailure =
			dimension(physical, "height", "auto", options, heightBasis, metrics.verticalInset, borderBox, nil)
		if widthFailure or heightFailure then
			return nil, widthFailure or heightFailure
		end
		local maxWidth, maxWidthFailure =
			dimension(physical, "max-width", "none", options, widthBasis, metrics.horizontalInset, borderBox, nil)
		local maxHeight, maxHeightFailure =
			dimension(physical, "max-height", "none", options, heightBasis, metrics.verticalInset, borderBox, nil)
		if maxWidthFailure or maxHeightFailure then
			return nil, maxWidthFailure or maxHeightFailure
		end
		local alignSelf, selfFailure = alignment(physical, "align-self", "auto")
		if not alignSelf then
			return nil, selfFailure
		end
		local resolveIntrinsic = item.resolveIntrinsic
		local basis: number? = nil
		local contentBasis = false
		if resolveIntrinsic then
			local basisFailure: string?
			basis, contentBasis, basisFailure = flexBasis(
				physical,
				options,
				mainBasis,
				if horizontal then metrics.horizontalInset else metrics.verticalInset,
				borderBox
			)
			if basisFailure then
				return nil, basisFailure
			end
			local effective = if alignSelf == "auto" then alignItems else alignSelf
			local stretches = context.widthDefinite ~= false
				and (effective == "normal" or effective == "stretch")
				and not metrics.margin.left.auto
				and not metrics.margin.right.auto
			local inlineSizeRequired = ratio ~= nil or fitWidth
			if horizontal then
				local minimumTokens = values["min-width"]
				if not minimumTokens or word(minimumTokens) == "auto" then
					local minimum, failure = automaticMinimum(
						physical,
						item.autoMinWidth,
						item.minContentWidth,
						width,
						maxWidth,
						nil,
						nil,
						nil
					)
					if failure then
						return nil, failure
					end
					inlineSizeRequired = inlineSizeRequired or minimum == nil
				end
				inlineSizeRequired = inlineSizeRequired
					or (basis == nil and (contentBasis or width == nil) and item.flexBase == nil)
			else
				inlineSizeRequired = inlineSizeRequired or width == nil and not stretches
			end
			local input, failure = resolveIntrinsic(inlineSizeRequired)
			if failure == "pending-text-measurement" then
				pending = true
				continue
			elseif failure then
				return nil, failure
			end
			if input then
				local resolved = table.clone(item)
				resolved.autoMinWidth = item.autoMinWidth or input.autoMinWidth
				resolved.autoMinHeight = item.autoMinHeight or input.autoMinHeight
				resolved.minContentWidth = item.minContentWidth or input.minContentWidth
				resolved.maxContentWidth = item.maxContentWidth or input.maxContentWidth
				resolved.minContentHeight = item.minContentHeight or input.minContentHeight
				resolved.flexBase = item.flexBase or input.flexBase
				resolved.hypotheticalCrossSize = item.hypotheticalCrossSize or input.hypotheticalCrossSize
				resolved.measure = item.measure or input.measure
				item = resolved
			end
			if item.flexBase ~= nil and not finite(item.flexBase) then
				return nil, "invalid-measured-flex-base"
			end
			if item.hypotheticalCrossSize ~= nil and not finite(item.hypotheticalCrossSize) then
				return nil, "invalid-hypothetical-cross-size"
			end
		end
		if fitWidth then
			local minimum, maximum = item.minContentWidth, item.maxContentWidth
			if minimum == nil or maximum == nil then
				return nil, "fit-content-inline-contributions-required"
			end
			if not finite(minimum) or not finite(maximum) or maximum < minimum then
				return nil, "invalid-fit-content-inline-contributions"
			end
			local available = if widthBasis then math.max(0, widthBasis - metrics.margin.left.value - metrics.margin.right.value) else maximum
			width = math.min(maximum, math.max(minimum, available))
		end
		if not horizontal and not ratio and item.measure and (item.flexBase == nil or item.minContentHeight == nil) then
			local crossMinimum, crossFailure =
				dimension(physical, "min-width", "auto", options, widthBasis, metrics.horizontalInset, borderBox, 0)
			if crossMinimum == nil then
				return nil, crossFailure
			end
			local available = math.max(0, context.width - metrics.margin.left.value - metrics.margin.right.value)
			local effective = if alignSelf == "auto" then alignItems else alignSelf
			local cross = width
			if cross == nil then
				if
					(effective == "normal" or effective == "stretch")
					and not metrics.margin.left.auto
					and not metrics.margin.right.auto
				then
					cross = available
				elseif item.minContentWidth ~= nil and item.maxContentWidth ~= nil then
					if
						not finite(item.minContentWidth)
						or not finite(item.maxContentWidth)
						or item.maxContentWidth < item.minContentWidth
					then
						return nil, "invalid-column-inline-intrinsics"
					end
					cross = math.max(item.minContentWidth, math.min(available, item.maxContentWidth))
				else
					cross = item.hypotheticalCrossSize
				end
			end
			if cross == nil then
				return nil, "column-content-inline-size-required"
			end
			cross = math.max(metrics.horizontalInset, crossMinimum, math.min(cross, maxWidth or math.huge))
			if not finite(cross) then
				return nil, "invalid-column-content-inline-size"
			end
			local measured, measureFailure = measureHeight(
				item.measure,
				cross - metrics.horizontalInset,
				metrics.verticalInset,
				"flex-main-measurement"
			)
			if measureFailure == "pending-text-measurement" then
				pending = true
				continue
			elseif measured == nil then
				return nil, measureFailure
			end
			item = table.clone(item)
			item.minContentHeight = item.minContentHeight or measured
			item.flexBase = item.flexBase or measured
			item.hypotheticalCrossSize = cross
		end
		local transferred: number? = nil
		local ratioMinimum: number? = nil
		local ratioMaximum: number? = nil
		local ratioBaseCross: number? = nil
		local crossAutomatic: number? = 0
		if ratio then
			local crossProperty = if horizontal then "height" else "width"
			local crossInset = if horizontal then metrics.verticalInset else metrics.horizontalInset
			local crossBasis = if horizontal then heightBasis else widthBasis
			local crossPreferred = if horizontal then height else width
			local crossMaximum = if horizontal then maxHeight else maxWidth
			local crossMinProperty = `min-{crossProperty}`
			local crossMinimum, crossFailure =
				dimension(physical, crossMinProperty, "auto", options, crossBasis, crossInset, borderBox, 0)
			if crossMinimum == nil then
				return nil, crossFailure
			end
			local minTokens = values[crossMinProperty]
			if
				minTokens
				and word(minTokens) ~= "auto"
				and not (crossBasis == nil and Measurements.hasPercentage(minTokens))
			then
				local failure: string?
				ratioMinimum, failure = AspectRatio.transferOuter(ratio, crossMinimum, crossProperty, metrics, false)
				if ratioMinimum == nil then
					return nil, failure
				end
			end
			if crossMaximum ~= nil then
				local failure: string?
				ratioMaximum, failure = AspectRatio.transferOuter(ratio, crossMaximum, crossProperty, metrics, false)
				if ratioMaximum == nil then
					return nil, failure
				end
			end
			if crossPreferred ~= nil then
				ratioBaseCross = math.max(crossInset, crossMinimum, math.min(crossPreferred, crossMaximum or math.huge))
				local failure: string?
				transferred, failure = AspectRatio.transferOuter(ratio, ratioBaseCross, crossProperty, metrics)
				if transferred == nil then
					return nil, failure
				end
			else
				local minimumFailure: string? = nil
				if not minTokens or word(minTokens) == "auto" then
					local authoritative = if horizontal then item.autoMinHeight else item.autoMinWidth
					local scrollable, overflowFailure = scrollableOverflow(physical)
					if scrollable == nil then
						return nil, overflowFailure
					end
					if item.measure and authoritative == nil and not scrollable then
						return nil, "ratio-width-sensitive-intrinsic-minimum-provider-required"
					end
					crossAutomatic, minimumFailure = automaticMinimum(
						physical,
						authoritative,
						if horizontal then item.minContentHeight else item.minContentWidth,
						nil,
						crossMaximum,
						nil,
						nil,
						nil
					)
				end
				if minimumFailure then
					return nil, minimumFailure
				end
				-- A definite single-line stretch size can determine a content
				-- flex base; it is not a preferred-size minimum suggestion.
				local effective = if alignSelf == "auto" then alignItems else alignSelf
				local a, b =
					if horizontal then metrics.margin.top else metrics.margin.left,
					if horizontal then metrics.margin.bottom else metrics.margin.right
				if
					not autoCross
					and (not horizontal or context.heightDefinite ~= false)
					and (horizontal or context.widthDefinite ~= false)
					and (effective == "stretch" or effective == "normal")
					and not a.auto
					and not b.auto
				then
					if not crossAutomatic and (not minTokens or word(minTokens) == "auto") then
						return nil, "ratio-cross-content-minimum-required"
					end
					ratioBaseCross = math.max(
						crossInset,
						crossMinimum,
						crossAutomatic or 0,
						math.min(
							(if horizontal then context.height else context.width) - a.value - b.value,
							crossMaximum or math.huge
						)
					)
				end
			end
		end
		local automatic: number? = nil
		local minimumTokens = values[if horizontal then "min-width" else "min-height"]
		if not minimumTokens or word(minimumTokens) == "auto" then
			local automaticFailure: string?
			automatic, automaticFailure = automaticMinimum(
				physical,
				if horizontal then item.autoMinWidth else item.autoMinHeight,
				(if horizontal then item.minContentWidth else item.minContentHeight)
					or (if not item.replaced then 0 else nil),
				if horizontal then width else height,
				if horizontal then maxWidth else maxHeight,
				transferred,
				ratioMinimum,
				ratioMaximum
			)
			if automaticFailure then
				return nil, automaticFailure
			end
		end
		local minWidth, minWidthFailure = dimension(
			physical,
			"min-width",
			"auto",
			options,
			widthBasis,
			metrics.horizontalInset,
			borderBox,
			if horizontal then automatic else crossAutomatic or 0
		)
		local minHeight, minHeightFailure = dimension(
			physical,
			"min-height",
			"auto",
			options,
			heightBasis,
			metrics.verticalInset,
			borderBox,
			if horizontal then crossAutomatic or 0 else automatic
		)
		if minWidth == nil or minHeight == nil then
			return nil, minWidthFailure or minHeightFailure
		end
		local grow, growFailure = number(physical, "flex-grow", 0)
		local shrink, shrinkFailure = number(physical, "flex-shrink", 1)
		if grow == nil or shrink == nil then
			return nil, growFailure or shrinkFailure
		end
		if not resolveIntrinsic then
			local failure: string?
			basis, contentBasis, failure = flexBasis(
				physical,
				options,
				mainBasis,
				if horizontal then metrics.horizontalInset else metrics.verticalInset,
				borderBox
			)
			if failure then
				return nil, failure
			end
		end
		if contentBasis then
			if horizontal then
				width = nil
			else
				height = nil
			end
		end
		local flexBase = item.flexBase
		if ratio and ratioBaseCross ~= nil and basis == nil and (if horizontal then width else height) == nil then
			local failure: string?
			flexBase, failure = AspectRatio.transferOuter(
				ratio,
				ratioBaseCross,
				if horizontal then "height" else "width",
				metrics,
				false
			)
			if flexBase == nil then
				return nil, failure
			end
		end
		table.insert(prepared.items, {
			ratio = ratio,
			node = item.node,
			metrics = metrics,
			width = width,
			height = height,
			minWidth = minWidth,
			minHeight = minHeight,
			maxWidth = maxWidth,
			maxHeight = maxHeight,
			grow = grow,
			shrink = shrink,
			basis = basis,
			mainDefinite = basis ~= nil or (if horizontal then width else height) ~= nil or ratioBaseCross ~= nil,
			alignSelf = alignSelf,
			measure = item.measure,
			flexBase = flexBase,
			hypotheticalCrossSize = item.hypotheticalCrossSize,
		})
	end
	return if pending then nil else prepared, if pending then "pending-text-measurement" else nil
end

local function margin(item: FlexTypes.PreparedItem, side: string): number
	local value = item.metrics.margin[side]
	return if value.auto then 0 else value.value
end

local function hypotheticalCross(item: FlexTypes.PreparedItem, main: number, horizontal: boolean): (number?, string?)
	local inset = if horizontal then item.metrics.verticalInset else item.metrics.horizontalInset
	local minimum = if horizontal then item.minHeight else item.minWidth
	local maximum = if horizontal then item.maxHeight else item.maxWidth
	local cross = if horizontal then item.height else item.width
	if cross == nil then
		local measure = item.measure
		if item.ratio then
			local failure: string?
			cross, failure =
				AspectRatio.transferOuter(item.ratio, main, if horizontal then "width" else "height", item.metrics)
			if cross == nil then
				return nil, failure
			end
		elseif horizontal and measure then
			local measured, reason = measureHeight(
				measure,
				math.max(0, main - item.metrics.horizontalInset),
				inset,
				"flex-cross-measurement"
			)
			if measured == nil then
				return nil, reason
			end
			cross = measured
		else
			cross = item.hypotheticalCrossSize
		end
	end
	if cross == nil then
		return nil, "measured-hypothetical-cross-size-required"
	end
	if not finite(cross) then
		return nil, "invalid-flex-cross-size"
	end
	return math.max(inset, minimum, math.min(cross, maximum or math.huge)), nil
end

function FlexSizing.resolve(
	style: Types.ComputedStyle,
	items: { FlexTypes.Item },
	context: FlexTypes.Context
): ({ FlexTypes.UsedItem }?, string?, number?)
	if context.widthDefinite == false then
		return nil, "definite-flex-content-size-required", nil
	end
	local prepared, failure = FlexSizing.prepare(style, items, context)
	if not prepared then
		return nil, failure, nil
	end
	local horizontal = prepared.flow == "row" or prepared.flow == "row-reverse"
	local lengths: { FlexibleLengths.Item } = {}
	for _, item in prepared.items do
		local preferred = if horizontal then item.width else item.height
		local base = item.basis or preferred or item.flexBase
		if base == nil then
			return nil, "measured-flex-base-required", nil
		end
		table.insert(lengths, {
			base = base,
			inset = if horizontal then item.metrics.horizontalInset else item.metrics.verticalInset,
			minimum = if horizontal then item.minWidth else item.minHeight,
			maximum = if horizontal then item.maxWidth else item.maxHeight,
			margin = if horizontal
				then margin(item, "left") + margin(item, "right")
				else margin(item, "top") + margin(item, "bottom"),
			grow = item.grow,
			shrink = item.shrink,
		})
	end
	local mainSize = if horizontal then prepared.width else prepared.height
	if prepared.autoMain then
		local natural = prepared.gap * math.max(0, #lengths - 1)
		for _, item in lengths do
			natural += math.max(item.inset, item.minimum, math.min(item.base, item.maximum or math.huge)) + item.margin
		end
		if natural ~= natural or math.abs(natural) >= math.huge then
			return nil, "nonfinite-flex-budget", nil
		end
		mainSize = math.max(0, prepared.minimumMain or 0, math.min(natural, prepared.maximumMain or math.huge))
	end
	local resolved, lengthFailure = FlexibleLengths.resolve(lengths, mainSize, prepared.gap)
	if not resolved then
		return nil, lengthFailure, nil
	end
	local lineCross = if horizontal then prepared.height else prepared.width
	local hypotheticals: { number } = {}
	local stretches: { boolean } = {}
	local pending = false
	if prepared.autoCross then
		lineCross = 0
	end
	for index, item in prepared.items do
		local alignment = if item.alignSelf == "auto" then prepared.alignItems else item.alignSelf
		local startSide, endSide = if horizontal then "top" else "left", if horizontal then "bottom" else "right"
		stretches[index] = (alignment == "stretch" or alignment == "normal")
			and not item.metrics.margin[startSide].auto
			and not item.metrics.margin[endSide].auto
		local crossPreferred = if horizontal then item.height else item.width
		if prepared.autoCross or (crossPreferred == nil and not stretches[index]) then
			local cross, crossFailure = hypotheticalCross(item, resolved[index], horizontal)
			if crossFailure == "pending-text-measurement" then
				pending = true
				continue
			elseif cross == nil then
				return nil, crossFailure, nil
			end
			hypotheticals[index] = cross
			if prepared.autoCross then
				lineCross = math.max(lineCross, cross + margin(item, "top") + margin(item, "bottom"))
			end
		end
	end
	if pending then
		return nil, "pending-text-measurement", nil
	end
	if prepared.autoCross then
		lineCross = math.max(prepared.minimumCross or 0, math.min(lineCross, prepared.maximumCross or math.huge))
		if not finite(lineCross) then
			return nil, "invalid-flex-line-cross-size", nil
		end
	end
	local used: { FlexTypes.UsedItem } = {}
	for index, item in prepared.items do
		local inset = if horizontal then item.metrics.verticalInset else item.metrics.horizontalInset
		local minimum = if horizontal then item.minHeight else item.minWidth
		local maximum = if horizontal then item.maxHeight else item.maxWidth
		local cross = if horizontal then item.height else item.width
		local crossDefinite = cross ~= nil or item.ratio ~= nil
		if cross == nil then
			local startSide, endSide = if horizontal then "top" else "left", if horizontal then "bottom" else "right"
			if stretches[index] then
				crossDefinite = true
				cross = lineCross - margin(item, startSide) - margin(item, endSide)
			else
				cross = hypotheticals[index]
			end
		end
		if cross == nil then
			return nil, "measured-hypothetical-cross-size-required", nil
		end
		if cross ~= cross or math.abs(cross) == math.huge then
			return nil, "invalid-flex-cross-size", nil
		end
		cross = math.max(inset, minimum, math.min(cross, maximum or math.huge))
		table.insert(used, {
			node = item.node,
			width = if horizontal then resolved[index] else cross,
			height = if horizontal then cross else resolved[index],
			widthDefinite = horizontal or crossDefinite,
			heightDefinite = if horizontal
				then crossDefinite
				else (not prepared.autoMain and context.heightDefinite ~= false) or item.mainDefinite == true,
		})
	end
	return used, nil, if horizontal then lineCross else mainSize
end

return FlexSizing
