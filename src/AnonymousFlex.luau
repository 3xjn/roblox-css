--!strict

local Types = require(script.Parent.Types)
local SceneTypes = require(script.Parent.SceneTypes)
local FlexTypes = require(script.Parent.FlexTypes)
local BoxModel = require(script.Parent.BoxModel)
local Measurements = require(script.Parent.Measurements)
local Whitespace = require(script.Parent.Whitespace)
local TextLine = require(script.Parent.TextLine)
local TextParagraph = require(script.Parent.TextParagraph)
local Fonts = require(script.Parent.Fonts)
local Typography = require(script.Parent.Typography)
local TextIntrinsic = require(script.Parent.TextIntrinsic)

export type Options = {
	fonts: Fonts.Provider?,
	geometry: TextLine.GeometryProvider?,
	nativeTextLine: boolean?,
	fontMetrics: Typography.MetricsProvider?,
}
export type Prepared = {
	item: FlexTypes.Item,
	atoms: { Whitespace.Atom },
	style: Types.ComputedStyle,
	lengths: Measurements.Context,
}
local AnonymousFlex = {}

function AnonymousFlex.prepare(
	owner: Types.Node,
	node: Types.Node,
	snapshot: SceneTypes.Snapshot,
	options: Options,
	getLengths: (Types.ComputedStyle) -> Measurements.Context,
	width: number,
	horizontal: boolean,
	text: string?
): (Prepared?, string?)
	if not snapshot.anonymousStyle then
		return nil, "anonymous-style-provider-required"
	end
	if not options.fonts then
		return nil, "anonymous-text-font-provider-required"
	end
	local style, styleFailure = snapshot.anonymousStyle(owner)
	if not style then
		return nil, styleFailure
	end
	style.properties.display = { { kind = "word", value = "block" } }
	local policy, policyFailure = Whitespace.resolve(style)
	if not policy then
		return nil, policyFailure
	end
	local atoms, atomFailure = Whitespace.process({ { source = node, text = text or owner.text, policy = policy } })
	if not atoms then
		return nil, atomFailure
	end
	local lengths = getLengths(style)
	local metrics, metricFailure = BoxModel.resolveMetrics(style, { lengths = lengths, containingInlineSize = width })
	if not metrics then
		return nil, metricFailure
	end
	if policy.wrap == "wrap" then
		local intrinsic, failure = TextIntrinsic.resolve(node, style, atoms, {
			width = 0,
			fonts = options.fonts,
			fontMetrics = if options.fontMetrics then options.fontMetrics(style) else options.fonts:getMetrics(style),
			measureText = snapshot.measureText,
			geometry = options.geometry,
			nativeTextLine = options.nativeTextLine,
		})
		if not intrinsic then
			return nil, failure
		end
		return {
			item = {
				node = node,
				style = style,
				metrics = metrics,
				lengths = lengths,
				minContentWidth = intrinsic.minimum + metrics.horizontalInset,
				maxContentWidth = intrinsic.maximum + metrics.horizontalInset,
				flexBase = if horizontal then intrinsic.maximum + metrics.horizontalInset else nil,
				measure = intrinsic.measure,
			},
			atoms = atoms,
			style = style,
			lengths = lengths,
		},
			nil
	end
	local line, lineFailure = TextParagraph.resolve(node, style, atoms, {
		width = 0,
		fonts = options.fonts,
		fontMetrics = if options.fontMetrics then options.fontMetrics(style) else options.fonts:getMetrics(style),
		measureText = snapshot.measureText,
		geometry = options.geometry,
		nativeTextLine = options.nativeTextLine,
	})
	if not line then
		return nil, lineFailure
	end
	return {
		item = {
			node = node,
			style = style,
			metrics = metrics,
			lengths = lengths,
			minContentWidth = line.advance + metrics.horizontalInset,
			minContentHeight = line.height + metrics.verticalInset,
			flexBase = if horizontal
				then line.advance + metrics.horizontalInset
				else line.height + metrics.verticalInset,
			hypotheticalCrossSize = if horizontal
				then line.height + metrics.verticalInset
				else line.advance + metrics.horizontalInset,
		},
		atoms = atoms,
		style = style,
		lengths = lengths,
	},
		nil
end

function AnonymousFlex.layout(
	prepared: Prepared,
	owner: Types.Node,
	size: FlexTypes.UsedItem,
	snapshot: SceneTypes.Snapshot,
	options: Options,
	parent: SceneTypes.Key,
	rank: number
): (SceneTypes.Box?, string?)
	if not options.fonts then
		return nil, "anonymous-text-font-provider-required"
	end
	local metrics = prepared.item.metrics
	local line, failure = TextParagraph.resolve(size.node, prepared.style, prepared.atoms, {
		width = math.max(0, size.width - metrics.horizontalInset),
		fonts = options.fonts,
		fontMetrics = if options.fontMetrics
			then options.fontMetrics(prepared.style)
			else options.fonts:getMetrics(prepared.style),
		measureText = snapshot.measureText,
		geometry = options.geometry,
		nativeTextLine = options.nativeTextLine,
	})
	if not line then
		return nil, failure
	end
	return {
		node = size.node,
		owner = owner,
		parent = parent,
		kind = "box",
		x = 0,
		y = 0,
		width = size.width,
		height = size.height,
		metrics = metrics,
		lengths = prepared.lengths,
		baselines = if line.baselines
			then {
				first = if line.baselines.first ~= nil
					then metrics.border.top + metrics.padding.top + line.baselines.first
					else nil,
				last = if line.baselines.last ~= nil
					then metrics.border.top + metrics.padding.top + line.baselines.last
					else nil,
			}
			else nil,
		runs = line.runs,
		zIndex = rank,
	},
		nil
end

return AnonymousFlex
