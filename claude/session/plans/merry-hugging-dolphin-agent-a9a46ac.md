# dotslash.dev Landing Page - Implementation Plan

## Overview
Build Swiss design inspired landing page for dev + AI consultancy with distinctive pixelated C logo with particle dispersion effect.

## Design Aesthetic
**Swiss/International Typographic Style:**
- Monochrome grayscale palette (pure black to near-white)
- Minimal, functional, clean
- Monospace section numbers (01, 02, 03)
- Sharp edges, no rounded corners
- Generous whitespace
- Grid-based layout

**Typography:**
- Use JetBrains Mono (monospace, code aesthetic) + IBM Plex Sans (technical, clean)
- NOT Inter, NOT Roboto - those are too generic
- Weight extremes: 200/300 for body, 600/700 for headings

**Logo (CRITICAL):**
- Pixelated/8-bit style letter "C" made of small black squares
- "./" text inside the C opening in clean font
- LEFT EDGE ONLY: dispersing particle effect (small black squares floating away)
- Subtle ambient animation (no hover, no mouse interaction)
- Creates "materializing" effect

## File Structure

```
/home/peterstorm/dev/web/dotslash.dev/
├── package.json ✓ (already created)
├── tsconfig.json
├── next.config.ts
├── tailwind.config.ts
├── postcss.config.mjs
├── .gitignore
├── app/
│   ├── layout.tsx
│   ├── page.tsx
│   ├── globals.css
│   └── fonts/
└── components/
    ├── Logo.tsx
    ├── Navigation.tsx
    ├── Hero.tsx
    ├── Services.tsx
    ├── About.tsx
    └── Contact.tsx
```

## Implementation Steps

### 1. Next.js Configuration Files
- `tsconfig.json` - TypeScript config with path aliases
- `next.config.ts` - Next.js 15+ config
- `tailwind.config.ts` - Grayscale palette, JetBrains Mono + IBM Plex Sans
- `postcss.config.mjs` - Tailwind + Autoprefixer
- `.gitignore` - Standard Next.js

### 2. CSS Variables & Global Styles (`app/globals.css`)
```css
:root {
  /* Grayscale palette */
  --color-black: #000000;
  --color-gray-900: #333333;
  --color-gray-800: #474747;
  --color-gray-700: #5C5C5C;
  --color-gray-600: #707070;
  --color-gray-500: #858585;
  --color-gray-400: #ADADAD;
  --color-gray-300: #C2C2C2;
  --color-gray-200: #D6D6D6;
  --color-gray-100: #E8E8E8;
  --color-gray-50: #F5F5F5;
  --color-near-white: #FAFAFA;

  /* Typography */
  --font-mono: 'JetBrains Mono', monospace;
  --font-sans: 'IBM Plex Sans', sans-serif;

  /* Animation easing */
  --ease-out-expo: cubic-bezier(0.16, 1, 0.3, 1);
}

/* Staggered page load animation */
.animate-stagger > * {
  opacity: 0;
  transform: translateY(20px);
  animation: fadeUp 0.6s var(--ease-out-expo) forwards;
}

.animate-stagger > *:nth-child(1) { animation-delay: 0ms; }
.animate-stagger > *:nth-child(2) { animation-delay: 100ms; }
.animate-stagger > *:nth-child(3) { animation-delay: 200ms; }
.animate-stagger > *:nth-child(4) { animation-delay: 300ms; }
.animate-stagger > *:nth-child(5) { animation-delay: 400ms; }

@keyframes fadeUp {
  to { opacity: 1; transform: translateY(0); }
}
```

### 3. Root Layout (`app/layout.tsx`)
- Load Google Fonts: JetBrains Mono + IBM Plex Sans
- Apply font CSS variables
- Metadata: title, description
- Clean HTML structure

### 4. Logo Component (`components/Logo.tsx`)
**Critical Implementation:**
- Canvas-based rendering or SVG with CSS animation
- Pixelated C shape: 2D array of pixel positions forming a "C"
- Inner "./" text centered in opening
- Particle system for LEFT EDGE:
  - ~20-30 particles
  - Each particle is small square (4-8px)
  - Float away from left edge with varying speeds/distances
  - Fade out as they disperse
  - Continuous loop, subtle ambient motion
