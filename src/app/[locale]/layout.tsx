import { notFound } from 'next/navigation';
import { isLocale, localeContent, locales } from '@/lib/site/locales';
export function generateStaticParams() { return locales.map((locale) => ({ locale })); }
export default async function LocaleLayout({ children, params }: { children: React.ReactNode; params: Promise<{ locale: string }> }) { const { locale } = await params; if (!isLocale(locale)) notFound(); return <div lang={localeContent[locale].htmlLang}>{children}</div>; }
