# Fix 1.1: Wire Contact Forms to Real Server Action

## Context
dotslash.dev has 3 contact form components. Two (`PixelContactSection`, `InlineContactSection`) use fake `setTimeout` handlers that simulate submission. One (`ContactForm`) correctly uses `useActionState` + `submitContact` server action but is unused. Goal: wire the two fake forms to the real server action following the ContactForm pattern.

## Approach
Switch both forms from controlled (`useState` + `value/onChange`) to uncontrolled (`name` attributes + `useActionState`). This aligns with Next.js server action conventions and removes unnecessary client state.

## Changes

### 1. `app/components/InlineContactSection.tsx`
- Remove all 4 `useState` hooks (`email`, `message`, `sending`, `sent`)
- Add `import { useActionState } from 'react'` and `import { submitContact, type ContactState } from '../actions/contact'`
- Add `useActionState<ContactState, FormData>(submitContact, null)` → `[state, formAction, pending]`
- `<form onSubmit={handleSubmit}>` → `<form action={formAction}>`
- Input/textarea: remove `value`/`onChange`, add `name="email"` / `name="message"`
- Button: `disabled={sending}` → `disabled={pending}`
- Success UI: replace `sent` boolean check with `state?.success` check (keep existing checkmark layout)
- Add error display: `state && !state.success` → show `state.message` in red
- Add `key={state?.success ? 'sent' : 'form'}` on `<form>` to reset fields on success

### 2. `app/components/PixelContactSection.tsx`
- Remove `useState` for `email`, `message`, `sending`
- Add same `useActionState` imports and hook
- **Desktop form** (line 675): `onSubmit={handleSubmit}` → `action={formAction}`
  - Input (line 683): remove `value={email} onChange={...}`, add `name="email"`
  - Textarea (line 698): remove `value={message} onChange={...}`, add `name="message"`
  - Button (line 723): `{sending ? "..." : ""}` → `{pending ? "..." : "→"}` (fix empty label)
  - Button: `disabled={sending}` → `disabled={pending}`
  - Add success/error message (absolute-positioned below button area, matching canvas aesthetic)
- **Mobile form** (lines 739-775): same pattern — `action={formAction}`, `name` attrs, uncontrolled
- Both forms share one `useActionState` hook (only one visible at a time via responsive classes)
- Add `key` prop for form reset on success
- Remove `handleSubmit` function entirely

### 3. `app/actions/contact.ts`
- No changes in this fix (improvements deferred to fix 1.2)

## What stays untouched
- All visual styling, CSS positioning, canvas logic, pixel animations
- Form field styles, placeholders, class names

## Verification
1. `npm run dev`
2. Desktop: submit PixelContactSection form → check server console for log, verify success message appears
3. Mobile: submit PixelContactSection mobile form → same checks
4. Service page: submit InlineContactSection → verify success checkmark UI, server log
5. Test validation: submit empty form → verify "All fields required" error displays
6. Test invalid email → verify "Invalid email" error displays
7. `npm run build` passes

## Unresolved
- none for 1.1, all decisions made
