import type { MetadataRoute } from 'next';
import { sitemapRoutes } from '@/lib/site/routes';
export default function sitemap(): MetadataRoute.Sitemap { const base = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://recorrido.example'; return sitemapRoutes.map((route) => ({ url: `${base}${route}`, changeFrequency: route.split('/').length === 2 ? 'weekly' : 'yearly', priority: route.split('/').length === 2 ? .9 : .3 })); }
