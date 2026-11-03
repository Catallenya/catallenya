# The message contract

Every notification this box sends is built here. **This document is the source.** It is
written to one test: *everything is lost, someone has this file — can they rebuild the
notification system correctly?* Code comments elaborate; they never contradict.

The mechanism is `ntfy/kinds.sh` (constructors), `ntfy/ntfy.lib.sh` (transport) and
`systemd/contract.sh` (the gate that refuses anything else).

**Why it exists.** 32 emission points across 12 files grew **six incompatible title
grammars** in about a year — `Staged: 3 Documents`, `Liquidroom: stems ready`,
`Afterimage Gave Up`, `Immich rotation bake failed`, `Disk Space Alert`,
`Backup Failure`. Each was written by someone following whatever file they had open.
The transport was unified on 2026-08-10, but that standardised the **wire**, never the
**message**.

---

## 1. The class model

Four classes. Which one a message belongs to decides whether its wording may differ
between pipelines.

| Class | Source | Vocabulary | Verbs |
|---|---|---|---|
| **Model** | `ai/scripts/ai.lib.sh` | **must be identical** | `Model Failed` `Model Paused` |
| **Policy** | the same rule implemented twice | shared by choice | `Abandoned` |
| **Situation** | different code, same predicament | shared by choice | `Flagged` `Stuck` `Refused` `Skipped` `Stranded` |
| **Service** | one pipeline's own machinery | independent | everything else |

**Why the model class is mandatory and not a preference.** Both intake pipelines call
`ask()` in `ai/scripts/ai.lib.sh`, and both triages have byte-identical branch structure
around it:

```bash
ask_rc=0
prop="$(ask …)" || ask_rc=$?
if   (( ask_rc == 2 || ask_rc == 3 )); then   # parked  — retry/paused
elif (( ask_rc != 0 )); then                  # terminal — fatal
```

An error out of that layer is **one fact arriving on several topics**. It used to read as
`Capture Failed — check the API key` on one and `Blocked: 1 Document — The model call
failed` on the other, only one of which pointed anywhere near the problem. `paused_title()`
already encoded this argument for one of the three outcomes; the other two were never
brought along.

`api_class()` emits four verdicts:

| rc | verdict | Triggers | Title |
|---|---|---|---|
| 0 | `ok` | 200 | — |
| 1 | `fatal` | 400 · 401 · 403 `permission_error` · 404 · model refusal · truncated reply · unparseable JSON | `Model Failed: 1 X` |
| 2 | `retry` exhausted | 429 · 5xx · `000` after `API_MAX_ATTEMPTS` | `Model Paused: N X [Unreachable]` |
| 3 | `paused` | 402 · 403 `billing_error` · 400 whose message names the credit balance | `Model Paused: N X [Unpaid]` |

`Model ` is a **namespace prefix**, the same move as `Still ` for nudges. It keeps the
shared meaning unambiguous and leaves `Failed` free for the state slot elsewhere
(`Backup: Failed`, `Rotation Bake: Failed`).

**`Abandoned` is unprefixed on purpose.** The 7-day give-up is *this repo's* timer
deciding to stop retrying — the cause is model-class, the decision is the pipeline's. The
missing prefix is what makes that difference readable on a lock screen.

---

## 2. The vocabulary — 24 verbs

| Verb | Class | Means |
|---|---|---|
| `Model Failed` | model | the API rejected the request; retrying cannot help |
| `Model Paused` | model | parked — unreachable, or out of credits |
| `Abandoned` | policy | the 7-day clock ran out on a parked item |
| `Flagged` | situation | the model answered, but a human should look |
| `Stuck` | situation | a file cannot be moved out of a drop zone; the trigger will re-fire |
| `Refused` | situation | a safety check refused something |
| `Skipped` | situation | nothing to do; working as intended |
| `Stranded` | situation | a file the pipeline cannot act on at all |
| `Passed` | afterimage | the event is already in the past |
| `Unlinked` | afterimage | staged, but no callback URL could be built |
| `Staged` | pigeonhole | proposed, awaiting a tap |
| `Blocked` | pigeonhole | the document itself cannot be filed |
| `Binned` | pigeonhole | moved to `bin/` after 7 days |
| `Finished` | liquidroom | stems published |
| `Downloaded` | liquidroom | interim ping; downloads complete |
| `Dropped` | liquidroom, grayjay | download failed |
| `Halted` | liquidroom | separation failed |
| `Emptied` | liquidroom | the separator produced nothing |
| `Raced` | liquidroom | the destination appeared mid-run |
| `Unpublished` | liquidroom | the atomic rename failed |
| `Baked` | immich | rotations written into originals |
| `Cancelled` | feeds | an event marked "going" vanished from its source |
| `Archived` | grayjay | a video you were told had failed is safely in ArchiveBox after all |
| `Still ` | prefix | a nudge |

**Every one is a past participle.** 23 end in `-ed`; `Stuck` is the single irregular and
is listed in `NTFY_IRREGULAR_VERBS`. The gate checks this (§9).

---

## 3. The constructors

All five live in `ntfy/kinds.sh`. Nothing else may build a title.

```bash
title_count <Verb> <n> <Noun> [name] [mark]   a REPORT — what happened, to how many
title_state <Subject> <State> [mark]          a FAULT or RECEIPT — what is, with what
title_quote <name> [mark]                     a QUOTATION — the world's own words

title_mark <text>        -> [text]      title_pos <n> <of>  -> [2/4]  (silent at of<=1)
title_age  <hours>       -> [6h][1d][3w]
```

Worked calls:

```bash
title_count Staged 3 Document                       # Staged: 3 Documents
title_count Blocked 1 Document                      # Blocked: 1 Document
title_count "Still Staged" 3 Document "" "[1d]"     # Still Staged: 3 Documents [1d]
title_count Flagged 1 Event "Kene"                  # Flagged: Kene
title_state zpool "78% Full"                        # zpool: 78% Full
title_state Backup Failed                           # Backup: Failed
title_quote "Kene" "$(title_pos 2 4)"               # Kene [2/4]
title_quote "Kene" "$(title_age 31)"                # Kene [1d]
```

**Sanitation is not here.** `notify()` already runs `hdr_safe` on its first argument, so a
name — a hand-typed track filename, a model-written event title — is handled at the same
boundary as every other title. Two copies of a CR/LF strip is how the two drift.

### Bodies — the language

Titles could have a closed vocabulary. Prose cannot, so what a body gets instead is a
**style system**: decisions that constrain how any future sentence is written. Settled
2026-08-21, and the point of settling it in one pass is that this text is generated
once and then frozen — a body written next year should be indistinguishable from one
written today.

#### Four shapes, and nothing else

```
1. IMG_1234.jpg                    ITEM      a thing — file, document, track, job
    Rotated: 90°                   DETAIL    what happened to it, indented

• 400G free                        FACT      a metric or a state about the run

Only *.png is triaged.             PROSE     one explanation, in sentences

_… and 3 more._                    ASIDE     a truncation count, and nothing else
```

**Order: items, blank, facts, blank, prose.** The aside sits with whatever it truncates.

