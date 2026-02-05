# Deep Analysis Template

When `--deep` flag is used, produce this full report structure.

## Required Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 DEEP ANALYSIS: [Idea Title]
Source: [URL or file path or "pasted text"]
Date: [YYYY-MM-DD]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## 🔍 Idea Viability — [🟢|🟡|🔴] [Verdict]

**What it is:** [2-3 sentence neutral summary of the core idea]

**Revenue model:** [How it makes money — recurring vs one-off, pricing approach, who pays]
**Market signals:** [Concrete demand evidence — search volume, existing spend, market size with source]
**Defensibility:** [Moat potential — tech, data, relationships, locale, switching costs]
**Risks:** [Top 2-3 risks that could kill it — be specific, not generic]

## ⚠️ Source Credibility — [🟢|🟡|🔴] [Verdict]

**Red flags detected:**
- 🚩 [Specific flag with evidence from the content]
- 🚩 [Specific flag with evidence from the content]

**Green flags:**
- ✅ [Specific credibility signal]

**Verdict:** [Is the source sharing real experience or selling a dream? Be direct.]

## 🏢 dotslash.dev Fit — [🟢|🟡|🔴] [Verdict]

Evaluate against BOTH segments separately:

### Segment A: AI Consulting Fit
**Service alignment:** [Could this become a consulting offering? Strategy sprint? Retainer service? Case study?]
**Client overlap:** [Does this serve tech teams/startups needing AI? Same buyer persona?]
**Credibility impact:** [Would building this demonstrate production AI expertise?]
**Engagement model:** [Project-based? Retainer? Fractional leadership?]

### Segment B: Productized SMB Fit
**Service alignment:** [Maps to which pricing tier? New offering or upsell to existing clients?]
**Market overlap:** [Does this serve Copenhagen SMBs? Same buyer persona as VVS/tandlæger/frisører?]
**Pricing fit:** [Compatible with 1,295-3,495 DKK/mo recurring model?]
**Scalability:** [Works at 10-20 clients, or requires mass scale?]

### Cross-Segment
**Tech leverage:** [Can you build with Hono/Bun/Claude API/K3s/Next.js? What's reusable across both?]
**Positioning impact:** [Strengthens or dilutes "AI that ships" brand?]
**Deal flow:** [Does this create flow between segments? SMB→consulting or consulting→product?]

## 🏟️ Competitive Landscape

**USE WebSearch to research this section. Do not speculate.**

**Direct competitors:**
- [Company/product] — [What they do, pricing, market, size]
- [Company/product] — [What they do, pricing, market, size]

**Indirect competitors:** [Adjacent solutions people use instead — spreadsheets, manual processes, agencies, etc.]
**Their weaknesses:** [Gaps dotslash.dev could exploit — no Danish support, overpriced, poor UX, enterprise-only]
**Your angle:** [What would make dotslash.dev's version different? Be specific.]

## 🇩🇰 Danish Market Lens

**USE WebSearch to research this section. Do not speculate.**

**Local demand signals:** [Danish search trends, local forums, Trustpilot reviews, industry reports]
**Regulatory considerations:** [GDPR implications, Danish business rules, industry-specific regs, data residency]
**Local competitors:** [Danish/Nordic players already doing this — check .dk domains, Danish directories]
**Cultural fit:** [Does this match how Danish SMBs buy? Trust-based selling? Janteloven-compatible? Price sensitivity?]
**Language barrier as moat:** [Does Danish-first execution give a real edge, or is English fine for this market?]

## 🛠️ Implementation Sketch

**MVP scope:** [Absolute minimum to validate — what you'd build in 1-2 weeks]
**Reusable from existing stack:**
- [Existing component] → [How it applies to this idea]
- [Existing component] → [How it applies to this idea]
**Net-new work:** [What doesn't exist yet — be honest about the gap]
**Timeline to MVP:** [Rough weeks, accounting for running the core business in parallel]
**Go/no-go signal:** [What specific result would prove this works before scaling? e.g., "3 paying customers in Copenhagen within 30 days"]

## 💰 Effort vs Payoff — [🟢|🟡|🔴] [Verdict]

**Build effort:** [What it actually takes — new skills, infrastructure, partnerships, regulatory compliance]
**Time to revenue:** [How fast could this generate first DKK? Be realistic]
**Revenue ceiling:** [What does this look like at 10, 50, 100 customers?]
**Opportunity cost:** [What you'd NOT be doing while pursuing this — be explicit about trade-offs]
**Compounding value:** [Does this get more valuable over time? Data flywheel? Network effects?]

## 🎯 Recommendation

[3-5 sentences. Clear actionable verdict:]
[- "Pursue: here's your first step"]
[- "Steal this one piece: X is valuable, ignore the rest"]
[- "Skip: here's why"]
[- "Park for later: revisit when X changes"]
[- "Explore more: research Y before deciding"]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Research Requirements

For `--deep` analysis, you MUST use actual research tools:

1. **WebSearch** for competitive landscape — find real companies, real pricing, real market data
2. **WebSearch** for Danish market — search in Danish when relevant ("AI chatbot virksomhed Danmark", etc.)
3. **WebFetch** if competitor URLs are found — get actual pricing/feature data
4. Do NOT fill these sections with speculation. If you can't find data, say "No data found" and note what to research manually.
