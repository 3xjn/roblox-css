/** Initial consumer declarations for the existing default scene. Not all low-level APIs are declared yet. */
export interface ValueToken {
  readonly kind: string;
  readonly value: string;
  readonly identifier?: string;
  readonly unit?: string;
  readonly quote?: string;
  readonly syntaxType?: 'color' | 'length';
  readonly color?: { readonly r: number; readonly g: number; readonly b: number; readonly alpha: number };
  readonly children?: readonly ValueToken[];
}

export interface PropertyMetadata {
  readonly inherited: boolean;
  readonly initialText?: string;
  readonly initial?: readonly ValueToken[];
  readonly longhands?: readonly string[];
  readonly animationType?: string | readonly string[];
}

/** Compiled declaration IR; raw CSS strings and React.CSSProperties are not accepted. */
export interface InlineStyle {
  readonly declarations: readonly {
    readonly kind: 'declaration';
    readonly property: string;
    readonly value: string;
    readonly tokens: readonly ValueToken[];
    readonly important: boolean;
    readonly validity?: string;
    readonly source?: { readonly file: string; readonly line: number; readonly column: number };
  }[];
  readonly properties?: Readonly<Record<string, PropertyMetadata>>;
}

export interface Stylesheet {
  readonly version: number;
  readonly nodes: readonly unknown[];
  readonly properties?: Readonly<Record<string, unknown>>;
}

export interface FontMetrics {
  readonly ex?: number;
  readonly ch?: number;
  readonly cap?: number;
  readonly ic?: number;
  readonly normalLineHeight?: number;
  readonly ascent?: number;
  readonly descent?: number;
}

/** Feature values already satisfied by the supplied font; never inferred from its name. */
export type FontFeatureDefaults = Readonly<Record<string, number>>;
export interface FontRegistrationOptions {
  readonly defaultFeatures?: FontFeatureDefaults;
}
export interface FontFace {
  readonly font: Font;
  readonly weight?: number;
  readonly style?: string;
  readonly metrics?: FontMetrics;
  readonly defaultFeatures?: FontFeatureDefaults;
}
export interface FontProvider {
  register(family: string, font: Font | Enum.Font, metrics?: FontMetrics, options?: FontRegistrationOptions): () => void;
  registerFaces(family: string, faces: readonly FontFace[]): () => void;
  subscribe(listener: () => void): () => void;
}

export interface TextShape {
  readonly font: Font;
  readonly size: number;
  readonly features?: string;
  readonly direction?: string;
}

export interface TextGeometry {
  readonly advance: number;
  readonly ascent: number;
  readonly descent: number;
  readonly nativeBaseline: number;
  readonly nativeHeight: number;
}

export interface ImageNode {
  readonly tag: string;
  readonly attributes: Readonly<Record<string, string>>;
}

export type ImageSource = string | Content;

export interface ImageData {
  readonly source: ImageSource;
  readonly natural?: { readonly width?: number; readonly height?: number; readonly ratio?: number };
  /** Monochrome content uses the logical node's computed CSS color and alpha. */
  readonly useCurrentColor?: boolean;
}

export type ImageProvider = (node: ImageNode) => LuaTuple<[ImageData | undefined, string | undefined]>;
export interface ImageProviderInputs {
  readonly attributes: readonly string[];
  readonly states: readonly string[];
}

export interface HostOptions {
	/** Optional cooperative preparation budget; zero/omission preserves ordinary scheduling. */
	readonly workBudgetMs?: number;
  /** Opt-in inclusive phase timings and matching Roblox MicroProfiler markers. */
  readonly onProfile?: (sample: { readonly phase: string; readonly seconds: number; readonly succeeded: boolean }) => void;
  readonly styles?: {
    readonly fonts?: FontProvider;
    readonly fontMetrics?: (style: ComputedValueStyle) => FontMetrics | undefined;
    readonly displayDefaults?: Readonly<Record<string, string>>;
    readonly onDiagnostic?: (code: string, detail: string, source?: unknown) => void;
  };
  readonly nativeTextLine?: boolean;
  /** Existing intrinsic provider, also consulted inside supported block/flex wrappers. */
  readonly flexIntrinsic?: IntrinsicProvider;
  /** Measured native editor baselines at used geometry, requested only by inline layout. */
  readonly editorBaselines?: EditorBaselineProvider;
  readonly textGeometry?: (style: unknown, text: string, shape: TextShape, bounds: Vector2) => LuaTuple<[TextGeometry | undefined, string | undefined]>;
  readonly getViewport?: (mount: Frame) => Vector2;
  readonly imageSource?: ImageProvider;
  /** Paint a passive CSS leaf without replacing its CSS sizing/tag identity. */
  readonly imageContentSource?: ImageProvider;
  readonly imageSourceInputs?: ImageProviderInputs;
  readonly imageContentSourceInputs?: ImageProviderInputs;
}

