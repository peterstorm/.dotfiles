---
name: wardrobe-asset-production
description: "Builds and qualifies versioned wardrobe reference packages for locked fictional characters. Use when designing or generating pilot suits, uniforms, performance outfits, everyday looks, costume turnarounds, front and rear wardrobe plates, construction close-ups, or downstream character sheets. Owns approval gates, rear-construction authorship, one-visible-face rules, workflow/output versioning, serialized image lineage, and visible evidence acceptance. Pairs with character-builder for prompt grammar and Krea 2 for local still generation."
license: MIT
compatibility: "Pi project skill for local Krea 2 image generation and evidence-backed visual inspection."
---

# Wardrobe Asset Production

A wardrobe is not locked by one attractive front portrait. Production needs visible evidence for silhouette, rear construction, materials, interfaces, footwear, and identity continuity.

This skill owns:

`text proposal → approval → front plate → front acceptance → rear plate → rear acceptance → close-up sheets → package acceptance → optional character sheet`

It complements `character-builder`. That skill owns character and prompt grammar; this skill owns package completeness, versioning, lineage, and acceptance.

## Ubiquitous language

- **Wardrobe proposal** — the head-to-toe text specification approved before generation.
- **Front plate** — one direct full-body front view with the locked identity and exactly one visible face.
- **Rear plate** — one direct full-body rear view with the face entirely invisible.
- **Construction close-up** — a face-free image proving a named garment material, seam, interface, closure, or footwear detail.
- **Wardrobe package** — the accepted front plate, rear plate, required close-ups, prompts, seeds, histories, checksums, and acceptance ledger for one look.
- **Lineage parent** — the accepted image used as the explicit reference for the next generation.
- **Version** — an immutable numbered attempt such as `pilot-suits-02`; a later version never overwrites an earlier version.
- **Visible evidence** — pixels inspected in the generated asset, not claims in a prompt, filename, or successful queue response.

## Hard rules

1. **Approve text first.** Do not generate a new outfit before the user approves its wardrobe proposal.
2. **Version instead of overwrite.** A changed construction, workflow, prompt system, model path, or accepted source creates a new numbered workflow and output directory. Preserve earlier requests, histories, images, rejection notes, and checksums.
3. **Front first.** Generate and inspect the front plate before using it as the lineage parent for rear or detail assets.
4. **Author unseen construction.** A face portrait cannot define body proportions, footwear, rear hair, or rear wardrobe. Specify every required unseen detail in text before it can become canon.
5. **One visible face.** The front plate contains exactly one visible face. Rear and detail assets contain no visible face, reflections, inset portraits, duplicated heads, or source-image displays.
6. **Separate assets preserve resolution.** Do not crowd front, rear, face, and construction details into one low-resolution grid. The default package uses separate front and rear plates plus dedicated close-up sheets.
7. **Explicit lineage.** Rear generation references the accepted front plate. Close-ups reference the accepted plate that visibly contains the relevant construction. Never silently swap a lineage parent.
8. **Local-only generation.** Use the locally installed Krea 2 family through serialized `creative-model-phase` ownership. Do not substitute a hosted generator.
9. **Prompt success is not acceptance.** Queue success, clean decode, and checksums prove technical completion only. Inspect every asset visually.
10. **Fail closed.** Missing or ambiguous construction is `UNVERIFIABLE`, never `PASS`.

## Stage 0 — proposal and version gate

Record:

- character and canonical identity source;
- wardrobe category and approved proposal;
- new immutable version identifier;
- model, precision path, workflow revision, seed policy, and output root;
- prior version and reason for superseding it;
- front, rear, material, interface, and footwear invariants.

A minor rerun with a new seed stays inside the same version as a documented retry. A changed design or workflow contract starts a new version.

## Stage 1 — front plate

Generate one direct, squared full-body front view in a tall vertical frame:

- crown through both boot soles visible with neutral margin;
- locked face and front hair identity from the canonical reference;
- relaxed symmetrical stance, hands clear of critical interfaces;
- complete front construction, materials, seals, sockets, and footwear readable;
- flat 18% neutral-gray field and shadowless reference illumination;
- no props, helmet, cockpit, text, logo, duplicate, collage, or extra person.

### Front acceptance

Inspect at full frame and useful crops. `PASS` requires:

- exactly one person, one body, and one visible face;
- face and front hair remain recognizably canonical;
- approved silhouette and palette are present;
- every named front interface is visible and correctly placed;
- both hands, legs, and boots are anatomically coherent;
- footwear is fully in frame;
- material reads as specified rather than generic fashion, armor, latex, or painted skin;
- background and light are clean enough for downstream reference use.

Reject or mark `UNVERIFIABLE` before proceeding if any critical invariant fails.

## Construction-first outfit-transfer repair

Use this path only after one or more direct character builds visibly round a custom outfit toward generic construction, omit critical interfaces, or trade identity against wardrobe fidelity.

1. Generate a complete **faceless front suit plate** on a smooth featureless fit mannequin. The blank head and body form carry only scale and worn volume; they carry no identity, skin, hair, or facial information.
2. Generate the matching **faceless rear suit plate** from the accepted faceless front plus the authored rear specification.
3. Accept front and rear construction before identity transfer. These plates become the wardrobe authority.
4. Run a two-reference outfit transfer. The canonical portrait carries only face, skin, front hair identity, and beauty register. The accepted faceless front suit plate carries only suit construction, materials, palette, fit, pose, and footwear.
5. State both reference roles explicitly and reject any averaging: no mannequin face or material enters the character identity, and no portrait clothing enters the suit.
6. The transferred character front is the sole faced wardrobe output. Rear construction and close-up sheets remain faceless unless a later story need explicitly requires another identity-bearing view.

