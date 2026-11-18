# Postmortem: <title in plain words>

Blameless: this document is about systems and decisions, not people. The
question is "what made this possible", never "who did it". Format adapted
from the Google SRE book (chapter 15) and the PagerDuty postmortem guide.

| | |
|---|---|
| Date (UTC) | |
| Scenario / incident | game day #1 S<n>, or a real incident |
| Release | eks v…, operator v… |
| Incident commander | |
| Scribe | |
| Status | draft / reviewed / action items closed |

## Summary

Two or three sentences: what users saw, for how long, and how it ended.

## Impact

- Requests failed: … of … (from the probe log)
- Availability SLI over the window: … % (objective 99.5 %)
- Latency SLI over the window: … % within 8 s (objective 95 %)
- 30-day error budget consumed: … %
- Cost of the session: … (BUDGET A-0..)

## Timeline (UTC)

| Time | Event | Source |
|---|---|---|
| hh:mm:ss | injection | command |
| | first alert / first human notice | alert, probe |
| | mitigation started | |
| | mitigated | |
| | recovered (SLI at steady state) | probe |

Time to detect: … · time to mitigate: … · time to recover: …

## What happened and why

The chain of causes, each link backed by a log line, an event or a metric.
Stop at causes the platform can change.

## Hypothesis vs result

| Hypothesis written before | Result | Held? |
|---|---|---|

## What went well

## What went wrong

## Where we were lucky

## Action items

| Item | Type (prevent / detect / mitigate / process) | Owner | Tracking (PR or issue) |
|---|---|---|---|

## Evidence

Links to the probe log, alert notifications, `kubectl` output and the
evidence file of the session.
