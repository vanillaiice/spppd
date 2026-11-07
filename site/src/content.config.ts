import fs from 'node:fs';
import { defineCollection } from 'astro:content';
import { glob, type Loader } from 'astro/loaders';
import { z } from 'astro/zod';
import { repoFile, siteLinks } from './lib/repo';

// Posts are Markdown files in src/content/blog. Drafts show only in `npm run dev`.
const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    date: z.coerce.date(),
    description: z.string(),
    draft: z.boolean().default(false),
  }),
});

// One entry per released version in the repository's CHANGELOG.md. "Unreleased" is
// left out, because nobody can download it yet.
function changelog(): Loader {
  return {
    name: 'changelog',
    load: async ({ store, renderMarkdown, watcher, logger }) => {
      const file = repoFile('CHANGELOG.md');
      const read = async () => {
        store.clear();
        const text = fs.readFileSync(file, 'utf8');
        const sections = text.split(/^## /m).slice(1);
        let order = 0;
        for (const section of sections) {
          const newline = section.indexOf('\n');
          const heading = section.slice(0, newline).trim();
          const match = heading.match(/^(\d+\.\d+\.\d+)\s*\((\d{4}-\d{2}-\d{2})\)$/);
          if (!match) {
            if (heading !== 'Unreleased') logger.warn(`Skipped changelog heading "${heading}"`);
            continue;
          }
          const [, version, date] = match;
          // Its own headings sit one level under the version's.
          const body = siteLinks(section.slice(newline + 1).replace(/^### /gm, '#### '));
          store.set({
            id: version,
            data: { version, date: new Date(`${date}T00:00:00Z`), order: order++ },
            body,
            rendered: await renderMarkdown(body),
          });
        }
      };
      await read();
      watcher?.add(file);
      watcher?.on('change', (changed) => changed === file && read());
    },
  };
}

const releases = defineCollection({
  loader: changelog(),
  schema: z.object({ version: z.string(), date: z.date(), order: z.number() }),
});

// README.md, ROADMAP.md, PRIVACY.md and TERMS.md, as they are in the repository.
function repoDocs(names: Record<string, string>): Loader {
  return {
    name: 'repo-docs',
    load: async ({ store, renderMarkdown, watcher }) => {
      const read = async (id: string, file: string) => {
        const text = fs.readFileSync(file, 'utf8');
        const title = text.match(/^# (.*)$/m)?.[1] ?? id;
        const updated = text.match(/Last updated (\d{4}-\d{2}-\d{2})/)?.[1];
        const body = siteLinks(text.replace(/^# .*\n/m, ''));
        store.set({ id, data: { title, updated }, body, rendered: await renderMarkdown(body) });
      };
      for (const [id, name] of Object.entries(names)) {
        const file = repoFile(name);
        await read(id, file);
        watcher?.add(file);
        watcher?.on('change', (changed) => changed === file && read(id, file));
      }
    },
  };
}

const docs = defineCollection({
  loader: repoDocs({ readme: 'README.md', roadmap: 'ROADMAP.md', privacy: 'PRIVACY.md', terms: 'TERMS.md' }),
  schema: z.object({ title: z.string(), updated: z.string().optional() }),
});

export const collections = { blog, releases, docs };
