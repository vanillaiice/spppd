// Facts read from the game's repository, so the site never has to be told them twice.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import site from '../site.config';

// Astro runs in site/, and the repository is one folder up (also in the Docker build).
export const repoRoot = path.resolve(process.cwd(), '..');

export function repoFile(name: string): string {
  return path.join(repoRoot, name);
}

// src/config.lua holds the version, as the Makefile reads it.
export function gameVersion(): string {
  const lua = fs.readFileSync(repoFile('src/config.lua'), 'utf8');
  const match = lua.match(/VERSION = "(.*?)"/);
  if (!match) throw new Error('No VERSION in src/config.lua');
  return match[1];
}

export interface Download {
  id: 'win64' | 'win32' | 'apk' | 'love';
  file: string;
  href: string;
  bytes: number;
}

// The files come from the GitHub release, so the site's server doesn't carry them.
// `make site-downloads` writes their sizes from dist/ into src/downloads.json.
export function downloads(): Download[] {
  const v = gameVersion();
  const sizes = path.join(process.cwd(), 'src', 'downloads.json');
  if (!fs.existsSync(sizes)) throw new Error('src/downloads.json is missing. Run make site-downloads.');
  const list: { version: string; bytes: Record<string, number> } = JSON.parse(fs.readFileSync(sizes, 'utf8'));
  if (list.version !== v) {
    throw new Error(`src/downloads.json is for ${list.version}, not ${v}. Run make site-downloads.`);
  }
  const files: [Download['id'], string][] = [
    ['win64', `spppd-${v}-win64.zip`],
    ['win32', `spppd-${v}-win32.zip`],
    ['apk', `spppd-${v}-android.apk`],
    ['love', `spppd-${v}.love`],
  ];
  return files.map(([id, file]) => {
    const bytes = list.bytes[file];
    if (!bytes) throw new Error(`${file} is missing from src/downloads.json. Run make site-downloads.`);
    return { id, file, href: `${site.repo}/releases/download/v${v}/${file}`, bytes };
  });
}

export function megabytes(bytes: number): string {
  return bytes < 1e6 ? `${Math.round(bytes / 1e3)} KB` : `${(bytes / 1e6).toFixed(1)} MB`;
}

// The repository's Markdown links to its other files by name, which works on GitHub.
// On the site those become the pages that show them, and links to anything else in
// the repository, which isn't published, become plain text.
const PAGES: Record<string, { href: string; name: string }> = {
  'README.md': { href: '/guide/', name: 'guide' },
  'PRIVACY.md': { href: '/privacy/', name: 'privacy policy' },
  'TERMS.md': { href: '/terms/', name: 'terms of use' },
  'CHANGELOG.md': { href: '/changelog/', name: 'changelog' },
  'ROADMAP.md': { href: '/roadmap/', name: 'roadmap' },
};

export function siteLinks(markdown: string): string {
  return markdown.replace(/(!?)\[([^\]]+)\]\(([^)\s]+)\)/g, (link, bang, text, href) => {
    if (bang || /^(?:[a-z][a-z0-9+.-]*:|\/|#)/i.test(href)) return link;
    const [file, hash] = href.split('#');
    const page = PAGES[file];
    if (!page) return text;
    // A link that reads as its file name reads as the page instead.
    return `[${text === file ? page.name : text}](${page.href}${hash ? `#${hash}` : ''})`;
  });
}

// A file in public/media, with a hash of its contents in the URL. Caddy lets browsers
// keep media for a week, so a re-recorded clip needs a new address to be seen.
const mediaHashes = new Map<string, string>();

export function media(file: string): string {
  let hash = mediaHashes.get(file);
  if (!hash) {
    const data = fs.readFileSync(path.join(process.cwd(), 'public', 'media', file));
    hash = createHash('sha256').update(data).digest('hex').slice(0, 10);
    mediaHashes.set(file, hash);
  }
  return `/media/${file}?v=${hash}`;
}
