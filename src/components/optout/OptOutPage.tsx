'use client';

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import type { Locale } from '@/lib/site/locales';
import { parseOptOutFragment, validOptOutResponse } from '@/lib/site/optout';

export type OptOutCopy = {
  eyebrow: string; title: string; body: string; confirm: string; missing: string; waiting: string;
  success: string; unavailable: string; fallback: string; back: string;
};

const apiLocale = (locale: Locale) => locale === 'pt' ? 'pt-BR' : locale;

export function OptOutPage({ locale, copy }: { locale: Locale; copy: OptOutCopy }) {
  const fragmentCaptured = useRef(false);
  const [token, setToken] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [status, setStatus] = useState('');

  useEffect(() => {
    if (fragmentCaptured.current) return;
    fragmentCaptured.current = true;
    const parsed = parseOptOutFragment(window.location.hash);
    window.history.replaceState(null, '', window.location.pathname + window.location.search);
    setToken(parsed?.token ?? null);
    setReady(true);
  }, []);

  async function confirm() {
    if (!token || submitted) return;
    setSubmitted(true);
    setStatus(copy.waiting);
    try {
      const response = await fetch('/api/opt-out', {
        method: 'POST', headers: { 'content-type': 'application/json' }, cache: 'no-store',
        body: JSON.stringify({ token, locale: apiLocale(locale) }),
      });
      const body: unknown = await response.json();
      if (!response.ok || !validOptOutResponse(body) || body.message !== copy.success) throw new Error('unavailable');
      setStatus(body.message);
    } catch {
      setStatus(copy.unavailable);
    }
  }

  return <main className="optout-page">
    <header className="optout-nav shell">
      <Link className="legal-brand" href={`/${locale}`} aria-label="Recorrido home"><img src="/brand/recorrido-wordmark.png" alt="Recorrido" /></Link>
      <nav aria-label="Language"><Link href="/es/baja">ES</Link><Link href="/pt/descadastro">PT</Link><Link href="/en/opt-out">EN</Link></nav>
    </header>
    <section className="optout-shell shell">
      <p className="eyebrow">{copy.eyebrow}</p>
      <h1>{copy.title}</h1>
      <div className="optout-card">
        <p>{copy.body}</p>
        {!ready && <p aria-live="polite">{copy.waiting}</p>}
        {ready && !token && <p className="optout-status" role="status">{copy.missing}</p>}
        {ready && token && <button className="button" disabled={submitted} onClick={confirm}>{copy.confirm}</button>}
        {status && <p className="optout-status" role="status" aria-live="polite">{status}</p>}
        <p className="optout-fallback">{copy.fallback}</p>
      </div>
      <Link className="optout-back" href={`/${locale}`}>← {copy.back}</Link>
    </section>
  </main>;
}
