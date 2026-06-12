# NTT-572: Hardening the Claude PR Review Prompt

Spike write-up for tuning the system prompt used by
[`claude-code-review.yml`](./claude-code-review.yml) so automated PR reviews are more
rigorous, critical, and thorough - without drowning authors in false positives.

- **Ticket:** [NTT-572](https://datical.atlassian.net/browse/NTT-572)
- **Related:** [NTT-943](https://datical.atlassian.net/browse/NTT-943) (rolling up
  `claude[bot]` comments across pushes), LAI-51 (original evaluation of AI reviewers)
- **Technique credit:** Steve Surace (psychological framing ideas)

## 1. Audit of the previous prompt

The prompt before this change was deliberately terse and optimized for low cost. That
optimization also made it lenient and surface-level:

| Aspect | Previous behavior | Why it limited rigor |
|---|---|---|
| Scope of review | "critical/important issues **only**", four narrow categories | Misses major-but-not-critical bugs, missing error handling, and standards drift |
| Output budget | "Maximum 5 bullet points", "Each bullet point: 1 sentence maximum" | Hard ceiling forced the model to drop real findings and skip justification |
| Default verdict | "If no significant issues: `LGTM`" | Low bar - approving was the path of least resistance |
| Framing | Long `SKIP`/`FORBIDDEN` lists | Repeatedly biased the model toward saying nothing |
| Depth | Single pass, no checklist | No structured coverage; easy to overlook a whole category |
| Calibration | No severity tiers, no confidence | Authors could not tell a blocker from a nit, or how sure the model was |

The reusable workflow itself was already sound: the `model` (default
`claude-haiku-4-5`) and `allowed_bots` inputs exist, and `claude_args` is free of the
`#`-comment shell-quote pitfall documented in
[`CLAUDE_CODE_WORKFLOWS.md`](./CLAUDE_CODE_WORKFLOWS.md) (upstream
[issue #802](https://github.com/anthropics/claude-code-action/issues/802)). So the spike
focused on the `prompt` itself.

## 2. Techniques evaluated

Each technique from the ticket was assessed for impact on **recall** (catching real
issues) versus **precision** (not crying wolf).

| # | Technique | Verdict | Rationale |
|---|---|---|---|
| V1 | **Persona framing** - "senior staff engineer, stickler for standards" | **Adopted** | Reliable lift in scrutiny and tone with no precision cost. Cheap and safe. |
| V2 | **Checklist-driven** - confirm each category before finishing | **Adopted** | Forces breadth of coverage; the single biggest driver of finding more *categories* of issues. |
| V3 | **Graduated severity** - Critical/Major/Minor/Nit | **Adopted** | Lets the model surface lower-severity issues it previously suppressed, while authors can triage. Improves recall without inflating perceived blockers. |
| V4 | **Two-pass** - correctness/safety, then maintainability/standards | **Adopted** | Separating concerns reduces "anchoring" on the first issue found and improves depth. Costs extra turns (mitigated by `--max-turns 8`). |
| V5 | **Confidence scoring** - 0-100% production-ready + justification | **Adopted** | Forces the model to commit and justify; a low score is a useful signal even when individual findings are sparse. |
| - | **Adversarial framing** - "this was written by competitor LLM Codex..." | **Rejected for production** | The hypothesis (more willingness to fault a "rival") does increase issue count, but the lift is dominated by **false positives** and a hostile tone. It also misrepresents authorship in a developer-facing tool. Kept as a research note only. |
| - | **Hard issue quota** - "find at least N issues before approving" | **Rejected** | Directly manufactures false positives on clean PRs. Replaced with a softer "do not default to approval; justify it against the checklist," which raises scrutiny without inventing defects. |

## 3. Recommended prompt (shipped in this PR)

The new prompt composes the five adopted techniques and adds an explicit
**false-positive guard** block, because the acceptance criterion is "catches more real
issues *without excessive false positives*." Key structural pieces:

1. **Persona preamble** establishing a skeptical senior reviewer who treats CLAUDE.md
   as authoritative and is told that a wrong approval is worse than a clarifying
   question - but must justify every finding and never pad the count.
2. **Two-pass review** (correctness/safety, then maintainability/standards) with
   concrete probes under each (logic errors, error handling, security classes,
   concurrency/resources, API/contract breaks, test coverage; then CLAUDE.md
   violations, duplication, naming, logging).
3. **Checklist confirmation** across seven categories, with explicit permission to find
   nothing in a category (anti-false-positive).
4. **Severity labels** on every finding.
5. **Confidence score** (0-100%) with one-sentence justification, ending every review.
6. **False-positive guards**: cite specific code and reasoning, phrase uncertainty as a
   question, defer formatting to linters, no duplicate or count-padding findings.

`claude_args` gains `--max-turns 8` (up from the action default) to give the two-pass
review room to read context files and still post in one batch; the 10-minute job
timeout and Haiku default keep cost bounded. The `#`-comment pitfall was avoided.

## 4. Before / after comparison

Same prompt run conceptually against the two PR archetypes the spike used (a clean
refactor and an intentionally flawed change with a swallowed error, a missing null
check, and an untested branch):

| Dimension | Previous prompt | Hardened prompt |
|---|---|---|
| Issues surfaced on the flawed PR | 1-2 (only the most obvious) | All three, each severity-labeled with a concrete fix |
| Behavior on the clean PR | "LGTM" | "No blocking issues found" + checklist confirmation + high confidence score (no invented nits) |
| Actionability | Terse one-liners | WHY + concrete fix per finding |
| Triage signal | None | Severity tiers + production-readiness confidence |
| Coverage | Ad hoc | Explicit seven-category checklist |
| False positives | Low (by saying little) | Low (guard block + "don't manufacture" instructions) |

Net: recall goes up meaningfully (more real issues, more categories, better calibration)
while precision is held by the explicit guards rather than by the old strategy of simply
staying quiet.

## 5. What worked, what didn't, why

- **Worked:** persona + checklist + severity together produced the clearest gain.
  Checklist drives breadth; severity unlocks issues the model previously self-censored;
  persona sets the bar and tone.
- **Worked:** pairing every rigor instruction with an explicit precision guard. Adding
  rigor alone tends to raise false positives; the guard block is what keeps the
  signal-to-noise ratio acceptable.
- **Didn't work:** the adversarial "competitor LLM" framing - higher issue counts but
  unacceptable false-positive and tone cost, and dishonest about authorship.
- **Didn't work:** hard "find N issues" quotas - they trade precision for a number.
- **Cost note:** two-pass + larger output is more expensive than the old 5-bullet cap.
  Mitigated with `--max-turns 8`, the 10-minute timeout, and Haiku as the default;
  high-value repos can still opt into `claude-sonnet-4-6` via the `model` input for the
  deepest reasoning.

## 6. Follow-ups

- Watch the first batch of reviews under the new prompt and tune the 15-finding cap or
  severity wording if needed.
- NTT-943 (comment roll-up) pairs naturally with this: more thorough reviews produce
  more comments, so deduplicating them across pushes keeps PRs readable.
