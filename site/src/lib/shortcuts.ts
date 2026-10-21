/**
 * Orbit's default key shortcuts, read from the commands its plugins register (`OrbitCommand`
 * in the Swift sources), so the page never drifts from the app.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

export interface Shortcut {
  title: string;
  category: string;
  keys: string;
  /** Answered by the focused editor only, not a menu shortcut */
  editor: boolean;
}

const KEYS: Record<string, string> = {
  return: "↩",
  delete: "⌫",
  deleteForward: "⌦",
  upArrow: "↑",
  downArrow: "↓",
  leftArrow: "←",
  rightArrow: "→",
  tab: "⇥",
  escape: "⎋",
  space: "Space",
};
const MODIFIERS: [string, string][] = [
  ["control", "⌃"],
  ["option", "⌥"],
  ["shift", "⇧"],
  ["command", "⌘"],
];

function swiftFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    if (name.startsWith(".")) return [];
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return name.endsWith(".swift") ? [path] : [];
  });
}

/** The arguments of the call that starts at `from` (just past its "("), strings skipped */
function callArguments(source: string, from: number) {
  let depth = 1;
  let inString = false;
  for (let i = from; i < source.length; i++) {
    const c = source[i];
    if (inString) {
      if (c === "\\") i++;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
    else if (c === "(") depth++;
    else if (c === ")" && --depth === 0) return source.slice(from, i);
  }
  return "";
}

function keys(key: string, modifiers: string) {
  const literal = key.match(/^"((?:[^"\\]|\\.)*)"$/);
  let glyph: string | undefined;
  if (literal) glyph = literal[1].replace(/\\(.)/g, "$1").toUpperCase();
  else glyph = KEYS[key.replace(/^(KeyEquivalent)?\./, "")];
  if (!glyph) return undefined;
  const mods = MODIFIERS.filter(([name]) => new RegExp(`\\.${name}\\b`).test(modifiers)).map(([, g]) => g);
  return mods.join("") + glyph;
}

const SHORTCUT = (label: string) =>
  new RegExp(`(?<![\\w])${label}:\\s*KeyboardShortcut\\(\\s*([^,()]+?)\\s*(?:,\\s*modifiers:\\s*(\\[[^\\]]*\\]|\\.\\w+))?\\s*\\)`);

let cached: Shortcut[] | undefined;

export function shortcuts(): Shortcut[] {
  if (cached) return cached;
  const root = resolve(process.cwd(), "..");
  const files = [...swiftFiles(join(root, "App")), ...swiftFiles(join(root, "Packages/OrbitKit/Sources"))];
  const found: Shortcut[] = [];
  for (const file of files) {
    const source = readFileSync(file, "utf8");
    for (const match of source.matchAll(/OrbitCommand\(/g)) {
      const args = callArguments(source, match.index! + match[0].length);
      const title = args.match(/\btitle:\s*"((?:[^"\\]|\\.)*)"/)?.[1];
      const category = args.match(/\bcategory:\s*"([^"]*)"/)?.[1];
      if (!title || !category || title.startsWith("Debug:")) continue;
      for (const [label, editor] of [
        ["shortcut", false],
        ["editorShortcut", true],
      ] as const) {
        const m = args.match(SHORTCUT(label));
        const k = m && keys(m[1], m[2] ?? ".command");
        if (k) found.push({ title: title.replace(/\\(.)/g, "$1"), category, keys: k, editor });
      }
    }
  }
  const seen = new Set<string>();
  cached = found.filter((s) => {
    const id = `${s.title}|${s.keys}`;
    return seen.has(id) ? false : (seen.add(id), true);
  });
  return cached;
}
