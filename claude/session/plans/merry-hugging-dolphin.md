# dotslash.dev Landing Page

## Design Vision
Swiss/International Typographic Style - monochrome, minimal, functional. The hero is a pixelated C logo with "./" inside and subtle left-edge particle dispersion.

## Reference Images
- `/home/peterstorm/Downloads/Whisk_73a878186a03ad1a35d4a294a2ef68cceg.png` - Hero logo (pixelated C with ./ inside, particles dispersing on left edge)
- `/home/peterstorm/Downloads/d227bf2ce4318c723d1de21ca2903617.webp` - Brand guidelines (grayscale palette, typography, texture system)

## Tech Stack
- Next.js 16 (App Router)
- TypeScript
- Tailwind CSS
- pnpm

## Color Palette (from brand guidelines)
```
#000000 → #333333 → #474747 → #5C5C5C → #707070 → #858585
#ADADAD → #C2C2C2 → #D6D6D6 → #E8E8E8 → #F5F5F5 → #FAFAFA
```

## Files to Create

```
dotslash.dev/
├── package.json
├── tsconfig.json
├── next.config.ts
├── tailwind.config.ts
├── postcss.config.mjs
├── app/
│   ├── layout.tsx       # Fonts, metadata
│   ├── page.tsx         # Landing page
│   └── globals.css      # CSS variables, animations
└── components/
    └── PixelLogo.tsx    # Canvas-based animated logo
```

## Logo Implementation (Critical)

Canvas-based pixelated C with "./" inside:
1. Define C shape as 2D pixel grid (small black squares)
2. Render "./" text centered in C opening
3. LEFT EDGE ONLY: ~20-30 particles that:
   - Float/drift away from main shape
   - Fade as they disperse
   - Continuous subtle loop
   - NO hover, NO mouse interaction

Animation: `requestAnimationFrame`, CSS transforms for GPU acceleration

## Page Sections

1. **Hero** - Full viewport, centered logo, "dotslash.dev" title, tagline
2. **Services (01)** - Software Dev, AI Integration, Architecture, Consulting
3. **About (02)** - FP principles, DDD, testable code philosophy
4. **Contact (03)** - Simple form + email

## Implementation Steps

1. Init Next.js 16 project (move flake files, run create-next-app, restore)
2. Spawn frontend-agent WITH image paths so it can view the exact design:
   - Read `/home/peterstorm/Downloads/Whisk_73a878186a03ad1a35d4a294a2ef68cceg.png` (hero logo)
   - Read `/home/peterstorm/Downloads/d227bf2ce4318c723d1de21ca2903617.webp` (brand guidelines)
3. Agent builds: Tailwind config, globals.css, PixelLogo component, page sections
4. Test and refine

## Verification
- `pnpm dev` → localhost:3000
- Logo animates subtly on load (particles drift on left edge)
- Page loads with staggered reveal animation
- All sections render with correct typography/colors
- Responsive on mobile

## Decisions Made

- **Typography**: JetBrains Mono + IBM Plex Sans (more distinctive, code-aesthetic)
- **Contact form**: Visual only for now
- **Logo size**: ~400px, scales via CSS
