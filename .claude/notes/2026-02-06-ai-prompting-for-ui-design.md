# AI Prompting for UI Design — Mastering the Vocabulary

**Source:** https://youtu.be/M-uUFLU9IFU
**Date:** 2026-02-06
**Speaker:** Meng To (Aura / Design+Code)

## TL;DR

A designer's guide to prompting AI for high-quality UI design. Covers the specific vocabulary — layout types, styling (flat/outline/glass), typography (font pairing, sizing, spacing), shadows, and animations — needed to get production-quality results from AI design tools. Demos everything using "Aura," the speaker's own prompt-to-HTML/CSS tool.

## Key Takeaways

1. **Prompting = knowing the vocabulary.** Better results come from using precise design terms (e.g. "shadow-2xl", "outline style", "sequence animation with fade, scale, slide") rather than vague descriptions
2. **Keep prompts simple and iterative.** Don't write 500-word prompts — change one thing at a time (dark mode, then shadow, then font). AI makes more mistakes with complex multi-instruction prompts
3. **Start from templates/forks, not from scratch.** Use existing code from CodePen, 21st.dev, or component libraries as a baseline, then prompt AI to remix/customize
4. **Font pairing matters:** Use serif for headings + sans-serif (Inter, Geist) for body. Smaller fonts for cards/dense layouts, larger for hero sections
5. **Beautiful shadows use multiple layers** — not just single CSS box-shadow. Tailwind terms (shadow-2xl) give AI better precision than raw CSS
6. **Outline style > flat** for modern apps (Apple, Linear, Vercel aesthetic) — helps with depth when layering elements
7. **Open-source libraries to name-drop in prompts:** Cobe (globe), Vanta.js (backgrounds), tsParticles (particles), Matter.js (physics), Codrops (advanced effects)

## Section Breakdown

### Intro & Context [00:00]
Speaker has done 10,000+ prompts, built Aura and DreamCut (100K+ lines each). Aura generates designs from prompts using HTML/CSS with live preview — positioned as simpler than React-based tools (v0, Lovable) for beginners.

### Prompt Builder Basics [03:30]
Aura's prompt builder has 800+ templates across layout types (hero, features, mobile, cards), framing options (card, browser frame, drop shadow), and configuration. Removes barrier to entry — click instead of type.

### Styling: Flat, Outline, Glass, Minimal [09:22]
Flat = 99% of basic websites. Outline = modern apps (Apple, Linear, Figma) — better for depth with layered elements. Minimal = more spacing/padding, less clutter. Glass = iOS/macOS translucency. Light/dark mode toggle via Tailwind color codes.

### Shadows [11:56]
Single Tailwind shadows (shadow-md, shadow-2xl) are basic. "Beautiful shadows" use multiple layered shadows (double, triple, colored, inner) — the design detail that makes Twitter-viral designs pop. Tailwind terms give AI better control than raw CSS.

### Typography [21:46]
Font families: sans (99% of apps), serif (titles/traditional), monospace (code/futuristic), condensed (posters), rounded (fun/kids). Font pairing: serif heading + sans body works; all-serif only for newspaper/book apps. Sizing: smaller for dense card layouts, larger for hero sections. Letter spacing: tight/tighter for titles, normal for body.

### Animation [27:02]
Main types: fade, slide, scale, blur, 3D, bounce. Sequencing: "all at once" vs "sequence" (staggered with 0.1s delay) vs "word by word" vs "letter by letter." Timing: ease-out most common; spring for bounciness. AI struggles more with animation than static design — requires more precise prompting.

### Advanced: Forking Open-Source Code [31:21]
Core technique: find code on CodePen or component libraries -> paste into AI tool -> prompt "adapt for [your use case]." Fork, don't copy verbatim. The code from HTML/CSS sources (CodePen, Aura) is more AI-friendly than React component libraries (21st.dev) which have hidden imports.

### Libraries to Name-Drop [39:00]
Cobe (interactive globe), Vanta.js (animated backgrounds), tsParticles (particle effects), Matter.js (physics engine), Codrops (advanced CSS effects with GitHub repos). Mentioning library names in prompts works because AI knows popular libraries.

## Notable Quotes

- "Prompting is all about knowing what to say in the most technical term possible in which, as accurate as possible, the AI is able to understand you."
- "The first time you taste coffee, you don't know all the nuances... The same with design."
- "Don't try to come up with 500 words in a prompt. Most likely AI is going to do a lot more wrong than right."

## Resources Mentioned

- Aura — AI design generator with prompt builder
- CodePen (codepen.io) — open-source HTML/CSS/JS examples
- 21st.dev — React component library
- Cobe — JS globe library
- Vanta.js — animated background library
- tsParticles — particle effects
- Matter.js — 2D physics engine
- Codrops — advanced CSS/JS experiments
- GPT-4.1 and Claude 3.7 Sonnet — recommended models
