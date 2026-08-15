# Recorrido Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, verify, and deploy Recorrido’s localized premium credibility and pricing website with customer-specific Stripe Checkout activation that fails closed until its billing authority is healthy.

**Architecture:** A Next.js App Router site serves `/es`, `/pt`, and `/en` from typed shared data. Server Components render all indexable content. Focused client islands handle navigation, pricing cadence, scroll motion, and checkout onboarding. A same-origin server route validates symbolic catalog codes and delegates to a server-only onboarding/checkout authority without exposing secrets or financial identifiers.

**Tech Stack:** Next.js, TypeScript, React, GSAP ScrollTrigger, CSS Modules/global CSS, Vitest, Testing Library, Playwright, Vercel.

---

### Task 1: Scaffold and contracts

**Files:** Create `package.json`, Next.js configuration, TypeScript configuration, Vitest/Playwright configuration, and `src/lib/site/*`.

- [ ] Write failing tests for the exact locale roster, route roster, catalog amounts/allowances, and prohibited marketing claims.
- [ ] Run focused tests and confirm RED because the modules do not exist.
- [ ] Scaffold Next.js and implement typed locale/catalog/site modules.
- [ ] Run focused tests and confirm GREEN.

### Task 2: Prepare official assets

**Files:** Create `public/brand/*`, `public/media/*`, and `docs/assets-manifest.md`.

- [ ] Create tests/assertions for required asset filenames and browser-safe media properties.
- [ ] Derive a transparent brand mark, wordmark, favicon, optimized H.264 silent hero video, and representative poster from approved sources.
- [ ] Verify geometry, alpha, duration, pixel format, fast-start, file size, and one-to-one manifest coverage.

### Task 3: Build localized landing routes

**Files:** Create `src/app/[locale]/*`, `src/components/marketing/*`, and `src/app/globals.css`.

- [ ] Write failing rendered-content tests for every locale and required section.
- [ ] Implement semantic page composition, responsive navigation, hero film, proof sections, workflow, pricing, trust, FAQ, footer, and legal links.
- [ ] Add purposeful GSAP scroll choreography and static reduced-motion equivalents.
- [ ] Run component and route tests until GREEN.

### Task 4: Add legal and discovery surfaces

**Files:** Create localized privacy, terms, purchase-result routes, `robots.ts`, `sitemap.ts`, metadata, JSON-LD, and `public/llms.txt`.

- [ ] Write failing tests for canonical URLs, alternate locales, legal terms, schema facts, sitemap routes, robots rules, and plain-text discovery.
- [ ] Implement all surfaces from shared typed facts.
- [ ] Run focused tests until GREEN.

### Task 5: Add safe checkout onboarding

**Files:** Create `src/components/checkout/*`, `src/app/api/checkout/route.ts`, and `src/lib/checkout/*`.

- [ ] Write failing tests for strict input shape, body bound, symbolic product allowlist, normalization, rate limit, server-derived redirects, sanitized errors, and exact Stripe hosted URL validation.
- [ ] Implement the localized onboarding modal and same-origin server route.
- [ ] Integrate only with a verified server-only account/member + Checkout authority. If unavailable, return a localized 503 and preserve a non-payment contact path.
- [ ] Run route and UI tests until GREEN.

### Task 6: Browser QA and repair

**Files:** Create `tests/e2e/*` and `scripts/visual-qa.*`.

- [ ] Start a clean production server.
- [ ] Run Playwright at 320, 375, 390, 768, 1024, and 1440 widths.
- [ ] Verify no horizontal overflow, navigation/menu/focus behavior, locale links, pricing toggle, modal keyboard behavior, reduced motion, media load, route-away/back lifecycle, and zero console errors.
- [ ] Capture desktop/mobile screenshots, inspect them visually, repair failures, and rerun the complete suite.

### Task 7: Release and production verification

**Files:** Update release evidence and Vercel project linkage.

- [ ] Run lint, typecheck, unit tests, production build, E2E, secret scan, and final diff review.
- [ ] Commit with the configured `Casper <kofi@traqd.io>` identity and push the website branch.
- [ ] Create/link the Vercel `recorrido` project and deploy the tested commit.
- [ ] Configure only verified production environment values through no-newline input.
- [ ] Verify the stable production URL over HTTP and rendered mobile/desktop, including every locale, pricing fact, legal route, metadata surface, media asset, and checkout fail-closed or exact Stripe redirect behavior.
- [ ] Record deployment URL, commit SHA, test counts, visual QA evidence, and any explicit activation blocker.
