# dotslash.dev — Business Context

> Auto-generated from vault notes + website content. Refresh with `/idea-analyzer --refresh-context`
> Full details: See `business/smart_website_agency/dotslash.dev - Unified Business Identity.md` in the Obsidian vault
> Last updated: 2026-02-05

## Identity

**Brand:** dotslash.dev
**Tagline:** "AI that ships"
**Location:** Copenhagen, Denmark
**Entity:** Enkeltmandsvirksomhed (sole proprietorship), planned ApS conversion at scale
**Founder profile:** Senior software engineer — Haskell, Scala/ZIO, FP background. Runs own K3s homelab. Deep Claude API experience. Technical depth + business pragmatism.

## The Dual-Segment Model

dotslash.dev operates TWO complementary market segments under one brand. **Both segments must be weighted equally when evaluating idea fit.**

The unifying thread: production AI systems that solve real problems, delivered honestly.

---

### Segment A: AI Consulting

**Positioning:** "Production AI systems for teams who build." Premium, honest, vendor-neutral AI consultancy.

**Services:**
1. **AI Strategy & Advisory** — Build vs buy analysis, vendor/model evaluation, opportunity mapping, technical due diligence, roadmap planning
2. **Implementation & Engineering** — RAG systems, AI agents with guardrails, LLM integrations, evaluation infrastructure, data pipelines. Production-grade: monitoring, cost optimization, security
3. **Ongoing Partnership** — Fractional AI leadership, monthly retainer, team training via pair programming, knowledge transfer
4. **Process:** Discovery (1-2 weeks) → Advisory (2-4 weeks) → Implementation (variable) → Partnership (ongoing)

**Target clients:** Tech teams, startups, SMEs needing AI capabilities but lacking in-house expertise. Companies with failed POCs needing production rebuild. M&A due diligence.

**Pricing:** Not public — project-based fees, monthly retainers, fractional leadership engagements. Higher ticket than Segment B.

**Key differentiators:**
- "We'll tell you when NOT to use AI" — honest, anti-hype
- Production focus — not demos, not POCs
- No vendor lock-in — recommendations based on needs
- Knowledge transfer — build client capabilities, not dependency
- Deep technical credibility — FP/DDD, not just prompt engineering

**Revenue role:** Higher-ticket, funds operations while Segment B scales. Provides credibility (you run your own AI product).

---

### Segment B: Productized SMB Offering

**Positioning:** AI-powered websites + Danish-speaking chatbots for local Copenhagen businesses. Solves: SMBs lose customers outside business hours.

**Core value prop:** Danish SMBs lose 6,000-18,000 DKK/month in missed after-hours inquiries. A 24/7 AI agent captures those leads for 1,295-3,495 DKK/month.

**Three-tier pricing (DKK, excl. VAT):**

| Package | Monthly | Setup | Core |
|---------|---------|-------|------|
| Pakke 1: Professionel | 1,295 | 9,995 | 5-page website, hosting, basic chat |
| Pakke 2: Smart Vækst | 1,995 | 14,995 | Website + 24/7 AI chatbot (Danish), lead capture, SEO |
| Pakke 3: Digital Partner | 3,495 | 19,995 | Everything + priority support, review mgmt, strategy |

**Unit economics:** 70-180 DKK/month cost per client → 91-94% gross margins. Break-even at 3 clients.

**Target market:**
- Copenhagen SMBs, 1-10 employees
- Tier 1: VVS montører (plumbers), tandlæger (dentists), frisører (hairdressers)
- Tier 2: Advokater, revisorer, anlægsgartnere, malerfirmaer
- Geographic: Østerbro, Frederiksberg, Hellerup → Vesterbro, Nørrebro → Amager, Valby

**Revenue role:** Recurring revenue engine — scalable, high-margin, builds data flywheel. Each client makes the system smarter.

---

### Why Both Segments Reinforce Each Other

1. **Consulting funds the product** — higher-ticket revenue sustains while SMB scales
2. **Product validates consulting** — running your own AI product gives credibility
3. **Shared tech stack** — same Claude API expertise, K3s infra, production engineering
4. **Deal flow** — consulting clients may need productized solutions; SMB clients may need deeper strategy
5. **Brand coherence** — "AI that ships" works for both a chatbot for a plumber and a RAG pipeline for a startup

## Tech Stack (Shared)

**SMB product:** Hono on Bun (API), Preact + Shadow DOM (widget, <5KB), Claude Sonnet with prompt caching, PostgreSQL (multi-tenant), SSE streaming, Next.js dashboard, K3s (EU-hosted)

**Consulting delivery:** Same tools + client-specific tech. FP-first approach (Haskell, Scala/ZIO, TypeScript).

**Website (dotslash.dev):** Next.js 16, React 19, TypeScript, Tailwind CSS 4. Swiss minimalist design, grayscale-only.

## Go-to-Market (SMB)

- Phase 0: Build MVP (weeks 1-6)
- Phase 1: First 3 clients via Google Maps audits + door-to-door (weeks 7-14)
- Phase 2: Product-market fit, 8-12 clients (weeks 15-30)
- Phase 3: Scale to 15-20 clients, ApS conversion, geographic expansion (months 8-12)
- Year 1 target: 15-20 SMB clients + consulting revenue = 25-40K DKK/month profit

## Competitive Moat

1. Custom code — no platform dependency
2. Danish prompt expertise — language/locale as barrier
3. Conversation data flywheel — improves with usage
4. Local market knowledge — Copenhagen neighborhoods, Danish business culture
5. EU infrastructure — GDPR, data stays in Denmark
6. Production engineering credibility — FP/DDD, real systems
7. Dual-segment diversification — consulting smooths scaling risk

## What Makes an Idea a Good Fit

An idea scores well for dotslash.dev if it:

**For either segment:**
1. Strengthens "AI that ships" positioning
2. Leverages existing tech (Hono/Bun, Claude API, K3s, Next.js, PostgreSQL)
3. Generates recurring revenue or leads to recurring engagements
4. Has high margins (target 85%+)
5. Can be validated cheaply (days/weeks, not months)
6. Builds data/knowledge flywheel

**Segment A fit signals:**
7. Serves tech teams or businesses needing AI strategy/build
8. Can become a consulting offering or case study
9. Demonstrates production AI expertise
10. Could attract retainer/fractional leadership engagements

**Segment B fit signals:**
11. Serves Copenhagen SMBs or extends to adjacent local markets
12. Benefits from Danish-first execution (language as moat)
13. Can upsell existing SMB clients or attracts same buyer persona
14. Works at small scale (10-20 clients, not 10,000)
15. Fits the 1,295-3,495 DKK/month pricing envelope

**Cross-segment fit (highest score):**
16. Serves both segments — e.g., a product you sell to SMBs AND use as consulting credibility
17. Creates deal flow between segments
