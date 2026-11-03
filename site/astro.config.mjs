import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://spppd.xyz',
  trailingSlash: 'ignore',
  build: {
    format: 'directory',
    // Caddy's Content-Security-Policy allows no inline styles.
    inlineStylesheets: 'never',
  },
  // Nor inline scripts: keep the clip player in its own file.
  vite: { build: { assetsInlineLimit: 0 } },
});
