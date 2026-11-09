export default {
  title: 'SPPPD',
  description:
    'A free top-down racing game for Windows, Android and Linux. Race the AI, slide for boost, build your own tracks, or race up to three friends online.',
  contact: 'vanillaiice1@proton.me',
  // The game's default online server, as the status page names it. The page asks
  // /api/status, which Caddy passes to the relay.
  relay: 'spppd.xyz',
  repo: 'https://github.com/vanillaiice/spppd',
  releases: 'https://github.com/vanillaiice/spppd/releases',
  github: 'https://github.com/vanillaiice/spppd',
  itch: 'https://vanillaiice.itch.io/spppd?ref=spppd.xyz',
  // The community server: feedback, ideas, finding a race. A never-expiring invite.
  discord: 'https://discord.gg/gPCvjny3qW',
  author: { name: 'vanillaiice', url: 'https://vanillaiice.xyz' },
  // Self-hosted Umami (cookieless), deployed from ~/Projects/stats.hblabs.xyz. The ID is
  // public by design. It only counts visits on the real domain, never in dev or preview.
  // Leave websiteId empty to load no analytics at all.
  umami: {
    src: 'https://stats.hblabs.xyz/script.js',
    websiteId: '34e2efc4-618d-4d9d-a896-30e72f8b6d84',
    domains: 'spppd.xyz',
  },
};