/** Computed token inputs shared by value resolvers. */
export interface ComputedValueStyle {
  readonly properties: Readonly<Record<string, readonly ValueToken[]>>;
  readonly unresolved: Readonly<Record<string, string>>;
}

export interface IntrinsicNode extends ImageNode {
  readonly nativeControl?: 'auto' | 'button';
  readonly id?: string;
  readonly className: string;
  readonly text: string;
  /** Text after each element child, keyed by its one-based child index. */
  readonly textAfter?: Readonly<Record<number, string>>;
  readonly states: Readonly<Record<string, boolean>>;
  readonly parent?: IntrinsicNode;
  readonly children: readonly IntrinsicNode[];
}
export interface IntrinsicBoxMetrics {
  readonly boxSizing: string;
  readonly padding: Readonly<Record<string, number>>;
  readonly border: Readonly<Record<string, number>>;
  readonly margin: Readonly<Record<string, { readonly auto: boolean; readonly value: number }>>;
  readonly horizontalInset: number;
  readonly verticalInset: number;
}
export interface IntrinsicRequest {
  readonly node: IntrinsicNode;
  readonly style: ComputedValueStyle;
  readonly metrics: IntrinsicBoxMetrics;
  readonly lengths: MeasurementContext;
  /** Low-level scene snapshot; its wider API is not declared by this consumer surface. */
  readonly snapshot: unknown;
  readonly width: number;
  /** False: width is scratch zero for intrinsic contribution, not a percentage basis. */
  readonly widthDefinite?: boolean;
  readonly height?: number;
  readonly flow: string;
  readonly inlineSizeRequired?: boolean;
}
export interface IntrinsicConstraints {
  readonly width?: number;
  readonly height?: number;
  readonly widthMode: 'undefined' | 'exactly' | 'at-most';
  readonly heightMode: 'undefined' | 'exactly' | 'at-most';
}
export interface IntrinsicSize { readonly width: number; readonly height: number }
export interface IntrinsicData {
  readonly autoMinWidth?: number;
  readonly autoMinHeight?: number;
  readonly minContentWidth?: number;
  readonly maxContentWidth?: number;
  readonly minContentHeight?: number;
  readonly flexBase?: number;
  readonly hypotheticalCrossSize?: number;
  readonly measure?: (constraints: IntrinsicConstraints) => LuaTuple<[IntrinsicSize | undefined, string | undefined]>;
}
/** Border-box intrinsic data. Nil/nil declines; missing geometry is never synthesized. */
export type IntrinsicProvider = (request: IntrinsicRequest) => LuaTuple<[IntrinsicData | undefined, string | undefined]>;

export interface BaselineSet {
  /** Offsets from the used border-box top in CSS pixels; missing edges stay unknown. */
  readonly first?: number;
  readonly last?: number;
}
export interface EditorData {
  readonly value?: string;
  readonly defaultValue?: string;
  readonly placeholder?: string;
  readonly multiline?: boolean;
}
export interface EditorBaselineRequest {
  readonly node: IntrinsicNode;
  readonly style: ComputedValueStyle;
  readonly metrics: IntrinsicBoxMetrics;
  readonly geometry: TransformGeometry & { readonly paddingWidth: number; readonly paddingHeight: number };
  /** Committed setup props; defaultValue is not the current uncontrolled native text. */
  readonly editor: EditorData;
}
/** Uses application calibration; no baseline is inferred from text bounds or font size. */
export type EditorBaselineProvider = (request: EditorBaselineRequest) => LuaTuple<[BaselineSet | undefined, string | undefined]>;
export type AnimationStyle = ComputedValueStyle;

export type Easing =
  | { readonly kind: 'bezier'; readonly x1: number; readonly y1: number; readonly x2: number; readonly y2: number }
  | { readonly kind: 'steps'; readonly count: number; readonly jump: 'start' | 'end' | 'none' | 'both' }
  | { readonly kind: 'linear'; readonly points: readonly { readonly input: number; readonly output: number }[] };

