# Plain CSS example (no Tailwind)

Standalone example using `@3xjn/roblox-css-compiler` and `@3xjn/roblox-css` with ordinary CSS rules, custom properties (`:root`), `:hover`/`:active`, and `[data-state="..."]` attribute selectors.

- **[styles.css](styles.css)** — Plain CSS stylesheet.
- **[PlainCssDemo.client.luau](PlainCssDemo.client.luau)** — Raw Roblox Luau client script (no React, no Tailwind).
- **[StatusCard.tsx](StatusCard.tsx)** — Equivalent TSX component using plain CSS classes and `data-state`.

## Build and open in Studio

```sh
node examples/plain-css/build.mjs
rojo build examples/plain-css/place.project.json --output examples/plain-css/generated/demo.rbxlx
```

Open `examples/plain-css/generated/demo.rbxlx` in Roblox Studio and start Play.