This is a repair path, not the default. Do not create mannequin plates preemptively for ordinary outfits. Once direct generation has visibly failed, however, repeating the same direct path with prompt inflation is lower leverage than separating construction from identity.

### Outfit-transfer acceptance

`PASS` requires the canonical face and front hair identity, exact accepted suit silhouette and construction, complete footwear, one person, one body, and one visible face. Reject mannequin facial geometry, blended wardrobe, portrait clothing leakage, duplicated accessories, missing suit interfaces, or altered palette.

### Optional FLUX.2 Klein A/B finish

When requested, preserve two explicit identity-bearing front outputs:

- **A — Krea base:** the accepted outfit-transfer result with no finishing model.
- **B — Klein finish:** a conservative FLUX.2 Klein 9B BF16 pass whose sole job is photographic face/material refinement.

B must use A as its direct parent and preserve exact face geometry, identity, expression, front hair, body proportions, pose, suit construction, palette, interfaces, footwear, composition, gray field, and medium. It may refine pores, hair strands, woven fibers, and hardware surfaces; it may not beautify, redesign, relight, restyle, add text, or change anatomy. Archive and checksum both. Klein never silently replaces A, and its non-commercial license status remains attached to B's manifest.

Identity modifiers are provenance, not generic realism filters. Record whether the canonical source already contains FameGrid or another identity modifier and inherit that source exactly. Never silently reapply a baked modifier. Applying a modifier to a member whose selected source did not contain it creates a separately labelled non-canonical comparison, not a canonical realism pass.

## Stage 2 — rear plate

For the direct path, use the accepted front plate as the lineage parent. For the repair path, use the accepted faceless front suit plate. Generate one direct 180-degree rear view:

- full figure from crown through boot soles;
- face completely invisible and head not turned toward camera;
- authored rear hair construction visible without inventing a face;
- rear seam map, closures, dorsal interfaces, seat couplers, heel construction, and sole segmentation readable;
- front palette and material system preserved exactly;
- no second view, inset, source-image display, reflection, text, or face.

### Rear acceptance

`PASS` requires consistent body proportions, palette, material, boot pair, rear hair specification, and every named rear interface. A plausible but unspecified rear design is not canon; either document and approve it or reject it.

## Stage 3 — close-up evidence

Prefer deterministic high-resolution crops from an accepted front or rear plate whenever the required construction is already visible. Crops preserve exact geometry and cannot invent pseudo-text, belts, interfaces, or hardware. Use a generative close-up only when the source genuinely lacks enough pixels or the required detail was never visible; that new detail must pass a separate authorship and acceptance gate.

Produce face-free close-ups as separate images. Default coverage:

1. **Upper-interface sheet** — collar/shoulder seal, sternum or chest node, clavicle sockets, and dorsal upper-spine construction as applicable.
2. **Control-and-footwear sheet** — forearm haptic surface, wrist seal, hip or tool sockets, ankle seal, magnetic boot, segmented sole, and heel/coupler details.

Each close-up has two or three large panels maximum. Every panel names one visible job. Do not include beauty portraits or repeat a full body merely to fill space.

### Close-up acceptance

- panel count matches the request;
- no face or unrelated body appears;
- the detail belongs to the accepted front/rear design;
- geometry is mechanically coherent at close range;
- material, color, scale, side, and orientation match the parent plate;
- no decorative interface is accepted as functional unless its mating purpose is documented.

## Stage 4 — package acceptance

Create an acceptance ledger:

| Asset | Parent | Required evidence | Result | Proof file/crop | Notes |
|---|---|---|---|---|---|

A wardrobe package passes only when:

- front, rear, and required close-ups pass visual inspection;
- prompts, seeds, request graphs, histories, source references, outputs, and checksums are preserved;
- every accepted file is below any synchronization limit or remains in the documented local archive;
- rejected retries remain preserved and explicitly barred from downstream resolver inputs;
- the package manifest identifies exactly one accepted file per asset role.

## Optional character sheet

A character sheet is downstream of the accepted wardrobe package, not a replacement for it. Use a strict one-visible-face layout. The package's dedicated front, rear, and close-up assets remain the higher-resolution construction authority.

## Pre-delivery checklist

- [ ] Text proposal explicitly approved
- [ ] New immutable version selected; no prior evidence overwritten
- [ ] Canonical identity source and lineage parents recorded
- [ ] Front plate visually accepted before rear generation
- [ ] If direct construction failed, faceless front/rear plates were accepted before two-reference outfit transfer
- [ ] Outfit transfer assigns identity and wardrobe to separate references without averaging
- [ ] Rear construction authored rather than inferred from a face crop
- [ ] Exactly one visible face in front; zero in rear and close-ups
- [ ] Upper-interface and control/footwear details visibly proved
- [ ] Prompts, seeds, requests, histories, outputs, and checksums archived
- [ ] Every critical row is `PASS`; no `UNVERIFIABLE` promoted to canon
