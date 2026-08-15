'use client';
import Link from 'next/link';
import { useState } from 'react';
import type { Locale, SiteContent } from '@/lib/site/locales';

export function SiteNav({ locale, copy, onStart }: { locale: Locale; copy: SiteContent['nav']; onStart: () => void }) {
  const [open, setOpen] = useState(false);
  return <header className="site-header"><a className="skip" href="#main">Skip to content</a><nav className="nav shell" aria-label="Primary">
    <Link href={`/${locale}`} className="brand" aria-label="Recorrido home"><img src="/brand/recorrido-wordmark.png" alt="Recorrido" /></Link>
    <button className="menu-button" aria-expanded={open} aria-controls="nav-links" onClick={() => setOpen(!open)}><span /> <span /><b>{open ? '×' : 'Menu'}</b></button>
    <div id="nav-links" className={`nav-links ${open ? 'is-open' : ''}`} onClick={() => setOpen(false)}>
      <a href="#product">{copy.product}</a><a href="#process">{copy.process}</a><a href="#pricing">{copy.pricing}</a><a href="#faq">{copy.faq}</a>
      <div className="locales" aria-label="Language"><Link href="/es" hrefLang="es" aria-current={locale === 'es' ? 'page' : undefined}>ES</Link><Link href="/pt" hrefLang="pt-BR" aria-current={locale === 'pt' ? 'page' : undefined}>PT</Link><Link href="/en" hrefLang="en" aria-current={locale === 'en' ? 'page' : undefined}>EN</Link></div>
      <button className="button button-small" onClick={onStart}>{copy.start}</button>
    </div>
  </nav></header>;
}