#### When to use which

**Terse lines for a list of things** — files, actions, metrics. **A sentence when there
is one thing to explain.** Never drop context to shorten a line, and never chop a single
explanation into bullets: `Could not move it out of incoming/. The disk may be full.`
reads better than three fragments, and three fragments is what the rule exists to
prevent.

#### The renderers

**No body is built by hand.** Four functions in `ntfy/kinds.sh` produce the four shapes,
and every one of them escapes its input — which is what let `NTFY_MARKDOWN` go. Five
publishers had turned rendering off because their bodies carry raw filenames, and a
camera name like `photo_2026_08_01.jpg` comes out with its middle italicised, or worse, a
filename arriving over Syncthing could hide a live `[tap here](https://evil)` inside a
notification you already trust. Escaping in one place is what makes rendering safe
everywhere.

**Markdown is now unconditional.** With all five opt-outs converted, `NTFY_MARKDOWN` was
a variable nothing set — a slot waiting for someone to put `no` in it, exactly what
priority was. It was removed on 2026-08-21 and the header is always sent. This matters
beyond tidiness: `md_escape` exists to guard a *rendered* body, so a consumer that could
switch rendering off could also switch off the reason the escaping is there.

```bash
body_list [--all] <item>...   items, numbered, capped at five; "name<TAB>detail"
body_fact <line>...           the • lines
body_aside <text>             the italic truncation count, and nothing else
body_join <section>...        the blank lines between sections, empties dropped
```

`body_join` exists because the order rule is a rule and not a habit: `$( )` strips
trailing newlines, so a section boundary needs two literal newlines and looks like a typo
with one. That is the kind of thing that is right the first time and wrong the third.

```bash
BODY="$(body_join \
    "$(body_list "${ERRORS[@]}")" \
    "$(body_fact "24/26 containers running" "15/15 timers active")")"
```

#### What the escaping stops, and what it does not

**Markdown is ON everywhere and is never switched off.** That is the opposite of the
old shape, where five publishers disabled rendering because their bodies were unsafe —
which patched the symptom in five places. Safety comes from the renderers escaping
their input, so it holds for every publisher including ones written later.

Three behaviours, and the difference between them is deliberate:

| Path | `[tap here](https://evil)` | Bare `https://evil` |
|---|---|---|
| **item · detail · fact** | `\[tap here\]\(https://evil\)` — inert, shows as literal text | passes through, may autolink |
| **prose** | not escaped — the caller's | not escaped — the caller's |

**Link syntax is what matters, and it is neutralised** in everything the box did not
author: filenames arriving over Syncthing, model output, a remote server's `last_error`,
a watch title chosen on someone else's website. Bold, headings and code spans go the same
way.

**A bare URL survives, and that is a decision rather than an oversight.** Link syntax
*hides* its destination behind friendly text, which is what makes it dangerous inside a
notification you already trust; a bare URL shows where it goes. Escaping one would mean
mangling `:` or `/`, which wrecks every legitimate path and every `Reason:` label. It is
also load-bearing in one place: changedetection's body ends with `{{watch_url}}`, because
the link is the actionable thing.

**But a bare URL is NOT TAPPABLE while markdown is on, and that was measured on the phone
rather than reasoned about** (2026-08-23). Three forms, one device:

| Body | Renders as |
|---|---|
| markdown **off**, `https://…` | the client linkifies it — tappable |
| markdown **on**, `https://…` | **plain text — not tappable** |
| markdown **on**, `<https://…>` | tappable, and the full address is still visible |

`<…>` is a CommonMark **autolink**, which is a different thing from `[text](url)` and is
not what rule 9 refuses: an autolink cannot hide a destination, because the
destination *is* the text. Rendering has been on since 2026-08-21 for everything that goes
through `notify()`, so a bare URL in one of those bodies is un-tappable. **In practice that
set is EMPTY**: no job authors a URL into a body — afterimage's and pigeonhole's URLs are
BUTTON TARGETS, which are not body text — and the only URLs that could arrive are untrusted
(a watch title lifted off someone's site, a `last_error` echoed back by a remote server).
Those are escaped on purpose and **must stay defused**; making them live would be a
downgrade, not a fix. So the rule is for whoever authors the NEXT one: wrap it in `<…>`.

**changedetection is NOT affected**, and an earlier version of this paragraph said it was.
Its watches notify through Apprise with `notification_format=text`, so nothing tells ntfy
to render them and the client linkifies the URL itself — which is the same path the CI
alert took before 2026-08-23, and that one was demonstrably tappable.

**Prose is unescaped by design** — `body_join` escapes nothing, since its other arguments
are already rendered. So the PROSE argument is the caller's to escape, trivially true when
the sentence is ours and mandatory when any part of it came from a model or a filename.
Gate rule 9 refuses hand-written link syntax in a body, which is the half of that a static
check can see.

#### The rules

| | Rule | Example |
|---|---|---|
| 1 | Items are numbered `1\.`, capped at five | `1. scan_20260820.pdf` |
| 2 | A detail is `Label: value`, **labelled only when the value alone is ambiguous** | `Rotated: 90°` but a bare `09_receipts-…/Acme.pdf` |
| 3 | **No full stop on any line but prose** — a stop after a path reads as part of the filename, and one rule beats remembering which line you are on | `Reason: PDF is locked or unreadable` |
| 4 | A fact is **self-describing and carries no stub label** | `• 400G free`, never `• Free: 400G` |
| 5 | A fact is a **complete statement**; where prose reads badly use a full descriptive phrase, never a stub | `• Estimated time left: 70m`, never `• about 70m` |
| 6 | Facts are **capitalised** | `• Out of credits` · `• Retrying daily` |
| 7 | Metrics get their own line, never a comma-joined run | `• 15/15 timers active` |
| 8 | Prose is capitalised sentences **with** full stops, as many as it needs | `Could not reach the API for 7d. Take it again once things are healthy.` |
| 9 | A body **may instruct** where there is a next step | `Take it again once things are healthy.` |
| 10 | **No rhetorical questions** — state it as a possibility | `The disk may be full.` not `Disk full?` |
| 11 | **No em-dashes**, anywhere in a body | the indent does that work |
| 12 | Units are **compact** | `402d` · `2d 4h` · `70m` · `1.3T of 1.7T` |
| 13 | Paths are **full** | `09_receipts-and-purchases/2026-08-20 Acme Receipt.pdf` |
| 14 | **Only a truncation count is italic** | `_… and 3 more._` |
| 15 | Prose uses natural language, **pronoun where the title already named it** | `Could not move it out of incoming/.` |
| 16 | No ceiling on length | the list cap bounds the common case |

#### Why facts carry no label and details do

It looks arbitrary and is not. **A detail hangs off the item above it**, so a label says
*which aspect of that item* you are being told — `Rotated: 90°` under a filename. **A fact
stands alone**, so it has no context to lean on and must describe itself.

The failure this invites is dropping context to keep the line short. `• about 70m` obeys
the letter of "no label" and means nothing. Where plain prose reads badly, the answer is a
**full descriptive phrase**, never a stub:

| stub label | terse prose | correct |
|---|---|---|
| `• Estimated: 70m` | `• about 70m` | `• Estimated time left: 70m` |
| `• Not found: 1` | `• 1 not found` | `• 1 track not found` |
| `• Free: 400G` | — | `• 400G free` |

#### Truncation keeps three meanings

They are different facts and read differently:

```
_… and 3 more._              the list was cut at five
_3 more still queued._       work is waiting for the next run
_3 more events not sent._    data was dropped and is gone
```

#### The `•` marker

**U+2022 BULLET**, since 2026-08-22. It replaced **U+25AA BLACK SMALL SQUARE**, which
shipped first and had one defect that mattered: U+25AA has an **emoji presentation**, and
some Android builds draw it as a coloured square. A marker that renders as an emoji on
the device it is read on is not a marker.

Also rejected: `-`, `*` and `+`, which markdown turns into real list markers — the same
trap the escaped `1\.` exists for — and which would therefore need escaping to survive.
`-` fails a second way on the body it appears in most: `- 19:30 - 21:00` puts three
hyphens on one line meaning two different things.

**The bullet needs no escape** (it carries no markdown meaning) and is not emoji-capable.
That is the whole of why it wins.

It collided with exactly one thing: afterimage used `" • "` as the separator between
alternative times, so the proposal would have read `• 19:30 - 21:00 • 20:15`. That
separator moved to `" / "` the same day — narrow enough to keep the phone-width reason it
was chosen for in the first place. **Do not restore `" • "` there without moving the
marker.**

#### The one text no rule can reach

**afterimage's `reason` is model-written prose and stays that way.** The plan was to
replace it with a code, the way pigeonhole returns `PDF_UNREADABLE_OR_ENCRYPTED` and
`reason_text()` turns that into a sentence — after which "no em-dashes" is a grep over
`case` arms rather than something anyone must remember.

Measured against the archive instead of assumed, and the archive says no. In 115
records the one stored `needs_human` reason reads:

> The screenshot shows an Instagram post for a bar's Cupid event ("magic at 10pm",
> free entry, 9 Bras Basah Road) and a group chat planning to walk in around 10pm, but
> no specific calendar date for the outing is shown anywhere, only a note that
> reservation slots open 1 August onwards.

