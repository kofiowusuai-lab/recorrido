# Recorrido Credibility Website Design

**Status:** Approved through Kofi’s direct build-and-deploy brief
**Date:** 2026-08-11
**Primary surface:** Decide / Learn

## Goal

Launch a premium, mobile-first Recorrido credibility website on Vercel with verified product footage, authoritative pricing, Spanish and Brazilian Portuguese service copy, English corporate copy, cinematic scroll motion, and safe customer-specific Stripe Checkout initiation.

## Source of truth

- Product: WhatsApp-native real-estate listing content for Latin American agents.
- Public product term: `recorrido cinematográfico`. Never claim 3D, 360°, or a spatially continuous virtual walkthrough.
- Hero proof: `references/quality_bars/GLOBAL_PROPERTY_VIDEO_QUALITY_BAR_2026-08-10.mp4`.
- Launch catalog: Single $22 once; Pro $32/month or $320/year, four monthly generations; Agency $79/month, 12 shared monthly generations, three members.
- Service languages: Spanish and Brazilian Portuguese. English localizes the credibility site but is not advertised as a production-language promise.
- Turnaround: within 24 hours.
- USD is canonical. Stripe handles eligible local presentment through Adaptive Pricing.

## Art direction

Original editorial product-film direction, borrowing principles rather than identity from premium product and payments sites.

- Deep Recorrido navy `#06172F` and near-black `#02132D`.
- White and warm off-white editorial fields.
- Production red `#DC1C2E` as the action color.
- The supplied red-to-orange logo gradient appears only in the official mark and restrained motion accents.
- Large, tightly tracked display typography paired with a highly legible sans body.
- Real Recorrido footage is the product object. No stock photos, fake metrics, generic SaaS icon grids, testimonials, or invented customer claims.
- Scroll motion uses pinned editorial reveals, phone-frame depth, route labels, subtle parallax, and section choreography. No scroll hijacking. Reduced-motion users receive a static equivalent.

## Page structure

1. Sticky navigation with logo, locale switcher, Product, How it works, Pricing, FAQ, and start CTA.
2. Hero with direct outcome-led copy and the approved vertical quality-bar video in a restrained phone frame.
3. Pinned cinematic transformation sequence: source photos → camera motion → captions/brand/map → delivery.
4. Product proof section with four outcome rows: cinematic video, branding/contact/MLS, amenities map and drive times, social caption.
5. WhatsApp workflow in three steps: send listing photos, Recorrido produces and quality-checks, receive the finished package.
6. Pricing comparison with monthly/annual Pro toggle and exact catalog terms.
7. Trust and accuracy section covering 24-hour delivery, structural QA, clear virtual-staging labels, and no false 3D claim.
8. FAQ, footer, privacy, terms, refund/cancellation, and purchase-result routes.

## Localization

Routes:

- `/es` is the default public experience and `hreflang=es`.
- `/pt` uses Brazilian Portuguese and `hreflang=pt-BR`.
- `/en` is a complete corporate translation and `hreflang=en`.
- `/` redirects to `/es`.

All visible navigation, product, pricing, FAQ, checkout form, legal summaries, metadata, structured data, and error/success messages derive from one typed locale dictionary. Currency stays USD in plan labels with a note about eligible local presentment.

## Checkout design

Public buttons never expose a raw Stripe price ID and never trust a caller-supplied amount, currency, customer, metadata, or redirect URL.

- Each plan button opens a localized onboarding form requesting only name, email, WhatsApp country code/number, country, and optional office name.
- The server accepts an allowlisted internal catalog code.
- Checkout activation requires a narrow server authority that creates or resolves the authoritative account/member and then invokes the existing customer-specific Checkout Session flow.
- The returned URL must be HTTPS on the exact `checkout.stripe.com` host.
- Payment state is granted only by signed Stripe webhooks, never by the success redirect.
- If the required production authority or credentials are unavailable, buttons fail closed with a localized support message rather than creating disconnected payments.

## Legal posture

- Do not advertise the referral program until its separate production/customer-messaging release gate is approved.
- Virtual staging is labeled `Imagen con ambientación virtual` / `Imagem com ambientação virtual` where shown.
- Customer-requested monetary refunds are unavailable after any generation from the paid service period has been reserved, consumed, or released.
- Period-end cancellation stops the next renewal while preserving already-paid access and remaining generations through period end; remaining subscription and referral generations then expire.
- Use `SET PACE HOLDINGS LLC` only where a legal-entity disclosure is required. Do not invent a postal address, public support email, or public telephone number.

## Technical architecture

- Next.js App Router, TypeScript, React Server Components by default.
- Motion via CSS and focused GSAP ScrollTrigger client islands. No Three.js dependency because real product film provides depth with lower mobile cost.
- Typed catalog and translation modules are the canonical UI truth.
- Route handlers apply strict body limits, allowlists, server-derived redirect URLs, rate limiting, and sanitized errors.
- Security headers, sitemap, robots, JSON-LD, Open Graph, and `llms.txt` ship with the site.
- Vercel production deployment, separate `recorrido` project, stable Vercel URL until a dedicated domain is available.

## QA and release gates

- Unit tests for catalog, locales, legal copy, checkout allowlists, URL validation, metadata, and route roster.
- Playwright coverage at 320, 375, 390, 768, 1024, and 1440 widths.
- Keyboard navigation, mobile menu, locale persistence, pricing toggle, modal focus, reduced motion, no horizontal overflow, and no console errors.
- Lint, typecheck, unit tests, build, E2E, secret scan, final diff review.
- Desktop and mobile screenshots receive visual inspection before deployment.
- Production URL receives HTTP, rendered mobile/desktop, metadata, locale, pricing, asset, and checkout fail-closed/redirect verification.
