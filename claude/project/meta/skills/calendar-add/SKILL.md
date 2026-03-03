---
name: calendar-add
description: "Add events to iCloud calendar by writing .ics files and triggering vdirsyncer sync. Use when user asks to 'add to calendar', 'create an event', 'schedule X on Tuesday', 'put this on the calendar', or any request to create a calendar event."
allowed-tools: Read, Bash, Write, Glob
---

# iCloud Calendar Event Creator

Creates calendar events by writing .ics files to the local vdirsyncer-synced iCloud calendar directory, then triggering a sync to push to iCloud.

## Calendar Setup

- **Default calendar (J & P):** `~/.local/share/calendars/icloud/D8C2180E-3AD0-406E-9B55-23DA5F2CC674/`
- **Timezone:** `Europe/Copenhagen`
- **Sync command:** `systemctl --user start vdirsyncer-sync.service`
- **Sync direction:** Bidirectional (local writes push to iCloud on next sync)

## Input Parsing

Parse `$ARGUMENTS` or conversational context for:

1. **Event title** — what the event is (e.g., "dinner at mom's", "dentist appointment")
2. **Date** — when it happens, supporting semantic expressions:
   - Relative: "today", "tomorrow", "in 2 days", "next week"
   - Named days: "this Tuesday", "next Friday", "on Saturday"
   - Absolute: "March 5th", "2026-03-15", "15/3"
3. **Time** — start time of the event:
   - 24h: "14:30", "09:00"
   - 12h: "2:30pm", "9am"
   - Named: "noon", "midnight"
   - If no time given, default to **all-day event**
4. **Duration** — how long (optional):
   - Explicit: "for 2 hours", "1h30m", "90 minutes"
   - Default: **1 hour** for timed events
5. **Location** — optional, if mentioned (e.g., "at Cafe Noir", "in meeting room 3")

## Date Resolution

Use the current date (`{{date}}` or system date) as reference. Always resolve forward:
- "Tuesday" when today is Sunday = this coming Tuesday (2 days)
- "Tuesday" when today is Wednesday = next Tuesday (6 days)
- "next Tuesday" always = Tuesday of next week

Compute the actual date as `YYYYMMDD` format for the .ics file.

## .ics File Generation

Generate a unique UID for each event using `uuidgen` (uppercase).

### Timed Event Template

```
BEGIN:VCALENDAR
CALSCALE:GREGORIAN
PRODID:-//reclaw//calendar-add//EN
VERSION:2.0
BEGIN:VEVENT
CREATED:${NOW_UTC}
DTEND;TZID=Europe/Copenhagen:${END_DATE}T${END_TIME}00
DTSTAMP:${NOW_UTC}
DTSTART;TZID=Europe/Copenhagen:${START_DATE}T${START_TIME}00
LAST-MODIFIED:${NOW_UTC}
SEQUENCE:0
SUMMARY:${TITLE}${LOCATION_LINE}
UID:${UUID}
TRANSP:OPAQUE
END:VEVENT
BEGIN:VTIMEZONE
TZID:Europe/Copenhagen
BEGIN:DAYLIGHT
DTSTART:19810329T020000
RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
TZNAME:CEST
TZOFFSETFROM:+0100
TZOFFSETTO:+0200
END:DAYLIGHT
BEGIN:STANDARD
DTSTART:19961027T030000
RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
TZNAME:CET
TZOFFSETFROM:+0200
TZOFFSETTO:+0100
END:STANDARD
END:VTIMEZONE
END:VCALENDAR
```

### All-Day Event Template

For events without a specific time, use `VALUE=DATE` format:

```
DTSTART;VALUE=DATE:${START_DATE}
DTEND;VALUE=DATE:${END_DATE_PLUS_ONE}
```

Note: All-day event DTEND is the day AFTER the last day (exclusive). A single all-day event on March 5th has DTEND March 6th.

### Variable Formats

| Variable | Format | Example |
|----------|--------|---------|
| `NOW_UTC` | `YYYYMMDDTHHmmssZ` | `20260301T143000Z` |
| `START_DATE` | `YYYYMMDD` | `20260303` |
| `START_TIME` | `HHmmss` | `180000` |
| `END_DATE` | `YYYYMMDD` | `20260303` |
| `END_TIME` | `HHmmss` | `190000` |
| `TITLE` | Plain text | `Dinner at mom's` |
| `LOCATION_LINE` | `\nLOCATION:${place}` or empty | `\nLOCATION:Cafe Noir` |
| `UUID` | Uppercase UUID | `A1B2C3D4-E5F6-...` |

## File Writing

1. Generate UUID: `uuidgen | tr '[:lower:]' '[:upper:]'`
2. Get current UTC time for CREATED/DTSTAMP/LAST-MODIFIED
3. Write the .ics file to:
   ```
   ~/.local/share/calendars/icloud/D8C2180E-3AD0-406E-9B55-23DA5F2CC674/${UUID}.ics
   ```
4. Filename MUST match the UID inside the file (this is a CalDAV requirement)

## Sync

After writing the .ics file, trigger an immediate sync:

```bash
systemctl --user start vdirsyncer-sync.service
```

This is fire-and-forget. The sync service handles the push to iCloud. If the service isn't running, the event will sync on the next timer cycle (every 15 minutes).

## Confirmation

After creating the event, confirm with a concise summary:

```
Added to J & P calendar:
  [Title]
  [Day name], [Date] [Time range or "all day"]
  [Location if set]
Syncing to iCloud...
```

## Error Handling

- If `uuidgen` isn't available, generate a UUID-like string with: `python3 -c "import uuid; print(str(uuid.uuid4()).upper())"`
- If the calendar directory doesn't exist, warn the user that vdirsyncer may not be configured
- If the sync service fails, note that the event is saved locally and will sync on next timer cycle

## Examples

**Input:** "add dentist appointment this Tuesday at 14:30"
- Title: Dentist appointment
- Date: resolve "this Tuesday" → 2026-03-03
- Time: 14:30-15:30 (1h default)

**Input:** "put dinner at mom's on Saturday evening"
- Title: Dinner at mom's
- Date: resolve "Saturday" → 2026-03-07
- Time: 18:00-20:00 (evening = 18:00, dinner = 2h)

**Input:** "calendar: vacation March 10-15"
- Title: Vacation
- Dates: all-day events March 10-15
- DTSTART: 20260310, DTEND: 20260316 (exclusive)

**Input:** "add meeting with Lars tomorrow 10am for 90 minutes at the office"
- Title: Meeting with Lars
- Date: tomorrow
- Time: 10:00-11:30
- Location: The office