export interface AnimationConfig {
  readonly index: number;
  /** Undefined represents an unquoted none entry; a quoted "none" keeps its name. */
  readonly name?: string;
  readonly duration: number;
  readonly delay: number;
  /** Infinity represents the CSS infinite keyword. */
  readonly iterations: number;
  readonly direction: 'normal' | 'reverse' | 'alternate' | 'alternate-reverse';
  readonly fill: 'none' | 'forwards' | 'backwards' | 'both';
  readonly paused: boolean;
  readonly easing: Easing;
}

export interface Keyframes {
  readonly name: string;
  readonly frames: readonly { readonly offset: number; readonly declarations: InlineStyle['declarations'] }[];
  readonly layer: readonly number[];
  readonly conditions: readonly unknown[];
  readonly source?: { readonly file: string; readonly line: number; readonly column: number };
}

export interface AnimationTracks {
  readonly name: string;
  readonly properties: Readonly<Record<string, {
    readonly property: string;
    /** Author important declarations mask animation-origin output. */
    readonly blocked: boolean;
    readonly frames: readonly {
      readonly offset: number;
      readonly tokens?: readonly ValueToken[];
      /** Missing endpoints use the current underlying effect-stack value. */
      readonly underlying: boolean;
      readonly easing: Easing;
      readonly unresolved?: string;
    }[];
  }>>;
}

export type AnimationTrack = AnimationTracks['properties'][string];
export type AnimationFrame = AnimationTrack['frames'][number];
export interface AnimationInterval {
  readonly start: AnimationFrame;
  readonly finish: AnimationFrame;
  readonly progress: number;
}

export declare const Animation: {
  readonly resolve: (style: AnimationStyle) => LuaTuple<[readonly AnimationConfig[] | undefined, string | undefined]>;
  /** Pure time mapping. Playback supplies a held localTime when paused. Easing belongs to keyframe intervals. */
  readonly sample: (config: AnimationConfig, localTime?: number) => LuaTuple<[AnimationSample | undefined, string | undefined]>;
  readonly interval: (track: AnimationTrack, progress: number, before?: boolean) => LuaTuple<[AnimationInterval | undefined, string | undefined]>;
};

export interface AnimationSample {
  readonly phase: 'idle' | 'before' | 'active' | 'after';
  readonly activeTime?: number;
  readonly iteration?: number;
  /** Directed iteration progress, before applying per-keyframe easing. */
  readonly progress?: number;
  readonly before?: boolean;
}

export interface TransformGeometry {
  readonly width: number;
  readonly height: number;
  readonly contentX: number;
  readonly contentY: number;
  readonly contentWidth: number;
  readonly contentHeight: number;
}

/** Committed CSS border/content boxes before native transforms or encoding. */
export interface BoxGeometry extends TransformGeometry {
  readonly paddingWidth: number;
  readonly paddingHeight: number;
}

export interface MeasurementContext {
  readonly fontSize?: number;
  readonly rootFontSize?: number;
  readonly lineHeight?: number;
  readonly rootLineHeight?: number;
  readonly viewportWidth?: number;
  readonly viewportHeight?: number;
  readonly percentageBasis?: number;
  readonly percentageDimension?: string;
  readonly strictPercentageTypes?: boolean;
  readonly allowLengthPercentage?: boolean;
  readonly allowRatio?: boolean;
  readonly units?: Readonly<Record<string, number>>;
  readonly mathRange?: { readonly minimum?: number; readonly maximum?: number };
}

export interface TranslationResult {
  readonly x: number;
  readonly y: number;
  readonly establishesContext: boolean;
}

export interface Transform2DResult extends TranslationResult {
  /** Native degrees; omitted on the existing translation path means zero. */
  readonly rotation?: number;
  /** Nonnegative uniform native scale; omitted means one. */
  readonly scale?: number;
}

export declare const Transform: {
  readonly resolveTranslation: (style: ComputedValueStyle, geometry: TransformGeometry, units: MeasurementContext) => LuaTuple<[TranslationResult | undefined, string | undefined]>;
  readonly resolve2D: (style: ComputedValueStyle, geometry: TransformGeometry, units: MeasurementContext) => LuaTuple<[Transform2DResult | undefined, string | undefined]>;
};
