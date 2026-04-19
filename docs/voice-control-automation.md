# Voice - Control: dismiss firing timer via "Alexa, stop"

This document describes the Home Assistant automation that completes the
"Alexa, stop" flow for firing timers on the ha-smart-display device. The
device side pauses the chime during wake-word listening (see
`docs/superpowers/specs/2026-04-19-stop-voice-command-design.md`); this
automation is what actually dismisses the timer when the user says "stop".

## Prerequisites

- An HA Assist pipeline is configured and the device's voice command flow
  works (wake word → STT → intent).
- The `stop` intent is routed to a script or automation — typically via
  the `conversation` integration's custom sentence matching or an
  `intent_script` for `HassCancelAllTimers` / similar.

## Automation body

The automation runs on the device's HA device registry ID. It reads the
timer list, filters to any timer whose `ends_at` has passed (that's what
"firing" means — the device only fires expired timers, and dismissed
timers are removed from the cache), and dismisses each one.

```yaml
alias: "Voice - Control: stop firing timer on ha-smart-display"
mode: queued
trigger:
  - platform: conversation
    command:
      - "stop"
      - "stop timer"
action:
  - action: ha_smart_display.get_timers
    data:
      device_id: <YOUR_DEVICE_ID>
    response_variable: resp
  - repeat:
      for_each: >-
        {{ resp.timers
           | selectattr('ends_at', 'le', now().timestamp() | int)
           | map(attribute='id') | list }}
      sequence:
        - action: ha_smart_display.dismiss_timer
          data:
            device_id: <YOUR_DEVICE_ID>
            timer_id: "{{ repeat.item }}"
```

## Notes

- **`<YOUR_DEVICE_ID>`** is the HA device registry ID for the
  ha-smart-display device. Find it in Settings → Devices → your device →
  "⋯" → Download diagnostics (or use the device picker in the UI when
  authoring the automation).
- The `repeat` block is a no-op if no timers are firing, so it's safe
  even when the user says "stop" at other times (the built-in Assist
  pipeline may handle it differently — this automation only dismisses a
  firing timer).
- **Alarms are out of scope.** Their payload has `time: "HH:MM"` rather
  than a unix timestamp, so the `ends_at <= now()` filter cannot be
  applied. Add alarm handling later if/when needed.
- Multiple firing timers: all are dismissed, which matches user
  expectation ("stop everything that's beeping at me").
