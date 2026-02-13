# Plan: Build Landing Page Sections

## Overview

Add 3 sections to dotslash.dev following the Cadrian brand guidelines design reference.

## Design Reference Analysis

From `/home/peterstorm/Downloads/d227bf2ce4318c723d1de21ca2903617.webp`:

**Section layout pattern**:
```
┌─────────────────────────────────────────────────────────────┐
│ Brand Guidelines          Category              Page XX     │  ← header bar
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  01        Large Title          Description paragraph       │  ← main row
│            Here                 text goes here on the       │
│                                 right side, small text      │
│                                                             │
│            [Visual content / feature grid below]            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Sections to Build

### 1. Services (01)
- Software Development
- AI Integration
- Architecture Design
- Consulting

### 2. About (02)
- Philosophy: FP, DDD, testable code
- Approach description

### 3. Contact (03)
- Email display
- Contact form (server action)

## Implementation

### File Structure

```
app/
├── components/
│   ├── Section.tsx          # Reusable section wrapper
│   ├── SectionHeader.tsx    # Header bar component
│   ├── ServiceCard.tsx      # Service item display
│   └── ContactForm.tsx      # Form with server action
├── actions/
│   └── contact.ts           # Server action for form
└── page.tsx                 # Add sections below hero
```

### Component APIs

**Section.tsx** (Server Component)
```tsx
type SectionProps = {
  id: string;           // anchor link target
  number: string;       // "01", "02", "03"
  title: string;
  category: string;     // e.g., "Services"
  description: string;
  children: ReactNode;
  variant?: 'light' | 'dark';  // bg color flip
}
```

**SectionHeader.tsx** (Server Component)
```tsx
type SectionHeaderProps = {
  left: string;    // "dotslash.dev"
  center: string;  // category
  right: string;   // page indicator
}
```

**ServiceCard.tsx** (Server Component)
```tsx
type ServiceCardProps = {
  title: string;
  description: string;
  index: number;  // for stagger animation
}
```

**ContactForm.tsx** (Client Component - needs form interactivity)
```tsx
// Uses useActionState for form handling
// Server action in actions/contact.ts
```

### Layout Pattern per Section

Each section follows the reference grid:

```tsx
<section id="services" className="min-h-screen px-12 py-20">
  {/* Header bar */}
  <div className="flex justify-between text-[11px] text-gray-500 mb-16">
    <span>dotslash.dev</span>
    <span>Services</span>
    <span>01</span>
  </div>

  {/* Main content row */}
  <div className="flex gap-12">
    {/* Large section number */}
    <span className="text-[8rem] font-light leading-none">01</span>

    {/* Title + content */}
    <div className="flex-1">
      <h2 className="text-[3.5rem] font-bold mb-8">Services</h2>
      {/* Grid of service cards */}
    </div>

    {/* Description */}
    <p className="w-64 text-[11px] text-gray-600 leading-relaxed">
      Description text...
    </p>
  </div>
</section>
```

### Styling

**Colors** (alternating sections):
- Services (01): white bg (#fafafa)
- About (02): dark bg (#0f0f0f), white text
- Contact (03): white bg (#fafafa)

**Typography**:
- Section numbers: `text-[8rem] font-light` (thin weight)
- Titles: `text-[3.5rem] font-bold tracking-[-0.02em]`
- Descriptions: `text-[11px] text-gray-500 leading-relaxed`
- Header bar: `text-[11px] uppercase tracking-wider`

**Animation**:
- Intersection Observer for scroll-triggered fade-up
- Reuse existing `.animate-stagger` pattern
- Add `useInView` hook or CSS `animation-timeline: view()`

### Contact Form Server Action

```ts
// app/actions/contact.ts
'use server'

type ContactState = {
  success: boolean;
  message: string;
} | null;

export async function submitContact(
  prevState: ContactState,
  formData: FormData
): Promise<ContactState> {
  const email = formData.get('email') as string;
  const message = formData.get('message') as string;

  // Validate
  if (!email || !message) {
    return { success: false, message: 'All fields required' };
  }

  // TODO: Send email (Resend, SendGrid, etc.)
  console.log('Contact submission:', { email, message });

  return { success: true, message: 'Message sent' };
}
```

### Services Content

| Service | Description |
|---------|-------------|
| Software Development | Full-stack apps built with FP principles |
| AI Integration | LLM integration, agents, automation |
| Architecture Design | Domain modeling, system design |
| Consulting | Code review, team training, tech strategy |

### Navigation

Add smooth-scroll nav links in hero:
```tsx
<nav className="flex gap-6 text-[11px]">
  <a href="#services">01 Services</a>
  <a href="#about">02 About</a>
  <a href="#contact">03 Contact</a>
</nav>
```

## Verification

1. `npm run dev` - check all sections render
2. Scroll behavior - sections animate on scroll
3. Contact form - submit and check server action logs
4. Mobile - responsive layout (stack on small screens)
5. Lighthouse - check performance score

## Decisions

- **Email**: None for now, just console.log (add Resend later)
- **Navigation**: No fixed nav, keep minimal scroll-only
- **Services**: 2x2 grid layout
- **About content**: Placeholder text (can refine later)