No enum produces that, and `NO_RESOLVABLE_DATE` → "No date could be resolved." throws
away everything that made it actionable. **The two pipelines differ in what the reason
is ABOUT**: pigeonhole's describes a failure to read a FILE, and the ways a file can
fail to be read are finite; afterimage's describes what a SCREENSHOT SHOWED, which is
not. The enum is right in one and wrong in the other for the same reason.

So the style rules are carried in the PROMPT — full stops, no em-dashes, no rhetorical
questions, no Markdown, and be specific rather than brief. That is weaker than a gate
and is the honest place for it: nothing static can check a sentence a model has not
written yet.

#### One thing kept that looks inconsistent

**afterimage keeps record ids** — `(id 3f2a9c1b)` — because a screenshot has no name
until the model reads one out of it, and every body carrying an id is a case where that
never happened. pigeonhole has filenames and so never needs one.

The proposal body is what the no-label rule was written for: a date, a time and a venue
each announce what they are, so a label would only repeat them.

```
Kene [2/4]
• Thursday, 27 August 2026
• 19:30 - 21:00
• Candlenut
```

An online event adds its meeting link as one more fact, in full. Add writes it into the
calendar as a link you can tap, and the notification is the only place to check it first.

---

## 4. The kinds

Every notification is one of five things, and the kind decides **which arguments exist**.
That is the whole mechanism.

```bash
notify_proposal <title> <body> <actions> <seq-id>   both REQUIRED
notify_nudge    <title> <body> <seq-id> [actions]   retracts first; id REQUIRED
notify_resolved <title> <body> <seq-id> [actions]   retracts first; id REQUIRED
notify_fault    <title> <body> [seq-id]             never actions
notify_receipt  <title> <body>                      never actions, never a seq-id
```

`notify()` is the transport primitive underneath and is not called from outside `ntfy/`.
Its signature is `notify <title> <body> [actions] [sequence-id]` — **there is no priority
and no tag.** Priority had one legal value, so it was a slot waiting for someone to put
`high` in it. Tags were twelve glyphs of which four meant "something is wrong"; the rest
named the pipeline, which the topic already says.

**The kinds produce no visible difference.** With tags gone, every message renders as
title plus body regardless. Their value is entirely structural — a receipt has no
argument to put a button in, a proposal cannot omit the sequence-id that makes it
withdrawable — and it is what lets the gate refuse a bare `notify()`.

### The fault lifecycle — a fault that heals itself says so

`fault_open` / `fault_close` in `ntfy/ntfy.lib.sh` (2026-10-31), the same one-call
lifecycle shape as `paused_sync`:

```bash
fault_open  <id> <title> <body>     the fault is present this run (publishes as notify_fault)
fault_close <id> <state> [prose]    the fault is absent this run
```

A caller asks one of the two on **every** run. `fault_open` leaves a marker in
`systemd/state/.faults/`; `fault_close` is a no-op without one, and with one it publishes
`<same subject>: <state>` on the **same sequence id** — so `ArchiveBox: Unreachable`
becomes `ArchiveBox: Reachable` in place on the phone — and removes the marker. The id is
the stable one the fault already carried, so nothing new identifies a fault. Nothing is
withdrawn: the fault is overwritten by a message saying what happened, which keeps the
withdrawal rule below intact. Output-transparent like `notify_fault`. `NTFY_FAULT_DIR` is
the test seam; a muted run without it touches no marker.

The same rule for **any job the courier reports**: a failure goes out under
`unit-<name>` and leaves a marker, and `ntfy/recovered.sh` — run by the base policy as an
`ExecStartPost=` after every successful run — publishes `<Job>: Recovered` over it. No job
carries a line of its own for this.

