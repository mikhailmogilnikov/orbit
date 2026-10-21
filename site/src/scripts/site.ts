import { segmented } from "./segmented";

const root = document.documentElement;

// ── Theme: auto follows the system; light and dark are remembered ──

const THEMES = ["auto", "light", "dark"] as const;
const THEME_LABELS = { auto: "match system", light: "light", dark: "dark" };
type Theme = (typeof THEMES)[number];

const themeControls = [...document.querySelectorAll<HTMLElement>("[data-theme-switch]")].map((seg) =>
  segmented(seg, (value) => setTheme(value as Theme)),
);
const themeCycles = [...document.querySelectorAll<HTMLButtonElement>("[data-theme-cycle]")];

/** One theme for the page, mirrored on every switch: the segmented one and the phone's cycle button */
function setTheme(theme: Theme) {
  if (theme === "auto") delete root.dataset.theme;
  else root.dataset.theme = theme;
  try {
    if (theme === "auto") localStorage.removeItem("orbit-theme");
    else localStorage.setItem("orbit-theme", theme);
  } catch {}
  for (const control of themeControls) control.select(theme, true);
  for (const button of themeCycles) {
    button.dataset.current = theme;
    button.setAttribute("aria-label", `Theme: ${THEME_LABELS[theme]}`);
  }
}

for (const button of themeCycles) {
  button.addEventListener("click", () => {
    const current = (root.dataset.theme ?? "auto") as Theme;
    setTheme(THEMES[(THEMES.indexOf(current) + 1) % THEMES.length]);
  });
}
setTheme((root.dataset.theme ?? "auto") as Theme);

// ── Reveal on scroll ──

const reveal = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("is-in");
      reveal.unobserve(entry.target);
    }
  },
  { rootMargin: "0px 0px -8% 0px" },
);
for (const el of document.querySelectorAll(".reveal")) reveal.observe(el);

// ── Copy buttons ──

document.addEventListener("click", async (event) => {
  const button = (event.target as Element).closest<HTMLButtonElement>("[data-copy]");
  if (!button) return;
  try {
    await navigator.clipboard.writeText(button.dataset.copy ?? "");
  } catch {
    return;
  }
  button.classList.add("is-copied");
  window.setTimeout(() => button.classList.remove("is-copied"), 1600);
});