- NO mouse interaction, NO hover effects
- requestAnimationFrame for smooth animation

**Approach:**
```tsx
// Pseudo-code structure
const Logo = () => {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas.getContext('2d');

    // Define C shape as pixel grid
    const cShape = [
      [1,1,1,1,1],
      [1,0,0,0,0],
      [1,0,0,0,0],
      // ... etc
    ];

    // Define particles for left edge
    const particles = generateLeftEdgeParticles();

    // Animation loop
    const animate = () => {
      // Clear canvas
      // Draw C pixels
      // Update and draw particles
      // Render "./" text
      requestAnimationFrame(animate);
    };

    animate();
  }, []);

  return <canvas ref={canvasRef} />;
};
```

### 5. Navigation Component (`components/Navigation.tsx`)
- Fixed top position
- Minimal: "./" logo left, nav links right
- Links: Services, About, Contact
- Smooth scroll behavior
- Transparent background with subtle backdrop blur

### 6. Hero Section (`components/Hero.tsx`)
- Full viewport height
- Centered logo (large, ~300-400px)
- "dotslash.dev" heading below logo
- Brief tagline: "Functional code. Domain-driven design. AI integration."
- Scroll indicator (subtle downward arrow)

### 7. Services Section (`components/Services.tsx`)
```
01
SERVICES

Grid of 4 services:
- Software Development
  Pure functions, immutable data, testable architecture

- AI Integration
  Practical AI, production-ready, maintainable systems

- System Architecture
  Domain-driven design, functional patterns, scalability

- Technical Consulting
  Code review, architecture validation, team guidance
```

### 8. About Section (`components/About.tsx`)
```
02
ABOUT

Philosophy:
- Functional programming principles
- Domain-driven design
- Immutable data structures
- Push I/O to edges
- 90%+ unit test coverage without mocks
- Property-based testing
```

### 9. Contact Section (`components/Contact.tsx`)
```
03
CONTACT

Simple form:
- Name
- Email
- Message
- Submit button

Email: hello@dotslash.dev
```

### 10. Main Page (`app/page.tsx`)
- Assemble all sections
- Apply staggered animation class
- Smooth scroll behavior

## Technical Considerations

**Performance:**
- Server Components by default
- Canvas animation runs client-side only
- Lazy load form validation
- Optimize fonts (subset if possible)

**Accessibility:**
- Semantic HTML
- ARIA labels where needed
- Keyboard navigation
- Focus indicators
- Skip to content link

**Animation Details:**
- Particle movement: translate + opacity fade
- Use CSS transforms for hardware acceleration
- Limit particle count for performance (~20-30)
- Debounce/throttle if adding any interactive elements

## Color Usage Strategy

Background: `#FAFAFA` (near white)
Text primary: `#000000` (black)
Text secondary: `#707070` (mid gray)
Borders/dividers: `#E8E8E8` (light gray)
Section numbers: `#5C5C5C` (darker gray)
Hover states: `#333333` (very dark gray)

## Typography Hierarchy

```
H1: 4rem (64px), font-mono, weight 700
H2: 3rem (48px), font-sans, weight 600
H3: 2rem (32px), font-sans, weight 600
Body: 1.125rem (18px), font-sans, weight 300
Mono (section #): 1rem (16px), font-mono, weight 400
```

## Dependencies Summary

From package.json already created:
- next: ^15.1.6
- react: ^19.0.0
- react-dom: ^19.0.0
- TypeScript + types
- Tailwind + PostCSS
- ESLint

No additional dependencies needed. Pure CSS animations + Canvas API.

## Unresolved Questions

1. Contact form - should it actually submit somewhere (email service, API route) or just validate client-side for now?
2. Logo canvas size - fixed dimensions or responsive? (suggest: fixed dimensions that scale via CSS transform)
3. Any specific copy/text for services descriptions beyond what's outlined?
4. Deploy target (Vercel, Netlify, self-hosted)?
