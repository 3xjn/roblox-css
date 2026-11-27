import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileCss, inventoryStylesheet } from '../../../roblox-css-compiler/dist/index.js';

const dir = path.dirname(fileURLToPath(import.meta.url));
const css = fs.readFileSync(path.join(dir, 'styles.css'), 'utf8');
const stylesheet = await compileCss(css, { from: 'styles.css' });
const inventory = inventoryStylesheet(stylesheet);

const outDir = path.join(dir, 'generated');
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'Stylesheet.json'), JSON.stringify(stylesheet, null, 2));

console.log(JSON.stringify({
  rules: inventory.rules,
  declarations: inventory.declarations,
}));
