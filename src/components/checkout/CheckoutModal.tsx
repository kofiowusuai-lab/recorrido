'use client';

import { FormEvent, useEffect, useRef, useState } from 'react';
import type { CatalogCode } from '@/lib/site/catalog';
import type { Locale, SiteContent } from '@/lib/site/locales';

type Props = { open: boolean; onClose: () => void; plan: CatalogCode; locale: Locale; copy: SiteContent['checkout'] };

export function CheckoutModal({ open, onClose, plan, locale, copy }: Props) {
  const dialog = useRef<HTMLDialogElement>(null);
  const firstField = useRef<HTMLInputElement>(null);
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const node = dialog.current;
    if (open && !node?.open) {
      node?.showModal();
      requestAnimationFrame(() => firstField.current?.focus());
    }
    if (!open && node?.open) node.close();
  }, [open]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setMessage('');
    const data = Object.fromEntries(new FormData(event.currentTarget));
    try {
      const response = await fetch('/api/checkout', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ ...data, plan, locale }),
      });
      const result = await response.json() as { url?: string };
      if (response.ok && result.url) window.location.assign(result.url);
      else setMessage(response.status === 400 ? copy.invalid : copy.unavailable);
    } catch {
      setMessage(copy.unavailable);
    } finally {
      setBusy(false);
    }
  }

  return <dialog ref={dialog} className="checkout" onClose={onClose} onCancel={onClose} aria-labelledby="checkout-title">
    <div className="checkout-top"><div><p className="eyebrow">Recorrido / {plan.replace('_', ' ')}</p><h2 id="checkout-title">{copy.title}</h2></div><button className="icon-button" onClick={onClose} aria-label={copy.close}>×</button></div>
    <p>{copy.body}</p>
    <form onSubmit={submit}>
      <label>{copy.name}<input ref={firstField} name="name" autoComplete="name" required minLength={2} /></label>
      <label>{copy.email}<input name="email" type="email" autoComplete="email" required /></label>
      <div className="form-row"><label>{copy.code}<input name="countryCode" defaultValue="+57" inputMode="tel" required /></label><label>{copy.whatsapp}<input name="whatsapp" inputMode="tel" autoComplete="tel-national" required /></label></div>
      <label>{copy.country}<input name="country" defaultValue={locale === 'pt' ? 'BR' : 'CO'} maxLength={2} required /></label>
      <label>{copy.office}<input name="office" autoComplete="organization" /></label>
      {message && <p className="form-error" role="alert">{message}</p>}
      <button className="button" disabled={busy}>{copy.continue}</button>
    </form>
  </dialog>;
}
