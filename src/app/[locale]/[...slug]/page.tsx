import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { OptOutPage } from '@/components/optout/OptOutPage';
import { isLocale, localeContent, locales, type Locale } from '@/lib/site/locales';
import { routeSlugs } from '@/lib/site/routes';

type Kind = 'privacy' | 'terms' | 'refunds' | 'success' | 'canceled' | 'optout';
function getKind(locale: Locale, slug: string): Kind | undefined { return (Object.entries(routeSlugs[locale]).find(([, value]) => value === slug)?.[0]) as Kind | undefined; }
function titleFor(kind: Kind, locale: Locale): string {
  const c = localeContent[locale];
  return kind === 'privacy' ? c.legal.privacyTitle : kind === 'terms' ? c.legal.termsTitle : kind === 'refunds' ? c.legal.refundsTitle : kind === 'success' ? c.result.success : kind === 'canceled' ? c.result.canceled : c.optout.title;
}
export function generateStaticParams() { return locales.flatMap((locale) => Object.values(routeSlugs[locale]).map((slug) => ({ locale, slug: slug.split('/') }))); }
export async function generateMetadata({ params }: { params: Promise<{ locale: string; slug: string[] }> }): Promise<Metadata> {
  const { locale, slug } = await params;
  if (!isLocale(locale)) return {};
  const kind = getKind(locale, slug.join('/'));
  if (!kind) return {};
  return { title: `${titleFor(kind, locale)} — Recorrido`, robots: ['success', 'canceled', 'optout'].includes(kind) ? { index: false, follow: false, noarchive: true } : undefined, referrer: kind === 'optout' ? 'no-referrer' : undefined };
}
export default async function InfoPage({ params }: { params: Promise<{ locale: string; slug: string[] }> }) {
  const { locale, slug } = await params;
  if (!isLocale(locale)) notFound();
  const kind = getKind(locale, slug.join('/'));
  if (!kind) notFound();
  const c = localeContent[locale];
  if (kind === 'optout') return <OptOutPage locale={locale} copy={c.optout} />;
  const title = titleFor(kind, locale);
  const body = kind === 'privacy' ? c.legal.privacy : kind === 'terms' ? c.legal.terms : kind === 'refunds' ? c.legal.refunds : kind === 'success' ? c.result.successBody : c.result.canceledBody;
  return <main className="legal"><Link className="legal-brand" href={`/${locale}`}><img src="/brand/recorrido-wordmark.png" alt="Recorrido" /></Link><p className="eyebrow">Recorrido / {kind}</p><h1>{title}</h1><p className="legal-body">{body}</p>{kind === 'terms' && <p className="legal-body">{c.legal.staging}</p>}<Link className="button button-dark" href={`/${locale}`}>← Recorrido</Link></main>;
}
