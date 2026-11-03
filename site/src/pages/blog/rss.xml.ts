import rss from '@astrojs/rss';
import type { APIContext } from 'astro';
import { publishedPosts } from '../../lib/dates';

export async function GET(context: APIContext) {
  const posts = await publishedPosts();
  return rss({
    title: 'SPPPD',
    description: 'News about SPPPD, a top-down racing game.',
    site: context.site!,
    items: posts.map((post) => ({
      title: post.data.title,
      pubDate: post.data.date,
      description: post.data.description,
      link: `/blog/${post.id}/`,
    })),
  });
}
