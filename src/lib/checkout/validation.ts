import { z } from 'zod';
import { catalogCodes } from '@/lib/site/catalog';
import { locales } from '@/lib/site/locales';

const compact = (value: string) => value.trim().replace(/\s+/g, ' ');
export const checkoutRequestSchema = z.object({
  plan: z.enum(catalogCodes), locale: z.enum(locales), name: z.string().min(2).max(80),
  email: z.string().trim().email().max(160), countryCode: z.string().regex(/^\+[1-9]\d{0,3}$/),
  whatsapp: z.string().min(6).max(24), country: z.string().regex(/^[A-Za-z]{2}$/),
  office: z.string().max(100).optional().default(''),
}).strict();
export type CheckoutInput = z.infer<typeof checkoutRequestSchema>;

export function normalizeCheckoutInput(input: CheckoutInput): CheckoutInput {
  return { ...input, name: compact(input.name), email: input.email.trim().toLowerCase(),
    whatsapp: input.whatsapp.replace(/\D/g, ''), country: input.country.toUpperCase(), office: compact(input.office ?? '') };
}

export function isStripeCheckoutUrl(value: string): boolean {
  try { const url = new URL(value); return url.protocol === 'https:' && url.hostname === 'checkout.stripe.com'; }
  catch { return false; }
}
