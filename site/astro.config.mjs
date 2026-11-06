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
  vite: {
    build: { assetsInlineLimit: 0 },
    // In dev, the status page asks a relay run here with -status :8081.
    server: { proxy: { '/api': process.env.SPPPD_STATUS ?? 'http://127.0.0.1:8081' } },
  },
});
