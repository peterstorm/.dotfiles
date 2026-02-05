# Service Pages Implementation Plan

## Overview
Add 4 consulting-focused pages to dotslash.dev with consistent Swiss minimalist design.

## Routes
```
/services/ai-strategy      - AI Strategy & Advisory
/services/implementation   - Implementation & Engineering
/services/partnership      - Ongoing Partnership
/how-we-work              - 4-phase consulting process
```

## File Structure
```
app/
├── (services)/
│   ├── layout.tsx              # Shared header + footer
│   ├── services/
│   │   ├── ai-strategy/page.tsx
│   │   ├── implementation/page.tsx
│   │   └── partnership/page.tsx
│   └── how-we-work/page.tsx
├── components/
│   ├── PageHeader.tsx          # Nav header with logo + back link
│   ├── ServicePageHero.tsx     # Hero section for service pages
│   ├── ContentBlock.tsx        # Reusable content section
│   └── ProcessStep.tsx         # Timeline step for how-we-work
├── lib/
│   └── services-data.ts        # Typed content data
└── page.tsx                    # Update service cards to link
```

## Key Design Decisions
- **Static routes** (not dynamic) - only 4 pages, each has unique structure
- **Traditional scroll** (not snap) - content pages need flexible reading
- **Shared layout** - consistent navigation across all service pages
- **Reuse existing patterns** - Section component style, color palette, typography
- **Full card clickable** - homepage service cards are entire links
- **No DotPattern** - keep service pages clean, no canvas animations
- **Inline contact form** - embed PixelContactSection at bottom of each page

## Components

### PageHeader
- Left: Small PixelLogo (28px) + "dotslash" → links to `/`
- Right: "Back to home" or nav links
- Border-bottom: `border-[#e0e0e0]`

### ServicePageHero
- Large section number (01/02/03)
- Title + tagline
- Optional DotPattern background for visual interest

### ContentBlock
- Title + body content
- Light/dark variants
- List items with consistent styling

### ProcessStep
- Number + title + duration
- Description + deliverables
- Connecting visual between steps

## Page Content

### /services/ai-strategy
1. Hero: "AI Strategy & Advisory"
2. What we help with: build vs buy, vendor evaluation, opportunity mapping
3. How we work: discovery workshops, honest guidance, no vendor lock-in
4. Engagements: one-off (2-4 wks), monthly retainer, fractional leadership
5. Inline PixelContactSection

### /services/implementation
1. Hero: "Implementation & Engineering"
2. What we build: RAG, agents, LLM integrations, evaluation infra
3. What we DON'T build: unmaintainable POCs, demo-only systems
4. Technical focus areas
5. Inline PixelContactSection

### /services/partnership
1. Hero: "Ongoing Partnership"
2. Fractional AI leadership model
3. Monthly retainer benefits
4. Team training & architecture reviews
5. Inline PixelContactSection

### /how-we-work
1. Hero: "How We Work"
2. Process timeline: Discovery → Advisory → Implementation → Partnership
3. Each phase details with deliverables
4. Key differentiator: "We'll tell you when NOT to use AI"
5. Inline PixelContactSection

## Homepage Updates (MINIMAL)
Only changes:
1. Wrap existing service cards in `<Link>` tags (add href, no visual change)
2. Update services array text to match new page titles

**NO changes to:**
- Layout, design, or styling
- Hero section
- About/Contact sections
- Any existing components
- Animations or functionality

## Styling
- Colors: grayscale only (`#1a1a1a`, `#f5f5f5`, `#666`, `#999`)
- Typography: JetBrains Mono (numbers), IBM Plex Sans (text)
- Sharp edges, no rounded corners
- Section numbers: `text-[5rem] font-light`
- Titles: `text-[2.5rem] font-bold`

## Implementation Order
1. Create route group `(services)` + shared layout
2. Create PageHeader component
3. Create services-data.ts with all content
4. Implement ai-strategy page (template for others)
5. Implement implementation + partnership pages
6. Create ProcessStep + implement how-we-work
7. Update homepage service cards to link

## Verification
1. `npm run build` - all routes compile
2. Navigate each route, verify styling matches homepage
3. Test back navigation from each page
4. Check responsive layout on mobile
5. Verify links from homepage cards work
