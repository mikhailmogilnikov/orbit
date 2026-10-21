// @ts-check
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://orbit.mogilnikov.dev",
  integrations: [sitemap({ filter: (page) => !page.endsWith("/404/") })],
});