**Known limit, accepted (2026-10-31 audit): "Recovered" means the next run SUCCEEDED, not
that it re-tested what failed.** For most jobs those are the same thing. For a poller that
often has nothing to do — `liquidroom.triage` every five minutes, pigeonhole's 03:00
backstop — an empty run exits 0, so a request-driven failure can be followed minutes later
by `Triage: Recovered` with nothing retried. The body says exactly that ("The next run
succeeded"), the failure note left in the folder still says what failed, and special-casing
pollers in the generic hook was judged worse than the rare honest-but-early message.

### The withdrawal rule

> **A notification with buttons may be withdrawn. A notification without buttons is
> never withdrawn by the system.**

An actionable message is withdrawn by the tap that resolves it, or by afterimage's
archive backstop once its buttons have started answering 404 — a control that lies is
worse than no control. Everything else stays until you swipe it.

**The reasoning matters more than the rule.** An absent notification is ambiguous: you
cannot tell "the problem fixed itself" from "I mis-swiped it" from "it was never sent".
A stale one is unambiguous — it says something happened, so you go and look.

| Kind | Buttons | Withdrawn? |
|---|---|---|
| `proposal` `nudge` `resolved` | yes | by the tap, or when the buttons go dead |
| `fault` `receipt` `paused` | no | **never** |

**There are no exceptions to that second row.** The last one closed on 2026-08-20:
afterimage's `Flagged: Kene` had no buttons yet was withdrawn at seven days by the
archive backstop, silently, because its record was gone. It now carries a Discard
button — see nuance 6b — so its withdrawal is a tap's or a dead control's, which the
rule already allows.

**A fault's sequence-id means "this can recur".** A job that runs on a schedule and can
report the same finding twice passes a stable literal, so the second run replaces the
first instead of stacking: `host/disk.sh` runs hourly, and a pool over threshold across a
weekend used to produce forty-five notifications. It still does **not** self-clear — see
the rule. A one-shot fault about a single item passes no id, because nothing later will
replace it.

Stable fault ids today: `disk-full`, `watchdog-findings`, `changedetection-health`,
`immich-bake-failed`, `boot-failed`, `afterimage-stuck`, `afterimage-stranded`,
`pigeonhole-stuck`, `pigeonhole-paused`, `grayjay-backup`, `grayjay-archivebox`,
`grayjay-channel-<channel id>`.

**This reverses a deliberate fix, and that is intentional.** On 2026-08-19
`paused_sync()` was made to retract unconditionally so the run that *ended* an outage
cleared the summary. Under the rule above that stale summary is correct — it has no
buttons — so `paused_sync()` now retracts only when it is about to publish a
replacement. Do not restore the old behaviour without revisiting the rule.

---

## 5. The rules

**Grammar**

| # | Rule |
|---|---|
| 1 | Never repeat what the topic already says |
| 2 | A model-written event title is a **quotation**, built by `title_quote` |
| 3 | **Past participle only, zero exceptions**, in the verb slot |
| 4 | `Still ` is the nudge prefix. A nudge of a *quotation* takes no verb — just the age |
| 5 | Faults use `Subject: State` |
| 6 | A name may replace the count in the object slot |
| 7 | `Model ` is the namespace prefix for the shared AI layer's two verbs |

**Style**

| # | Rule | Example |
|---|---|---|
| 8 | Keep the digit at 1 | `Blocked: 1 Document` |
| 9 | Title Case nouns | `3 Documents` |
| 10 | Identifiers keep their real case; words get Title Case | `zpool: 78% Full` |
| 11 | The state slot carries a number where one naturally fits, otherwise a bare participle or phrase. **Strong preference for the number** | `zpool: 78% Full` · `Backup: Failed` |
| 12 | The digest noun is `Findings` | `Watches: 3 Findings` |
| 13 | Every qualifier rides in square brackets | `[2/4]` `[1d]` `[Unpaid]` `[restic]` |
| 14 | Cap ~40 chars. **The verb is never what truncates** | `Finished: Godspeed You! Black Emperor -…` |
| 15 | The ellipsis is `…`, one codepoint | |

**Behaviour**

| # | Rule |
|---|---|
| 16 | **Quiet on success** (owner, 2026-10-31). Every notification is one of four things: a **failure**; a **decision waiting for you**; the **result of something you asked for**, including a failure that has since recovered; or a **change in how your requests will be handled**. Never "all fine". Proof that the alert path works goes to an outside watcher, never the phone. Enforced twice: `install.sh` refuses `OnSuccess=` on every class, and `systemd/contract.sh` refuses a `notify_receipt` whose word is not in `NTFY_RECEIPT_VERBS` (`ntfy/kinds.sh`) |
| 17 | The imperative lives on the **button**; the title only ever reports |
| 18 | A notification with buttons may be withdrawn; one without buttons never is — see §4 |

---

## 6. The nuances

Fifteen deliberate exceptions. Each is a decision, not an oversight; each names the
service that exemplifies it.

| # | Nuance | Where | Why |
|---|---|---|---|
| 1 | `Model ` prefix exists to free `Failed` | all | `Failed` is wanted in the state slot (`Backup: Failed`) and as a general idea. Prefixing the model class keeps its shared meaning exact without monopolising the word |
| 2 | `Abandoned` is **not** prefixed | afterimage, pigeonhole | the 7-day give-up is our timer, not the API's fault. The missing prefix carries that |
| 3 | Rule 11 is a preference, not a rule | immich, restic | forcing a number produced `Backup: 1 Success`, counting something always exactly one, and `Changedetection: 0 Containers Running` for a container that is simply down |
| 4 | `Flagged` `Stuck` `Refused` `Skipped` `Stranded` are shared **by choice** | several | they are situation-class, so sharing is permitted, not required. The situations genuinely match — `Flagged` means *model answered, human should look* in both pipelines |
| 5 | The gate **is** the layering | `systemd/contract.sh` | unlike systemd there is no merge engine. Nothing at runtime stops a hand-built string. See §10 |
| 6 | A proposal's nudge takes **no verb** | afterimage `sweep:184` | its original title is a quotation with no verb to reuse. afterimage therefore has two nudge shapes on purpose |
| 6b | `Flagged: Kene` carries a **Discard** button | afterimage `triage:431` | `Add` is impossible without a parsed date, so this was a button-less fault — and therefore the one message the withdrawal rule said to keep while the archive backstop removed it at seven days anyway, silently. Discard is only an archive, which is what the day-7 expiry does regardless, so giving it that one button settles the contradiction in the rule's favour rather than against it |
| 7 | Noun follows the pipeline **stage** | afterimage | `Screenshot` until the model produces events, `Event` after. `Passed: 3 Screenshots` would be wrong — three events came from one screenshot |
| 8 | Filenames stay in the **body**, not the title | pigeonhole | `title_count` accepts a name; pigeonhole deliberately passes none, because a batch of three wants three names listed, not one promoted |
| 9 | One notification **per verb**, not per run | liquidroom | a run where two tracks succeeded and one failed cannot honestly be titled `Finished` |
| 10 | Name the watch only at exactly one | changedetection | two or more and the title becomes a list; `Watches: 3 Findings` is the honest summary |
| 11 | Three faults are **digests**, so their state is caller-built text | disk, changedetection, watchdog | disk covers root *and* zpool; changedetection covers N problems of mixed types; the watchdog covers N mixed findings. The gate checks the shape, not the content |
| 12 | `system-ntfy.sh` is **exempt** from the constructors | courier | it is the alarm of last resort and must depend on as little as possible, including on another file in this repo being intact. It matches the grammar by hand; the gate checks it by pattern |
| 13 | The courier is watched by its **own dead man's switch**, off the phone | ntfy | Until 2026-10-31 restic's daily `Backup: Succeeded` was the only proof the courier still worked — a notification every morning that said nothing. `courier.selftest.timer` (08:30 SGT) now makes the courier publish to the unsubscribed `courier-canary` topic over the real alert path and ping a healthchecks.io check only if ntfy accepted it; healthchecks.io alarms when the ping stops. A broken self-test fails loud the same way, which is where the "who watches the watcher" chain ends. The ping URL (`HEALTHCHECKS_COURIER_PING_URL`) is a secret in `.env` |
| 14 | Every restic job is failure-only **by design** | restic | silence is the healthy state, and `install.sh` mechanically refuses `OnSuccess=` on every class |
| 15 | Boot reports failure only | host | dropped from success on 2026-08-20. Accepted consequence: after a power cut, silence no longer distinguishes *recovered* from *still dark*, and this box does not auto-restore on AC return |
| 16 | **The courier's body is the job's own words** | `system-ntfy.sh` | one body serves every job failure and all three scheduled restic successes, and `systemctl status` spent ~18 lines on boilerplate before reaching anything a person wants. Scoped to `_SYSTEMD_INVOCATION_ID` so it cannot bleed across runs — `restic.staleness` prints one line a day, so a failure used to arrive under five previous days of "within the 48h limit" — and to `_TRANSPORT=stdout` so systemd's own Starting/Finished lines cannot fill the budget, which is what happened to `disk`, a job that prints nothing when healthy |
| 17 | **`catallenya.service` cancels its inherited `OnFailure=`** | host | see the self-alerting rule below |

---

## 7. The inventory

Every title the system can emit.

### model selection — on whichever intake topic ran (`ai/scripts/ai.lib.sh`)

The model is resolved per run (2026-10-03): the newest Opus from the Models API,
falling back to the last model that answered. Two notices come out of that, both
**once per model** rather than per item, and both on the topic of whichever pipeline
happened to make the call, since the state they compare is shared. Built with
`title_state`, so no verb is declared for them.

| When | Kind | Title |
|---|---|---|
| a different model answered than last time | receipt | `Model: Changed` |
| the newest model refused a request the last-working one then accepted | fault | `claude-opus-6: Rejected` |

### afterimage — topic `afterimage`

| When | Title |
|---|---|
| screenshot lands → model finds an event | `Kene` · `Kene [2/4]` |
| same, callback URL unbuildable | `Unlinked: 1 Event` |
| can't move out of `incoming/` — disk full | `Stuck: 1 Screenshot` |
| API rejected — rc 1 | `Model Failed: 1 Screenshot` |
| model says it isn't an event | `Skipped: 1 Screenshot` |
| date or time ambiguous | `Flagged: Kene` · **Discard** |
| events found, all in the past | `Passed: 3 Events` |
| parked 7d from first failure | `Abandoned: 1 Screenshot` |
| needs-human untouched 24h | `Still Flagged: Kene [1d]` · **Discard** |
| proposal untouched 24h | `Kene [1d]` |
| strays the `*.png` glob can't see | `Stranded: 3 Files` |
| a HEIC photo that will not decode | `Stranded: 1 Screenshot` |
| anything parked | `Model Paused: 2 Screenshots [Unpaid]` |

### pigeonhole — topic `pigeonhole`

| When | Title |
|---|---|
| clean proposals | `Staged: 3 Documents` |
| blocked — the 11 document codes | `Blocked: 1 Document` |
| blocked — `CLASSIFY_FAILED` | `Model Failed: 1 Document` |
| flagged for review | `Flagged: 1 Document` |
| `stage_file` failed, file left at root | `Stuck: 1 Document` |
| staged 7d, no decision → `bin/` | `Binned: 1 Document` |
| blocked doc staged 24h | `Still Blocked: 1 Document [1d]` |
| flagged doc staged 24h | `Still Flagged: 1 Document [1d]` |
| clean docs still staged 24h | `Still Staged: 3 Documents [1d]` |
| parked 7d, API never answered → `bin/` | `Abandoned: 1 Document` |
| a tap's move was refused | `Refused: 2 Documents` |
| anything parked | `Model Paused: 3 Documents [Unreachable]` |

### liquidroom — topic `liquidroom`

One notification **per verb present in the run**.

| When | Title |
|---|---|
| interim, downloads complete | `Downloaded: 2 Tracks` |
| stems ready | `Finished: 1 Track` |
| download failed | `Dropped: 1 Download` |
| separation failed | `Halted: 1 Separation` |
| unsafe or symlinked result | `Refused: 1 Result` |
| empty result | `Emptied: 1 Result` |
| destination appeared mid-run | `Raced: 1 Track` |
| publish failed | `Unpublished: 1 Track` |
| already exists · duplicate request | `Skipped: 1 Track` |
| not a request | `Stranded: 1 File` |
| could not move a stray | `Stuck: 1 File` |

Bounded by `MAX_PER_RUN=3`, so at most three distinct failure verbs. Typical run 2
notifications, bad run 4, worst realistic 6. `Downloaded`, `Finished` and `Skipped` are
**receipts** (the result of your request); every other verb goes out as a **fault**
(2026-10-31 — all were receipts before, which left the receipt gate unable to tell this
loop's good news from its bad). Neither carries a sequence id or actions, so multiplying
them adds no lifecycle logic.

### immich — topic `immich`

| When | Title |
|---|---|
| rotations landed | `Baked: 3 Rotations` |
| photos it could not settle | `Flagged: 2 Rotations` — stable id `immich-flagged` |
| the run failed | `Rotation Bake: Failed` — stable id `immich-bake-failed` |

**Split on 2026-08-21.** One message used to carry both the rotations that landed and
the photos wanting a human, under a title counting only the first — so
`Baked: 2 Rotations` could sit above three lines. They are different kinds, and both
pigeonhole and liquidroom already split this way.

The failure body no longer repeats `tail -n 8` of the run: immich is a **worker**, so
the courier's message arrives beside it carrying exactly the job's last eight lines of
stdout (§ 8). This one adds the parsed counts instead, which the courier cannot know.

### restic — topic `restic`, via the courier

| Job | Cadence | Failure | Next success after a failure |
|---|---|---|---|
| `restic.backup` | daily, 00:00–01:00 | `Backup: Failed` | `Backup: Recovered` |
| `restic.forget` | weekly, Mon 06:00–07:00 | `Forget: Failed` | `Forget: Recovered` |
| `restic.check@subset` | monthly, 1st 03:00–04:00 | `Check Data Subset: Failed` | `Check Data Subset: Recovered` |
| `restic.staleness` | daily 09:00 | `Staleness: Failed` | `Staleness: Recovered` |

A success is silent (nuance 14). The recovery replaces the failure in place — see § 4,
the fault lifecycle — and every other job the courier reports behaves the same way.

All carry `RandomizedDelaySec=3600`, hence the one-hour windows.

Two check modes are **manual-only** and so have no cadence row: `check@meta`
(structural pass alone, unscheduled 2026-08-07) and `check@data` (full `--read-data`,
unscheduled 2026-08-22 — the monthly `n/6` rotation reads the whole repository twice
a year and supersedes it). Both still emit through the courier when run by hand, as
`Check Metadata: Failed` and `Check Data: Failed`; the
branches that spell those out are in `system-ntfy.sh`, which is why a manual run does
not title itself `Check@meta`. They are listed here because this file is the record
of *every* title the system can produce, not only the scheduled ones.

### calendar feeds — topic `hitome` (`radicale/feeds/feeds.notify.sh`)

| When | Title |
|---|---|
| one event marked "going" in hitome was cancelled at its source | `Cancelled: The Violinist` |
| several in one run | `Cancelled: 2 Events` |

A **receipt**: the calendar already shows the event crossed out (`STATUS:CANCELLED`)
and there is nothing to tap, so no buttons and no id, and it is never withdrawn.
Each item's detail is when it was (`Tue 13 Oct, 16:45`). Only MARKED events notify;
an unmarked event that vanishes is simply deleted. The feeds are Python, so the sink
shells out to this one bash script rather than growing a second transport.

### grayjay — topic `grayjay`

No buttons anywhere: adding a video to a 📦 playlist, or a channel to the Archive
subscription group, on the phone IS the decision, so
everything here is a receipt or a fault and nothing is ever withdrawn.

**Silent unless something fails** (owner, 2026-10-31). A video that saves sends nothing,
however many arrive. The one piece of good news is a video you were already told had
failed (`Dropped` or `Abandoned`) that saves after all: it closes its own loop with
`Archived`, the same word as the end state because the end state is the same.

| When | Kind | Title |
|---|---|---|
| a video that had failed is now saved | receipt | `Archived: 50 City Pop Style Guitar Licks…` |
| several such in one run | receipt | `Archived: 3 Videos` |
| a video's FIRST failure | fault | `Dropped: 1 Video` |
| still failing 7 days from that first failure | fault | `Abandoned: 1 Video` |
| neither backup file opens | fault, id `grayjay-backup` | `Backup: Unreadable` |
| newest backup older than 7 days | fault, id `grayjay-backup` | `Backup: 8 Days Old` |
| a channel in the Archive group cannot be listed | fault, id `grayjay-channel-<channel id>` | `Channel: Unreadable` |
| ArchiveBox could not be asked, or refused `add` | fault, id `grayjay-archivebox` | `ArchiveBox: Unreachable` |
| ArchiveBox answers again | recovery, same id | `ArchiveBox: Reachable` |
| the backup opens and is fresh again | recovery, id `grayjay-backup` | `Backup: Current` |
| that channel lists again | recovery, same id | `Channel: Readable` |

`Dropped` is liquidroom's word reused, because the situation is the same one: a
download failed. Between the first failure and day 7 the video is retried daily in
SILENCE, so `Dropped` is said exactly once per video. A receipt's detail is the tag
(`Tag: Guitar`); a fault's is the reason, compact and without a stop
(`Timed out after 2h`). Unreadable and stale share one id because they are two states
of one subject and only the newest is worth keeping. Already-archived videos, a video
in both playlists, an unchanged backup, a video that saves normally, and a video taken
out of the playlist while unfinished, or whose playlist or channel stops being followed
(it simply stops being tracked) are all silent. A video that vanishes from a channel
STILL followed is not: it is a failure, so it is `Dropped` and `Abandoned` like any
other. `<Tag>: Missing` and `<Tag>: Found` retired on 2026-11-01 with the hand-kept
playlist list; a playlist that disappears is no longer followed. A
lasting fault re-sends once a day on its stable id, so the phone holds ONE message that
refreshes itself each morning until the cause is fixed, the same shape as `disk` and the
watchdog.

### host / disk / changedetection / watchdog

| When | Topic | Title |
|---|---|---|
| one filesystem ≥ 75% | `disk` | `zpool: 78% Full` |
| both ≥ 75% | `disk` | `Filesystems: 2 Full` |
| a container didn't start at boot | `host` | `Boot: 2 Containers Down` |
| exactly one watch wrong | `changedetection` | `Yellowpaige Shop: Broken` |
| two or more wrong | `changedetection` | `Watches: 3 Findings` |
| container down | `changedetection` | `Changedetection: Not Running` |
| any watchdog finding | `host` | `Watchdog: 3 Findings` |
| the next roll call is clean | `host` | `Watchdog: All Clear` (same id) |
| a container finding clears on its own | `host` | `Containers: Running` · `immich-server: Running` (same id) |
| a watch finding clears | `changedetection` | `Yellowpaige Shop: Working` · `Watches: Working` (same id) |
| the watchdog stalled, then runs again | `host` | `Watchdog: Stalled` → `Watchdog: Running` (deadman, same id) |
| any courier-reported job succeeds after failing | routed | `Backup: Recovered` · `Sync: Recovered [filmhouse]` |

`disk` and `smart` deliberately send **no** recovery: you fix those yourself, so you
already know (owner, 2026-10-31). Recovery is for faults that heal without you.
| any unit's `OnFailure=` | routed | `Backup: Failed` · `[restic]` appended when rerouted |

---

## 8. Reporters and workers

Six jobs send their own notification rather than leaving it to the courier. They split
into two kinds, and the split decides whether the courier ALSO fires.

| | **Reporter** | **Worker** |
|---|---|---|
| The bad news is about | the **world** — a full pool, a broken watch, a stale job | the **job itself** — the bake crashed, files would not move, the boot did not finish |
| Did the job do its work? | yes; it looked, and found something | no |
| Exit code | `0` | non-zero |
| Courier fires | only if the alert did not land | **always** |
| Jobs | `disk` · `changedetection` · `heartbeat` | `catallenya` · `immich` · `afterimage` · `pigeonhole` |

**A reporter exits non-zero only when its own message could not be delivered.** All three
test the transport's *silence* — `curl -fsS` prints nothing on success — and fail only if
it said something. So the two layers never overlap: alert delivered, courier quiet; alert
lost, courier fires and is the only way you learn.

**A worker must exit non-zero, and that is not negotiable.** `ExecStartPost=` writes the
completion stamp only when `ExecStart` succeeded, so a failed run that exited 0 would
stamp healthy and the watchdog would report it fresh. The exit code is what keeps a
failed bake, a stuck spool or a bad boot from looking fine.

### So a worker sends two messages, and that is accepted

A failed bake produces `Rotation Bake: Failed` from the script and again from the
courier. A bad boot produces `Boot: 2 Containers Down` and `Catallenya: Failed`. Both
land seconds apart on the same topic.

**Kept deliberately (2026-08-21), after being changed and changed back.** `catallenya`
briefly cancelled its inherited `OnFailure=` to send one message instead of two. The
reasons for reverting:

- **The courier's copy is the only evidence the `OnFailure=` path still works for that
  unit.** Mute a job, and if its own notify quietly breaks, nothing reports that the
  path is dead.
- **It closes the one real blind spot.** A script that dies BEFORE reaching its notify —
  a missing `.env`, an OOM, a timeout kill — has sent nothing. With the courier muted,
  that is silent until the watchdog notices, up to 36h later for a daily job. With it
  firing, it is covered in seconds.
- **The events are rare.** A handful a year, on things you unambiguously want to know
  about. Not the class of problem that `host/disk.sh` had, where an hourly job stacked
  45 notifications over one weekend.

The two messages are not identical in value: the job's says *what* went wrong
(`Stuck: 2 Documents`), the courier's says *the unit failed* and carries the job's own
journal output. The first is better wording; the second is the proof the path is alive.

### The escape hatch exists and is unused

`systemd/install.sh` refuses an empty `OnFailure=` on any unit that has not declared
`SelfAlerting=acknowledged` in its `[X-Catallenya]` sticker — the same shape as
`UnboundedRoot=acknowledged`. **No unit declares it**, and the gate keeps it that way,
exactly as it does for `RuntimeMaxSec=` and `ExecStart=-`. Switching off a job's failure
alerting is the silent-failure class this repo is built to prevent, so it may be done,
but never quietly.

---

## 8b. The publishers this repo does not own

**Three things publish to this ntfy that are not this repo's code.** Named because a
contract listing only what it governs reads as though it governs everything.

| Publisher | Wired via | Status |
|---|---|---|
| **watchtower** | `docker-compose.yml`, shoutrrr | **in the contract, hand-matched** |
| **changedetection** (the watches) | Apprise, set in its **UI** | **reshaped, but unenforceable** |
| **zed** (ZFS Event Daemon) | `/etc/zfs/zed.d/` on the host | **in the contract, hand-matched** |
| **GitHub Actions** (`notify-failure`) | `.github/workflows/ci.yml`, `curl` | **in the contract, hand-matched, gate-checked** |

None of the four can call `ntfy/kinds.sh` — a Go binary, a Python app, a POSIX shell
function outside the repo, and a job on someone else's runner — so all four match the
grammar **by hand**, exactly as `ntfy/system-ntfy.sh` does. That is **five hand-matched
publishers**, and the number should not grow: each is a place the gate cannot fully reach.

### GitHub Actions

Added to this list on **2026-08-23**, and it was the one publisher nobody had noticed
was here. It posts to the **public ntfy.sh**, not to this box's instance — a runner
cannot reach the tailnet — using the `NTFY_FAILURE_URL` secret. That is the only reason
CI can tell you anything at all when a push fails.

**It was violating the contract and had been since the contract landed.** It carried
`Priority: high` and `Tags: rotating_light`, both of which left `notify()` on
2026-08-20, plus a hand-written `CI failed: <repo>` title. It escaped every check for a
reason worth stating plainly: `systemd/contract.sh` scanned tracked **shell**, and this
is **YAML**. "Nothing shouts" was written in two documents and was false in CI for three
days — the same shape as the wrapped `high` in pigeonhole that was false for nine.

It is now `catallenya: CI Failed` (`title_state`'s shape, subject narrower than the
topic, `${REPO##*/}` dropping the owner a lock screen has no room for) over a body of
one `•` fact and a bare URL, and it is the **only** hand-matched publisher the gate
actually reads — rule 10 refuses `Priority:` or `Tags:` in any workflow file. It is also
`--data-raw` rather than `-d` and carries `--max-time`, matching the transport.

### watchtower

Body in `watchtower/notification.tmpl`, a Go template. **It is silent unless something
FAILED**, which is what every other job here does. Before 2026-08-22 it fired on every
run that changed anything, which meant **every night** — `tomsquest/docker-radicale:latest`
is rebuilt upstream daily, and three consecutive days of it sat in the ntfy cache.

`WATCHTOWER_NOTIFICATION_REPORT=true` is what makes a contract-shaped body possible: it
swaps the template's data from a list of log lines to the structured session report.

Three things learned on the box and recorded in the template's own header: a template
that fails to parse **falls back to the default** and logs it, so a broken one surfaces
as the OLD message rather than as silence; the outer `if .Report` guard is load-bearing
because watchtower renders the template for its **startup** message too, where `.Report`
is nil; and the failure branch must be proven to RENDER, since testing only the silent
path is indistinguishable from a template that never emits.

**The title is not ours and cannot be.** shoutrrr's ntfy service does not let the sender
set one, so it stays `Watchtower updates on <hostname>`. `hostname: watchtower` in compose
fixes the half that could be fixed — it read `…on 6729304e71db`, the container id.

### zed

Titles are built in `zed_ntfy_title()`, a local addition to
`/etc/zfs/zed.d/zed-functions.sh`. The file is vendored at **`host/zed-functions.sh`**
and installed by `sudo bash host/zed.install.sh`.

| Event | Title |
|---|---|
| `scrub_finish` | `Scrub: Finished` |
| `resilver_finish` | `Resilver: Finished` |
| `data` | `Data: Errors Found` |
| `statechange` FAULTED/DEGRADED/REMOVED/UNAVAIL | `Device: Faulted` / `Degraded` / `Removed` / `Unavailable` |
| anything else | zed's own subject, unchanged |

The mapping is exhaustive for the four enabled zedlets and is built from `ZEVENT_*`
rather than by parsing the subject — there are five subject shapes across the zedlets,
so a regex over the prose would be matching wording upstream is free to change.

**The pool cannot be the subject**: the topic is `zpool` and the pool is literally named
`zpool`, so it would repeat the topic. The EVENT is the subject instead.

**Bodies are left verbatim**, and that is not laziness — a `zpool status` dump is what
you want when a disk is failing, for the same reason `system-ntfy.sh` sends a raw
journal excerpt.

**Four defects were fixed in the same edit**, all of them ones this repo had already
fixed elsewhere on 2026-08-19: no `-f` (an HTTP error returned 0 and the alert vanished
while zed recorded success — on the channel that reports a dying disk), no `--max-time`,
`-d` instead of `--data-raw`, and no CR/LF strip on the `Title:` header. `Priority: high`
was hardcoded and is gone.

Each is verified rather than assumed: an HTTP error now returns 1, an unreachable host is
bounded at exactly 15s, and a real publish lands as `Scrub: Finished` with no priority
and no tags.

### changedetection

Its topic has **two publishers by design**: the watches themselves, and
`changedetection/changedetection.health.sh`, which IS in the contract. Sharing one topic
is deliberate — an unsubscribed monitoring topic swallows alerts with a 200 OK.

Titles were reshaped on 2026-08-22 and the values are recorded here **because they are
not in git**:

| Scope | Title |
|---|---|
| global default | `{{watch_title}}: Changed` |
| watch `0710e790` | `Spliffy T-Shirt: Changed` |
| watch `2e19ad86` | `YellowPaige Shop: Changed` |

Both also carry a `click=` URL (above), which is stored in the same unenforceable place.

Bodies are left alone: `{{diff}}` is changedetection's own diff format and there is
nothing to reshape it with.

**`notification_format` stays `text`, and that is a SECURITY setting rather than a
cosmetic one.** It was recorded here as costing a tappable URL — *"ntfy autolinks nothing
in a message it was not told to render"* — and **that was measured wrong** (corrected
2026-08-23). It is the other way round: with no render header the CLIENT linkifies a bare
URL, and with rendering on it does not unless the URL is wrapped in `<…>`. So `text` costs
nothing here; the security argument below stands entirely on its own. The temptation is to switch to
`markdown`, and it must be resisted — changedetection escapes untrusted page content
**only for HTML formats** (`if 'html' in requested_output_format` in
`notification/handler.py`), which is the fix for GHSA-q8xq-qg4x-wphg. Markdown is not
covered. Under it, a watched shop whose product name contained `[click here](https://evil)`
would put a live phishing link in a notification the operator already trusts — the exact
threat the renderers guard against everywhere else, in the one place this repo cannot do
the escaping itself.

**The tappability is bought back with ntfy's `click` header instead**, set per watch in
its Apprise URL:

```
ntfy://ntfy/changedetection?click=https%3A%2F%2Fwww.yellowpaige.com%2F
```

Tapping the notification opens the page; the body stays unrendered. It has to be
per-watch because changedetection runs Jinja over the body and title but **not** over the
notification URL, so `{{watch_url}}` there would arrive literally.

**This is the one part of the contract that cannot be enforced, and the reason is worth
understanding.** A watch's own `notification_title` **overrides** the global default, and
it lives in `changedetection/data/<uuid>/watch.json` — root-owned, gitignored, and
unreadable by `--check`, which must run without docker. Retype a title in the UI and no
diff, no gate and no test will notice.

The inheritance runs the safe way, though: a **new** watch left with empty notification
fields takes the global default, so the shape propagates on its own. It is the explicit
per-watch override that escapes — which is what both existing watches were doing.

Global settings have no API endpoint (v1 is watch-only), so changing that default means
stopping the container, editing `changedetection.json`, and starting it again. A backup
sits at `changedetection.json.bak.pre-contract`.

---

## 9. Enforcement

`systemd/contract.sh`, eleven rules, run by `bash systemd/install.sh --check` (no root
needed) and by `systemd/tests/run.sh`. **Since 2026-08-23 that command is also a CI job
and a `ci/pre-push` hook** — before then it ran only when a human typed it, and a unit
it refuses reached `main` green:

1. Every title argument is a `title_count`, `title_state` or `title_quote` substitution —
   nothing hand-built. A variable is followed to its assignment.
2. Its verb is in `NTFY_MODEL_VERBS` **or** in that file's own `NTFY_VERBS`.
3. Every `NTFY_VERBS` entry ends in `ed` **or** appears in `NTFY_IRREGULAR_VERBS`.
4. **No bare `notify ` outside `ntfy/`** — every job goes through a kind. This is what
   makes the wrappers authoritative; there is no merge engine underneath them.
5. **No `clear=true`** in an Actions string. It dismisses on the *tap*, before the work
   behind the button has happened, so a refused move would look like a completed one.
6. **A `notify_nudge` title reads as a nudge** — a `Still ` verb or a `title_age`
   bracket. A nudge indistinguishable from the first asking tells you nothing.
7. **No hand-built numbered list.** A literal `1\.` is what four files each discovered
   separately on the phone, after which each grew its own cap, its own truncation tail
   and its own indent — two of which were already different widths by the time they
   were collected.
8. **No hand-built italic line.** Italics mark a truncation count and nothing else, and
   `body_aside` is the only thing that emits them. The check looks for an underscore run
   closing before a quote, so it catches the shape `paused_body` shipped in for a year:
   italics inside a `printf` *format* string, which anything anchored on a leading `"_`
   walks straight past.
9. **No markdown link syntax in a body.** The renderers neutralise it in anything they
   escape, but PROSE is unescaped, so this is the one place a live link could be authored
   by hand. It matches `](http` — link syntax specifically, not a bare URL, which is
   allowed and is load-bearing in changedetection's body.
10. **No `Priority:` or `Tags:` header in a CI workflow.** The nine rules above read
    tracked shell; this one reads `.github/workflows/*.yml`, because a runner emits
    notifications too and nothing was looking. Deliberately narrow — a workflow is a
    sanctioned hand-built emitter (§8b), so what is checked is only the part that is
    unambiguous regardless of who assembled the string: the two headers with no legal
    value left anywhere in this system.
11. **A receipt carries an approved word** (2026-10-31). Quiet on success: the receipt is
    the one kind that can say good news, so its verb (`title_count`) or state
    (`title_state`) must be in `NTFY_RECEIPT_VERBS` in `ntfy/kinds.sh`. **Repo-wide**,
    unlike rules 1–9, which run only over intake-family trees — most receipts live
    outside them. A title variable is followed to its nearest earlier assignment; a word
    that is itself a variable is refused, because nothing static can read it.
    Alongside it, `install.sh` refuses `OnSuccess=` on every class.
    **Two shapes it cannot see, accepted (2026-10-31 audit):** a wrapper that forwards a
    positional title (`send() { notify_receipt "$1" …; }`), and a title variable
    reassigned to a plain string after a constructor assignment (it is judged on the
    stale constructor word). Nothing in the repo writes either; hardening the parse was
    judged not worth its complexity. Write receipts inline and this cannot bite.

Rules 1–3 are about the title, 4–6 about the envelope, 7–8 about the body, 11 about
what is allowed to be good news.

Gate rule 3 is what stops a new service breaking rule 3-of-§5 silently. It refuses
`Processing`, `Uploading`, `Waiting` — **and** `Stray`, `Unclear`, `Timeout`, which a
looser `-ing`-only check would have waved through. Both of those adjectives were proposed
during design.

**Vocabulary is declared per feature, never centrally** — with one deliberate exception,
`NTFY_RECEIPT_VERBS`, where each entry is an owner's decision that a piece of good news
earns a buzz and the friction of a central line is the point. Each feature's lib sets its own
`NTFY_VERBS` / `NTFY_NOUNS` / `NTFY_SUBJECTS`. This is the same shape as
`[X-Catallenya] Class=`: the thing declares, and nothing repeats it in a map. A central
verb table would be the `SUBSCRIBED` list again — hand-maintained, and it silently ate
four units' alerts once already.

**One exemption in the whole repo:** `ntfy/system-ntfy.sh`. See nuance 12.

---

## 10. Traps

**There is no merge engine.** `systemd/policy/` works because systemd genuinely merges
drop-ins — verified on this box, a unit's `RuntimeMaxSec=999` lost to a drop-in's `111` —
so that layering holds even when `install.sh` is wrong. Nothing equivalent happens here.
**Gate rule 1 is the only thing making the constructors authoritative.** Treat it as
load-bearing, not tidiness.

**A new tracked file needs a `.gitignore` allowlist line.** The file starts with `*` deny.
Without a line, a new file is untracked, invisible to `git status`, and silently absent
from anything reading the tree.

**`systemd/tests/run.sh` builds its check tree from a hardcoded directory list.** A
directory missing from it means a mutation case edits a file that is not in the tree, the
gate finds nothing to refuse, and the failure reads as *the gate stopped working* rather
than *the test is misconfigured*. That broke 23 cases on 2026-08-15.

**Nothing verifies a retract actually happened.** The wire is where visibility ends — the
same blind spot as ntfy accepting a publish to an unsubscribed topic with a 200 OK.

**Adding a new service?** Declare `NTFY_VERBS` in its lib, source `ntfy/kinds.sh` after
`ntfy/ntfy.lib.sh`, build every title with a constructor, and run
`bash systemd/install.sh --check`. Read §1 first to work out which class each of your
messages belongs to — that decides whether you may choose your own words.
