# Plan: SSR Migration + Onboarding Route Split

## Goals
1. Make all possible pages/components SSR (server components)
2. Convert onboarding from single-page SPA to separate URL-routed pages
3. Browser back/forward works naturally

---

## Part 1: Onboarding → Separate Pages

### Routes
```
/onboarding/services   → Step 1: Service selection
/onboarding/kontakt    → Step 2: Personal info (phone)
/onboarding/detaljer   → Step 3: Current subscription details
/onboarding/resultat   → Step 4: Results/confirmation
```

### State: Layout Context
`app/onboarding/layout.tsx` — "use client", wraps all steps with `OnboardingProvider`
- Provides `FormData` + `updateFormData` via React Context
- Layout renders shared chrome: Header, HeroSection, StepProgress, NavigationControls
- Derives `currentStep` from `usePathname()`
- Next → `router.push()` to next route
- Back → `router.back()`
- `canProceed` validation lives in layout
- For `/onboarding/resultat`: detect path, render full-width layout (no hero sidebar) — simpler than nested layout override

### New file: `lib/onboarding-context.tsx`
- Move `FormData`, `SubscriptionType`, `CustomerType` types from `OnboardingFlow.tsx`
- `OnboardingProvider` + `useOnboarding()` hook

### New page files (server component shells)
Each is a thin server component rendering a client step component:
- `app/onboarding/services/page.tsx` → `<SubscriptionChoice />`
- `app/onboarding/kontakt/page.tsx` → `<PersonalInfoForm />`
- `app/onboarding/detaljer/page.tsx` → `<SubscriptionDetails />`
- `app/onboarding/resultat/page.tsx` → `<ResultsPage />`

### Refactor step components
- `SubscriptionChoice.tsx` — use `useOnboarding()` instead of props
- `PersonalInfoForm.tsx` — use context, drop `onNext` prop
- `SubscriptionDetails.tsx` — use context, drop `onNext`/`nextButtonText` props
- `ResultsPage.tsx` — use context, drop `formData`/`onUpdateFormData` props

### Entry points (service pre-selection)
- General CTA → `<Link href="/onboarding/services">`
- Service-specific → `<Link href="/onboarding/kontakt?service=mobile">`
- In layout: read `searchParams` on `/kontakt`, auto-set `formData.subscriptionTypes`

### Delete `components/OnboardingFlow.tsx`

---

## Part 2: SSR-ify Pages + Components

### Home page (`app/page.tsx`)
**Remove "use client"**. Currently client due to `useState` for `showOnboarding`. After onboarding moves to routes, no state needed:
- Replace `onStartOnboarding` callback with `<Link>` hrefs
- Replace `scrollToHowItWorks` ref with `<a href="#how-it-works">` (id-based scroll)
- Page becomes a server component importing client child components

### Landing page components
These all need "use client" (IntersectionObserver, hover state, etc.) but that's fine — they're client components *imported by* a server component page:

| Component | Stays client? | Changes needed |
|-----------|--------------|----------------|
| `Header.tsx` | Yes (mobile menu state) | Remove `onLogoClick` prop (always `<Link href="/">`) |
| `HeroSection.tsx` (front page) | Yes (hover state) | Replace `onStartOnboarding` → `<Link href="/onboarding/services">`, `onScrollToHowItWorks` → `<a href="#how-it-works">` |
| `HowItWorksPrototype.tsx` | Yes (IntersectionObserver) | Replace `onStartOnboarding` → `<Link>`. Drop `forwardRef`, add `id="how-it-works"` for scroll target |
| `ServicesPrototype.tsx` | Yes (hover + useInView) | Replace `onStartOnboarding("mobile")` → `<Link href="/onboarding/kontakt?service=mobile">` etc. |
| `TrustSection.tsx` | Yes (useInView) | No changes needed |
| `CTASection.tsx` | Yes (useInView) | Replace `onStartOnboarding` → `<Link>`. Remove prop |
| `Footer.tsx` | **Already SSR** | No changes |

### Static pages
Check each for unnecessary "use client":

| Page | Currently | After |
|------|-----------|-------|
| `/faq` | Client (search + accordion state) | **Keep client** |
| `/om-os` | Need to check | Remove "use client" if static |
| `/kontakt` | Need to check | Remove "use client" if static |
| `/presse` | Need to check | Remove "use client" if static |
| `/support` | Need to check | Remove "use client" if static |
| `/privatlivspolitik` | Need to check | Remove "use client" if static |
| `/handelsbetingelser` | Need to check | Remove "use client" if static |
| `/virksomhed` | Need to check | Remove "use client" if static |
| `/hvordan-fungerer` | Need to check | Remove "use client" if static |

---

## Implementation Order

1. Create `lib/onboarding-context.tsx` (types + context)
2. Create `app/onboarding/layout.tsx` (shared chrome + provider)
3. Create 4 page files under `app/onboarding/`
4. Refactor step components to use context
5. Refactor `onboarding/HeroSection.tsx`, `StepProgress.tsx`, `NavigationControls.tsx` for layout
6. SSR-ify home page: remove "use client", convert callbacks to Links
7. Refactor landing components (Header, HeroSection, HowItWorks, Services, CTA) — remove callback props, use Links
8. SSR-ify static pages where possible
9. Delete `OnboardingFlow.tsx`
10. Build + test

---

## Files Changed

| File | Action |
|------|--------|
| `lib/onboarding-context.tsx` | **NEW** |
| `app/onboarding/layout.tsx` | **NEW** |
| `app/onboarding/services/page.tsx` | **NEW** |
| `app/onboarding/kontakt/page.tsx` | **NEW** |
| `app/onboarding/detaljer/page.tsx` | **NEW** |
| `app/onboarding/resultat/page.tsx` | **NEW** |
| `app/page.tsx` | Remove "use client", use Links |
| `components/SubscriptionChoice.tsx` | Use context |
| `components/PersonalInfoForm.tsx` | Use context |
| `components/SubscriptionDetails.tsx` | Use context |
| `components/ResultsPage.tsx` | Use context |
| `components/Header.tsx` | Remove onLogoClick, always use Link |
| `components/HeroSection.tsx` | Callbacks → Links |
| `components/HowItWorksPrototype.tsx` | Callbacks → Links, drop forwardRef |
| `components/ServicesPrototype.tsx` | Callbacks → Links |
| `components/CTASection.tsx` | Callback → Link |
| `components/onboarding/HeroSection.tsx` | Accept step via props from layout |
| `components/onboarding/StepProgress.tsx` | Accept step via props from layout |
| `components/onboarding/NavigationControls.tsx` | Use router.push/back |
| `components/OnboardingFlow.tsx` | **DELETE** |
| Static pages | Remove "use client" where possible |

---

## Verification
1. `npm run build` — no errors, check page rendering mode (○ static, λ SSR)
2. Navigate full onboarding flow → URL changes each step
3. Browser back button → returns to previous step with form data preserved
4. Service card click → `/onboarding/kontakt?service=mobile` with pre-selected service
5. Full page reload mid-flow → data resets (expected), page renders
6. Home page loads without JS initially (SSR)
7. All static pages render server-side
