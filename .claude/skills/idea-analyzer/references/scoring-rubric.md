# Scoring Rubric

## Dimension 1: Idea Viability

Assess whether the business idea itself has merit, independent of who's presenting it.

### 🟢 Strong
- Clear revenue model with proven demand (people already pay for this or close substitutes)
- Addressable market is real and reachable (not theoretical TAM hand-waving)
- Some form of defensibility exists (tech, data, relationships, regulatory, language/locale)
- Unit economics make sense at small scale (don't need 10K customers to break even)
- Problem is painful and frequent (not a "nice to have")

### 🟡 Explore Further
- Revenue model exists but unproven or requires validation
- Market demand has signals but not conclusive evidence
- Defensibility is weak but possible to build over time
- Unit economics work but margins are thin or require scale
- Problem is real but severity/frequency is uncertain

### 🔴 Skip
- No clear revenue model or relies entirely on future speculation
- Market is saturated with well-funded competitors and no clear differentiation
- Zero defensibility — anyone can replicate in days
- Unit economics don't work without massive scale
- Solution looking for a problem

## Dimension 2: Hype/BS Score

Assess source credibility. See [hype-detection.md](hype-detection.md) for detailed patterns.

### 🟢 Low Risk (Credible)
- 0-1 red flags, multiple green flags
- Practitioner with verifiable track record

### 🟡 Medium Risk (Cautious)
- 2-3 red flags, some green flags
- Mixed incentives — genuine knowledge but also selling something

### 🔴 High Risk (Hype Trap)
- 4+ red flags, few/no green flags
- Primary business is selling the dream, not doing the thing

## Dimension 3: dotslash.dev Fit

Assess alignment with the user's actual business. Load context from [business-context.md](business-context.md).

### 🟢 Strong Fit
- Directly serves Copenhagen SMB target market (or expands it naturally)
- Leverages existing tech stack (Hono/Bun, Claude API, K3s, Next.js)
- Compatible with current pricing model (1,295-3,495 DKK/mo recurring)
- Strengthens "AI that ships" positioning
- Can be offered as upsell to existing clients or attracts same buyer persona
- Danish language/market knowledge is a genuine moat

### 🟡 Explore Further
- Adjacent market that could be reached with moderate effort
- Requires some new tech but core stack is reusable
- Pricing model needs adjustment but not a complete rethink
- Doesn't dilute brand but doesn't clearly strengthen it either
- Could work in Danish market but not obviously advantaged

### 🔴 Poor Fit
- Different target market entirely (enterprise, B2C consumer, non-Danish)
- Requires completely different tech stack or expertise
- Incompatible pricing model (one-off, marketplace, ad-supported)
- Dilutes "AI that ships" focus — feels like distraction
- No Danish market advantage — competing globally against bigger players

## Dimension 4: Effort vs Payoff

Rough signal on whether the opportunity is worth the resource investment.

### 🟢 High Payoff
- Can validate with minimal new work (days, not months)
- Leverages something already built — marginal effort for new revenue
- Clear path from MVP to paying customers
- Recurring revenue potential
- Low opportunity cost — doesn't block core business development

### 🟡 Medium
- Requires meaningful new development (weeks of work)
- Revenue potential exists but timeline to first dollar is uncertain
- Some opportunity cost — time spent here = time not spent on core offering
- Needs market validation before building

### 🔴 Low Payoff
- Requires months of new development with uncertain demand
- One-off revenue or low margin at achievable scale
- High opportunity cost — would significantly delay core business
- Market validation itself is expensive or slow
- Requires skills/resources the user doesn't currently have

## Verdict Labels

Choose the most appropriate actionable label:

| Label | When to use |
|-------|------------|
| **Strong fit** | 🟢 on viability + fit, no 🔴 on hype |
| **Explore further** | Mix of 🟢/🟡, worth investigating more |
| **Steal one piece** | Overall idea is meh, but one specific element is valuable |
| **Park for later** | Good idea but wrong timing — revisit when X changes |
| **Skip** | 🔴 on viability or fit, not worth time |
| **Hype trap** | 🔴 on hype score — the idea may be fine but this source is unreliable, find better sources |
