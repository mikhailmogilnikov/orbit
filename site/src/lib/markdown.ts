/** Markdown from the repo (docs/, release notes) rendered for the site's pages. */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Marked } from "marked";
import { createHighlighter } from "shiki";
import { REPO } from "./release";

const LANGS = ["json", "toml", "bash", "swift", "typescript", "javascript", "text"];
const highlighter = await createHighlighter({ themes: ["github-light", "github-dark"], langs: LANGS });

export interface Heading {
  depth: number;
  text: string;
  slug: string;
}

const slugify = (text: string) =>
  text
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-");

/** HTML and its h2/h3 headings. Links to sibling docs go to GitHub, where they live. */
export function render(markdown: string) {
  const headings: Heading[] = [];
  const marked = new Marked({
    gfm: true,
    renderer: {
      heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens);
        const slug = slugify(text);
        if (depth === 2 || depth === 3) headings.push({ depth, text: text.replace(/<[^>]+>/g, ""), slug });
        return `<h${depth} id="${slug}">${text}</h${depth}>`;
      },
      code({ text, lang }) {
        const language = lang && LANGS.includes(lang) ? lang : "text";
        return highlighter.codeToHtml(text, {
          lang: language,
          themes: { light: "github-light", dark: "github-dark" },
          defaultColor: false,
        });
      },
      link({ href, tokens }) {
        const text = this.parser.parseInline(tokens);
        const url = /^([a-z]+:|#|\/)/i.test(href) ? href : `${REPO}/blob/master/docs/${href}`;
        return `<a href="${url}">${text}</a>`;
      },
    },
  });
  return { html: marked.parse(markdown, { async: false }), headings };
}

/** A file in the repo, from the site's folder (builds run there) */
export function repoFile(path: string) {
  return readFileSync(resolve(process.cwd(), "..", path), "utf8");
}
