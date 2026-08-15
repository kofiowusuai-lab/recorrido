import type { Locale } from './locales';

const TOKEN = /^[A-Za-z0-9_-]{32,256}$/;
const FRAGMENT_LOCALES: Record<string, Locale> = { en: 'en', es: 'es', pt: 'pt', 'pt-BR': 'pt' };

export function parseOptOutFragment(fragment: string): { token: string; locale?: Locale } | null {
  if (!fragment.startsWith('#') || fragment.length < 2) return null;
  const raw = fragment.slice(1);
  if (!raw.includes('=')) return TOKEN.test(raw) ? { token: raw } : null;
  const params = new URLSearchParams(raw);
  const keys = [...params.keys()];
  if (keys.some((key) => key !== 'token' && key !== 'locale') || keys.filter((key) => key === 'token').length !== 1 || keys.filter((key) => key === 'locale').length > 1) return null;
  const token = params.get('token') ?? '';
  const requestedLocale = params.get('locale');
  const locale = requestedLocale ? FRAGMENT_LOCALES[requestedLocale] : undefined;
  if (!TOKEN.test(token) || (requestedLocale !== null && !locale)) return null;
  return { token, locale };
}

export function validOptOutResponse(value: unknown): value is { status: 'success'; message: string } {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return JSON.stringify(Object.keys(row).sort()) === JSON.stringify(['message', 'status']) && row.status === 'success' && typeof row.message === 'string' && row.message.length > 0 && row.message.length <= 300;
}
