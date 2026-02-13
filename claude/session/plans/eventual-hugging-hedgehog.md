# Fix All Remaining Review Issues — dotslash.dev

## Context

4 design reviews identified 83 issues total. The fix-plan addressed 29, of which 26 are done. This plan covers the **3 incomplete fix-plan items + 21 missed review items** = ~24 items total.

User decisions: skip snap scrolling fix, add placeholder pages, wire design tokens, consolidate forms.

---

## Wave 1: Foundation — Design Tokens + Contrast + Security + Cleanup

Everything else depends on the token system being in place.

### 1A. Add missing design tokens to globals.css

`app/globals.css` `@theme inline` block — add:
```
--color-ds-gray-950: #0a0a0a;
--color-ds-gray-550: #737373;
--color-ds-gray-250: #cccccc;
--color-ds-gray-150: #eeeeee;
--color-ds-border-dark: #222222;
```

### 1B. Migrate ALL hardcoded hex → design tokens

Replace every `bg-[#hex]`, `text-[#hex]`, `border-[#hex]` with `bg-ds-*`, `text-ds-*`, `border-ds-*` Tailwind token classes. ~20 files, ~150 replacements.

Key mappings:
| Hex | Token |
|-----|-------|
| `#0a0a0a` | `ds-gray-950` |
| `#0f0f0f` | `ds-gray-900` |
| `#1a1a1a` | `ds-gray-800` |
| `#252525` | `ds-gray-750` |
| `#2a2a2a` | `ds-gray-700` |
| `#333` | `ds-border` |
| `#222` | `ds-border-dark` |
| `#e0e0e0` | `ds-border-light` |
| `#999` | `ds-muted` |
| `#595959` | `ds-subtle` |
| `#b8b8b8` | `ds-light-text` |
| `#b5b5b5` | `ds-gray-300` |
| `#737373` | `ds-gray-550` |
| `#ccc`/`#cccccc` | `ds-gray-250` |
| `#f5f5f5` | `ds-gray-50` |
| `#fafafa` | `ds-white` |
| `#eee`/`#ebebeb` | `ds-gray-150` |
| `#666` on dark bg | `ds-muted` (fixes WCAG contrast) |

**Keep raw hex** for: canvas JS `ctx.fillStyle`, error color `#ff6b6b`, any color not in grayscale system.

Files: `page.tsx`, `(services)/layout.tsx`, `ContactForm.tsx`, `InlineContactSection.tsx`, `PixelContactSection.tsx`, `AboutSection.tsx`, `SocialProofSection.tsx`, `ServiceCard.tsx`, `ServicePageHero.tsx`, `ContentBlock.tsx`, `ProcessStep.tsx`, `Section.tsx`, `RelatedServices.tsx`, `PageHeader.tsx`, `MobileNav.tsx`, `CookieBanner.tsx`, `error.tsx`, `privacy/page.tsx`, `how-we-work/page.tsx`

### 1C. Fix focus-visible selectors

`globals.css:111-114` — `[class*="bg-[#0"]` selector breaks after token migration. Replace with:
```css
.dark-focus *:focus-visible { outline-color: var(--color-ds-white); }
```
Add `.dark-focus` class to dark-bg containers (footer, contact section, service cards area). Or use token-based selectors like `[class*="bg-ds-gray-9"]`.

### 1D. Color contrast fix (#666 on dark bg)

