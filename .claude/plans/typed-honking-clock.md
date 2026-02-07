# Fix All Review Issues — dotslash.dev

## Context
4 design reviews found 15 critical, 22 high, 31 medium, 15 low issues. Site looks great visually but has zero functional CTAs, broken forms, invisible mobile content, wrong metadata, and no SEO infrastructure. Current estimated conversion: ~2-3%.

**Decisions**: server action with console.log (no email svc), social proof structure only, full scope.

---

## Wave 1: Functional Blockers

### 1.1 Wire contact forms to real server action
- `PixelContactSection.tsx` — replace fake setTimeout (line 641-648) with `useActionState` + `submitContact`. Fix empty button label (line 723).
- `InlineContactSection.tsx` — same: replace fake submit (line 11-19) with `useActionState`.
- Reference: `ContactForm.tsx` already uses correct pattern but is unused on any page.

### 1.2 Fix server action
- `actions/contact.ts` — remove PII console.log (line 25). Improve email validation (regex instead of `includes('@')`). Use discriminated union for `ContactState` (`idle | success | error`). Add type guards instead of `as string` casts.

### 1.3 Fix mobile hero
- `page.tsx:24` — left panel `hidden md:flex` hides all text on mobile. Make visible, stack vertically on mobile.

### 1.4 Add hero CTA
- `page.tsx` — add "Start a conversation" button in hero, links to `#contact`. Swiss style: black bg, white text, no rounded corners.

### 1.5 Fix metadata + OG tags
- `layout.tsx:17-20` — change "Software Craftsmanship" / "FP/DDD" to AI consultancy positioning. Add `metadataBase`, OG tags, Twitter card.

### 1.6 Add SEO infrastructure
- Create `app/robots.ts` + `app/sitemap.ts` (Next.js metadata API).

### 1.7 Move puppeteer to devDeps
- `package.json:12` — `@modelcontextprotocol/server-puppeteer` from deps to devDeps.

---

## Wave 2: UX & Accessibility

### 2.1 Fix color contrast (WCAG AA)
- Replace non-compliant colors across all files:
  - `#666` on white → `#595959` (7:1)
  - `#888` on `#1a1a1a` → `#b8b8b8` (6:1)
  - `#444` on `#0a0a0a` → `#999` (4.6:1)
- Files: `page.tsx`, `ServicePageHero.tsx`, `ContentBlock.tsx`, all components with these hex values.

### 2.2 Increase font sizes
- `page.tsx` — body text `10px` → `12px`, card text `10px` → `12-13px`, card titles `0.85rem` → `1rem`.
- Form inputs — ensure minimum `14px` + adequate padding.

### 2.3 Improve touch targets
- `PageHeader.tsx:35-40` — back button `text-[10px]` too small. Increase to min 44px hit area.
- All form inputs — minimum `py-3` padding.
- Fix desktop pixel form field visibility (border-transparent → visible border).

### 2.4 Add persistent header CTA
- `PageHeader.tsx` — add "Get in touch" button linking to `/#contact`.

### 2.5 Add form validation feedback
- Both contact forms: field-level error display, ARIA attributes (`aria-invalid`, `aria-describedby`, `aria-live` region).

### 2.6 Add focus states + skip links
- `globals.css` — `*:focus-visible { outline: 2px solid #000; outline-offset: 2px; }`.
- `page.tsx` — sr-only skip links to `#services` and `#contact`.
- Canvas elements: `aria-hidden="true"` or `role="img"` with label.

### 2.7 Fix heading hierarchy
- Audit all pages for h1→h3 skips, fix to sequential.

### 2.8 Add reduced motion support
- `globals.css` — `@media (prefers-reduced-motion: reduce)` disables animations.
- Canvas components: check `matchMedia`, skip RAF loops.

---

## Wave 3: Content Structure & Navigation

### 3.1 Social proof section (placeholder)
- New `SocialProofSection.tsx` — logo grid (4 placeholders) + testimonial cards (2 placeholders).
- Insert in `page.tsx` between about and contact sections.

### 3.2 Comprehensive footer
- `page.tsx:150-155` — expand from copyright-only to 4-column footer: brand, services links, company links, contact info.

### 3.3 Mobile navigation
- New `MobileMenu.tsx` — hamburger menu overlay with service links + contact.
- Wire into `PageHeader.tsx` for service pages, and homepage.

### 3.4 Service page cross-links
- All service pages — add "Related services" section before `InlineContactSection`.

### 3.5 Privacy placeholder + cookie banner
- Create `app/privacy/page.tsx` (placeholder).
- Simple `CookieBanner.tsx` — "This site uses no cookies" + dismiss.

### 3.6 Improve CTA copy
- "Send message" → "Start a conversation" / "Book a strategy call".
- Add benefit microcopy near forms.

---

## Wave 4: Code Quality

### 4.1 Extract pure functions
- Move `generateLogoPixels`, `generateDotSlashPixels` from `PixelAssembly.tsx:21-143` to `app/lib/pixel-generation.ts`.
- Move canvas rendering utils to `app/lib/canvas-rendering.ts`.

### 4.2 Design token system
- `globals.css` already defines CSS vars (lines 5-15) but they're UNUSED. Wire Tailwind theme to these vars. Replace all hardcoded hex in components.

### 4.3 Error boundaries
- Create `app/error.tsx` (Next.js convention).
- Wrap canvas-heavy components with fallback UI.

### 4.4 Security headers
- `next.config.ts` — add X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy.

### 4.5 Fix module-level issues
- `PixelLogo.tsx:9-88` — module-level `PRECOMPUTED` computation. Lazy-init or document.
- `DotPattern.tsx:19` — unbounded `pixelCache` Map. Add max size eviction.

### 4.6 Rate limiting
- Create `app/lib/rate-limit.ts` — in-memory rate limiter.
- Wire into `actions/contact.ts`.

### 4.7 Animation perf
- Stop RAF loops on `document.hidden` (Page Visibility API).
- `AboutSection.tsx:21-26` — soften sessionStorage animation skip (fast fade vs instant).

### 4.8 Fix snap scrolling
- `page.tsx:20` — `snap-y snap-mandatory` can trap users. Change to `snap-proximity` or remove.

---

## Verification

After each wave, visually check with Playwright MCP:
- **Wave 1**: forms submit, mobile shows text, CTA visible, metadata correct in `<head>`, robots.txt/sitemap accessible
- **Wave 2**: contrast passes (DevTools audit), tab navigation works, focus rings visible, text readable
- **Wave 3**: social proof section renders, footer links work, mobile menu opens/closes
- **Wave 4**: `npm run build` succeeds, no console errors, security headers in response

Full check: `npm run build && npm run lint`

---

## Unresolved Questions
- snap scrolling: remove entirely or switch to `snap-proximity`?
- section numbers (01/02/03): keep as design element or remove?
- mobile menu style: overlay, slide-in, or dropdown?
- about/team section: add placeholder alongside social proof, or later phase?
