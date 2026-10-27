--!strict

export type SelectorToken = {
	kind: string,
	value: string,
	attribute: string?,
	operator: string?,
	insensitive: boolean?,
	namespace: (string | boolean)?,
	children: { SelectorToken }?,
	nth: { a: number, b: number, of: { SelectorToken }? }?,
	nthError: string?,
}

export type Selector = {
	text: string,
	tokens: { SelectorToken },
	specificity: { number },
	-- Preparation-only target. Compiled selectors retain their original tokens.
	pseudoElement: string?,
}

export type RgbaColor = { r: number, g: number, b: number, alpha: number }

export type ValueToken = {
	kind: string,
	value: string,
	identifier: string?,
	children: { ValueToken }?,
	quote: string?,
	unit: string?,
	color: RgbaColor?,
	syntaxType: ("color" | "length")?,
}

export type RangeOperand = {
	kind: string,
	name: string?,
	tokens: { ValueToken }?,
}

export type ConditionExpression = {
	kind: string,
	queryKind: string?,
	name: string?,
	property: string?,
	text: string?,
	tokens: { ValueToken }?,
	operands: { ConditionExpression }?,
	operand: ConditionExpression?,
	rangeOperands: { RangeOperand }?,
	comparisons: { string }?,
	selectors: { Selector }?,
}

export type Source = { file: string, line: number, column: number }
export type Priority = {
	important: boolean,
	inline: boolean?,
	layer: { number },
	specificity: { number },
	order: number,
	logical: boolean?,
}

export type Declaration = {
	kind: "declaration",
	property: string,
	value: string,
	tokens: { ValueToken },
	important: boolean,
	validity: string?,
	shorthand: { property: string, target: string }?,
	priority: Priority?,
	cascadeOrder: number?,
	source: Source?,
}
export type Rollback = (string, Declaration, string) -> Declaration?
export type RemapCascade = ({ [string]: string }) -> ({ [string]: Declaration }, Rollback)

export type Rule = {
	kind: "rule",
	selectors: { Selector },
	children: { CssNode },
	source: Source?,
}

export type AtRule = {
	kind: "at-rule",
	name: string,
	params: string,
	tokens: { ValueToken },
	children: { CssNode }?,
	condition: ConditionExpression?,
	registration: CompiledRegistration?,
	keyframes: CompiledKeyframes?,
	source: Source?,
}

export type CompiledKeyframes = { status: "valid", name: string } | { status: "invalid", reason: string }

export type CompiledRegistration =
	{ status: "invalid", reason: string }
	| {
		status: "valid" | "unchecked",
		name: string,
		syntax: string,
		inherits: boolean,
		initial: { ValueToken }?,
		reason: string?,
		syntaxDefinition: PropertySyntax?,
	}

export type PropertySyntax = {
	universal: boolean,
	branches: { { kind: "type" | "keyword", name: string, list: "single" | "space" | "comma" } },
}

export type KeyframeStep = {
	kind: "keyframe-step",
	offsets: { string },
	positions: { number }?,
	children: { CssNode },
	source: Source?,
}

export type CssNode = Declaration | Rule | AtRule | KeyframeStep
export type PropertyMetadata = {
	inherited: boolean,
	initial: { ValueToken }?,
	initialText: string?,
	longhands: { string }?,
	animationType: (string | { string })?,
}
export type Stylesheet = { version: number, nodes: { CssNode }, properties: { [string]: PropertyMetadata }? }
export type InlineStyle = { declarations: { Declaration }, properties: { [string]: PropertyMetadata }? }

-- Logical nodes exclude backend-owned padding, strokes and decorative layers.
export type Node = {
	tag: string,
	nativeControl: ("auto" | "button")?,
	id: string?,
	className: string,
	classes: { [string]: boolean },
	attributes: { [string]: string },
	states: { [string]: boolean },
	text: string,
	textAfter: { [number]: string }?,
	inlineStyle: InlineStyle?,
	inlineCandidates: { CascadeCandidate }?,
	parent: Node?,
	children: { Node },
}

export type Diagnose = (code: string, detail: string, source: Source?) -> ()

export type Condition = { name: string, params: string, tokens: { ValueToken }, expression: ConditionExpression? }
export type MatchCondition = (condition: Condition, node: Node) -> boolean?

export type CascadeCandidate = {
	declaration: Declaration,
	priority: Priority,
	physical: CascadeCandidate?,
	logical: CascadeCandidate?,
}

export type PreparedRule = {
	selectors: { Selector },
	declarations: { Declaration },
	layer: { number },
	conditions: { Condition },
	-- Root-owned immutable candidate arrays, built lazily for a matched selector
	-- specificity. Manual prepared sheets can omit this cache.
	candidates: { [{ number }]: { CascadeCandidate } }?,
}

export type Registration = {
	inherits: boolean,
	initial: { ValueToken }?,
	syntax: string,
	syntaxDefinition: PropertySyntax?,
}
export type SelectorBuckets = {
	universal: { number },
	ids: { [string]: { number } },
	classes: { [string]: { number } },
	tags: { [string]: { number } },
}
export type SelectorIndex = {
	targets: { [string]: SelectorBuckets },
	declarationOffsets: { number },
}
export type PreparedKeyframe = { offset: number, declarations: { Declaration } }
export type PreparedKeyframes = {
	name: string,
	frames: { PreparedKeyframe },
	layer: { number },
	conditions: { Condition },
	source: Source?,
}
export type PreparedSheet = {
	rules: { PreparedRule },
	registrations: { [string]: Registration },
	properties: { [string]: PropertyMetadata },
	pseudoElements: { [string]: boolean }?,
	selectorIndex: SelectorIndex?,
	keyframes: { [string]: { PreparedKeyframes } }?,
}

export type ComputedStyle = {
	properties: { [string]: { ValueToken } },
	variables: { [string]: { ValueToken } },
	unresolvedVariables: { [string]: string }?,
	priorities: { [string]: Priority },
	unresolved: { [string]: string },
}

return {}