`#666` on `#0f0f0f` ≈ 3.9:1 — fails WCAG AA. Already handled by 1B: `text-[#666]` on dark bg → `text-ds-muted` (#999, ≈6.3:1 on #0f0f0f). Locations:
- `page.tsx:175,188,199,210` (footer nav headers)
- `(services)/layout.tsx:23,32,39,46` (footer nav headers)
- `PixelContactSection.tsx:645`

Focus border `focus:border-[#666]` in `ContactForm.tsx:27,43` and `InlineContactSection.tsx:58,74` → `focus:border-ds-muted`

### 1E. Security headers — add CSP + HSTS

`next.config.ts` — add:
- `Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'`
- `Strict-Transport-Security: max-age=31536000; includeSubDomains`

Note: `'unsafe-inline'` for scripts needed for Next.js inline scripts + JSON-LD. For styles needed for Tailwind.

### 1F. Copyright year → dynamic

- `page.tsx:211` → `{new Date().getFullYear()}`
- `(services)/layout.tsx:47` → same
- `PixelContactSection.tsx:310` → `` `© ${new Date().getFullYear()}` ``
- `PixelContactSection.tsx:720` → `{new Date().getFullYear()}`

### 1G. Delete unused scaffold SVGs

`rm public/file.svg public/globe.svg public/next.svg public/vercel.svg public/window.svg`

### 1H. Delete dead ServiceCard component

`app/components/ServiceCard.tsx` — confirmed zero imports. Delete.

**Wave 1 verify**: `npm run build && npm run lint`, grep for remaining `[#` in tsx (expect only canvas JS + #ff6b6b), check security headers in dev server response.

---

## Wave 2: SEO + Structure

### 2A. JSON-LD structured data

Create `app/lib/json-ld.ts` — pure builder functions:
- `organizationSchema()` → Organization + ContactPoint
- `websiteSchema()` → WebSite
- `serviceSchema(name, description, url)` → Service
- `breadcrumbSchema(items: {name, url}[])` → BreadcrumbList

Add to `app/layout.tsx`: `<script type="application/ld+json">` with Organization + WebSite graph.
Add per-page: Service + BreadcrumbList JSON-LD to each service page + how-we-work.

### 2B. Canonical URLs

Add `alternates: { canonical: 'https://dotslash.dev/...' }` to metadata in:
- `app/page.tsx` (add metadata export)
- All service pages (extend existing metadata)
- `how-we-work/page.tsx`
- `privacy/page.tsx`
- New placeholder pages

### 2C. OG image

Create `app/opengraph-image.tsx` using `next/og` `ImageResponse`:
- 1200x630, black bg, white text "dotslash.dev", tagline
- Swiss minimalist: no rounded corners

### 2D. Custom 404 page

Create `app/not-found.tsx`:
- Server component, large monospace "404", brief text, link home
- Uses design tokens, matches site branding

### 2E. Breadcrumbs component

Create `app/components/Breadcrumbs.tsx`:
- Server component, `nav[aria-label="Breadcrumb"] > ol > li`
- Props: `items: { label: string; href?: string }[]`
- Swiss styling: monospace, small, token colors

Add to all service pages + how-we-work (per-page, after PageHeader).

### 2F. Placeholder pages

Create using same layout pattern as `privacy/page.tsx` (standalone with header link):
- `app/pricing/page.tsx` — "Coming soon" + brief teaser
- `app/about/page.tsx` — team placeholder + company info
- `app/faq/page.tsx` — common questions placeholder

Each with metadata + canonical URL.

### 2G. Update sitemap + footer links

`app/sitemap.ts` — add pricing, about, faq URLs.
Footer in both `page.tsx` and `(services)/layout.tsx` — add About, Pricing links under Company nav.

**Wave 2 verify**: `npm run build`, inspect `<script type="application/ld+json">` in page source, visit `/404-test` for custom 404, check `/opengraph-image` renders, breadcrumbs on service pages, placeholder pages at /pricing /about /faq.

---

## Wave 3: UX Polish — Forms, Affordance, Accessibility

### 3A. Form consolidation

Create `app/hooks/useContactForm.ts`:
```ts
export function useContactForm() {
  const [state, formAction, pending] = useActionState(submitContact, null);
  return { state, formAction, pending };
}
```

Refactor `InlineContactSection.tsx` + `PixelContactSection.tsx` (mobile form) to use shared hook. Delete orphaned `ContactForm.tsx` (unused).

Desktop pixel form in PixelContactSection stays bespoke (positioned over canvas) but uses same hook.

### 3B. Service cards — add affordance arrow

`page.tsx:130-144` — add `→` indicator to service cards to signal clickability. Bottom-right positioned, monospace, token color.

### 3C. PageHeader — ARIA + back button fix

`PageHeader.tsx`:
- Add `aria-label="dotslash.dev homepage"` to logo Link
- Change back button from sessionStorage-dependent button → `<Link href="/">← Home</Link>`

### 3D. Canvas fallback UI

`PixelContactSection.tsx` — if `getContext("2d")` returns null, set state flag and render static text contact form instead of empty canvas.

### 3E. CLS mitigation for AboutSection

`AboutSection.tsx` — add `aspect-square` or fixed `min-height` on logo container to reserve space before ResizeObserver fires.

### 3F. Input sanitization

`actions/contact.ts` — add pure `escapeHtml()` function, apply to message field before (future) email send. 6 lines.

### 3G. Footer extraction

Extract duplicated footer from `page.tsx:161-214` and `(services)/layout.tsx:16-50` into shared `app/components/Footer.tsx`. Server component, uses tokens, dynamic year (from 1F). Replace inline footers with `<Footer />`.

**Wave 3 verify**: forms submit on all pages, service cards show arrow, PageHeader link works without sessionStorage, `npm run build && npm run lint`.

---

## File Change Matrix

| File | Wave | Changes |
|---|---|---|
| `globals.css` | 1 | Add tokens, fix focus selectors |
| `page.tsx` | 1,2,3 | Tokens, copyright, canonical, arrow, Footer |
| `(services)/layout.tsx` | 1,3 | Tokens, copyright, Footer |
| `layout.tsx` | 2 | JSON-LD |
| `next.config.ts` | 1 | CSP + HSTS |
| `PixelContactSection.tsx` | 1,3 | Tokens, copyright, hook, fallback |
| `InlineContactSection.tsx` | 1,3 | Tokens, hook |
| `ContactForm.tsx` | 3 | Delete (orphaned) |
| `ServiceCard.tsx` | 1 | Delete (dead code) |
| `PageHeader.tsx` | 1,3 | Tokens, ARIA, back→Link |
| `AboutSection.tsx` | 1,3 | Tokens, CLS fix |
| `SocialProofSection.tsx` | 1 | Tokens |
| `ServicePageHero.tsx` | 1 | Tokens |
| `ContentBlock.tsx` | 1 | Tokens |
| `ProcessStep.tsx` | 1 | Tokens |
| `Section.tsx` | 1 | Tokens |
| `RelatedServices.tsx` | 1 | Tokens |
| `MobileNav.tsx` | 1 | Tokens |
| `CookieBanner.tsx` | 1 | Tokens |
| `error.tsx` | 1 | Tokens |
| `privacy/page.tsx` | 1,2 | Tokens, canonical |
| `how-we-work/page.tsx` | 1,2 | Tokens, canonical, JSON-LD, breadcrumbs |
| `ai-strategy/page.tsx` | 2 | Canonical, JSON-LD, breadcrumbs |
| `implementation/page.tsx` | 2 | Canonical, JSON-LD, breadcrumbs |
| `partnership/page.tsx` | 2 | Canonical, JSON-LD, breadcrumbs |
| `actions/contact.ts` | 3 | Sanitization |
| `sitemap.ts` | 2 | Add new pages |
| **NEW** | | |
| `app/lib/json-ld.ts` | 2 | JSON-LD builders |
| `app/components/Breadcrumbs.tsx` | 2 | Breadcrumb nav |
| `app/components/Footer.tsx` | 3 | Shared footer |
| `app/hooks/useContactForm.ts` | 3 | Shared form hook |
| `app/not-found.tsx` | 2 | Custom 404 |
| `app/opengraph-image.tsx` | 2 | OG image |
| `app/pricing/page.tsx` | 2 | Placeholder |
| `app/about/page.tsx` | 2 | Placeholder |
| `app/faq/page.tsx` | 2 | Placeholder |
| **DELETE** | | |
| `public/{file,globe,next,vercel,window}.svg` | 1 | Scaffold leftovers |
| `app/components/ServiceCard.tsx` | 1 | Dead code |
| `app/components/ContactForm.tsx` | 3 | Orphaned after consolidation |

---

## Unresolved Questions

- favicon: default Next.js? needs visual check, custom design out of scope
- CSP `'unsafe-inline'` for scripts/styles: needed for Next.js + Tailwind, acceptable tradeoff?
- `#0a0a0a` vs `#0f0f0f`: add gray-950 token or reuse gray-900? (plan adds gray-950 for accuracy)
- placeholder pages layout: standalone like privacy or use (services) layout? (plan: standalone)
