---
name: prose-hygiene
description: Remove AI writing tells from prose. Use when drafting, editing, or reviewing text to eliminate predictable AI patterns.
metadata:
  source: taxonomy adapted from stop-slop (github.com/hardikpandya/stop-slop, MIT), reworded for cs; synced at upstream 8da1f03 (2026-03-18)
---

# Prose Hygiene

The complete checklist for removing AI writing tells from prose. While drafting,
avoid the patterns below. A reviewer applying this reads the prose, flags every match
below with the quoted text and a concrete rewrite, then scores it (see Scoring). A
regex can only catch the lexical items; the structural and voice rules need a model
judging meaning. cs applies this to /summary and /wrap output (`.cs/summary.md` and the memory
entries; the narrative notebooks are exempt); the lexical subset is enforced by
`cs -lint` and the prose-lint Stop hook.

## Core principles

1. **Cut filler.** Remove throat-clearing openers, emphasis crutches, and every adverb. Say the thing.
2. **Break formulas.** No binary contrasts, negative listings, dramatic fragments, rhetorical setups, or false agency.
3. **Use active voice.** Every sentence needs a human subject doing something. No passive constructions. No inanimate object performing a human verb.
4. **Be specific.** Name the actual thing. No vague declaratives ("the reasons are structural"). No lazy extremes doing vague work.
5. **Put the reader in the room.** "You" beats "people." Specifics beat abstractions. No narrating from a distance.
6. **Vary rhythm.** Mix sentence lengths. Prefer two items to three. End paragraphs differently. No em-dashes.
7. **Trust the reader.** State facts directly. Skip softening, justification, and hand-holding.
8. **Cut quotables.** If a line sounds like a pull-quote, rewrite it.

## Phrases to cut

### Throat-clearing openers
Announcements before the point. Cut them and state the point.
"Here's the thing", "Here's what/this/that/why [X]", "The uncomfortable truth is", "It turns out", "The real [X] is", "Let me be clear", "The truth is", "I'll say it again", "I'm going to be honest", "Can we talk about", "Here's what I find interesting", "Here's the problem though". Any "here's what/this/that" construction is throat-clearing.

### Emphasis crutches
Add no meaning. Delete them.
"Full stop.", "Period.", "Let that sink in.", "This matters because", "Make no mistake", "Here's why that matters", "Needless to say", "Rest assured", "Without a doubt", "The fact of the matter is".

### Business jargon
Replace with plain language: navigate → handle; unpack → explain; lean into → accept; landscape → situation; game-changer → significant; double down → commit; deep dive → analysis; take a step back → reconsider; moving forward → next; circle back → revisit; on the same page → aligned.

### Adverbs
Cut all of them. No -ly words, no softeners, no intensifiers, no hedges. Specific offenders: really, just, literally, genuinely, honestly, simply, actually, deeply, truly, fundamentally, inherently, inevitably, interestingly, importantly, crucially. Also cut these fillers: "at its core", "in today's [X]", "it's worth noting", "at the end of the day", "when it comes to", "in a world where", "the reality is", "last but not least", "when all is said and done".

### Meta-commentary
Remove self-referential asides. The text should move, not announce its own structure.
"Hint:", "Plot twist:" / "Spoiler:", "You already know this, but", "But that's another post", "[X] is a feature, not a bug", "Dressed up as", "The rest of this essay...", "Let me walk you through...", "In this section, we'll...", "As we'll see...", "I want to explore...".

### Performative emphasis
Manufactured sincerity: "creeps in", "I promise", "They exist, I promise".

### Telling instead of showing
Announcing difficulty or importance rather than demonstrating it: "This is genuinely hard", "This is what leadership actually looks like", "This is what [X] actually looks like", "actually matters".

### Vague declaratives
Announce importance without naming the specific thing. Cut, or replace with the specific thing: "The reasons are structural", "The implications are significant", "This is the deepest problem", "The stakes are high", "The consequences are real".

## Structures to avoid

### Binary contrasts
False drama. State the point directly.
"Not because X. Because Y.", "[X] isn't the problem. [Y] is.", "The answer isn't X. It's Y.", "It feels like X. It's actually Y.", "The question isn't X. It's Y.", "Not X. But Y." / "not X, it's Y", "It's not this. It's that.", "stops being X and starts being Y", "doesn't mean X, but actually Y", "is about X but not Y", "not just X but also Y". Fix: state Y directly; drop the negation.

### Negative listing
Listing what something is not before revealing what it is. "Not a X... Not a Y... A Z." / "It wasn't X. It wasn't Y. It was Z." Fix: state Z.

### Dramatic fragmentation
Fragments for emphasis read as manufactured profundity. "[Noun]. That's it. That's the [thing].", "X. And Y. And Z.", "This unlocks something. [Word].". Fix: complete sentences.

### Rhetorical setups
Announce insight rather than deliver it. "What if [reframe]?", "Here's what I mean:", "Think about it:", "And that's okay." Fix: make the point.

### Formulaic constructions
"By the time X, I was Y." (narrative template), "X that isn't Y" (indirect; say "X is broken").

### False agency
Inanimate things given human verbs. AI loves this because it avoids naming the actor. "a complaint becomes a fix", "a bet lives or dies", "the decision emerges", "the culture shifts", "the conversation moves toward", "the data tells us", "the market rewards". Fix: name the human, or use "you".

### Narrator-from-a-distance
Floating above the scene. "Nobody designed this.", "This happens because...", "This is why...", "People tend to...". Fix: put the reader in the room.

### Passive voice
Hides the actor and drains energy. "X was created", "It is believed that", "Mistakes were made", "The decision was reached". Fix: name who did it, at the front of the sentence.

### Sentence starters to avoid
Sentences starting with What/When/Where/Which/Who/Why/How. Paragraphs starting with "So". Sentences starting with "Look,". Fix: lead with the subject or the specific thing.

### Rhythm patterns
Three-item lists (use two or one). Questions answered immediately (let them breathe or cut them). Every paragraph ending punchily (vary endings). Em-dashes (use commas or periods; none at all). Staccato fragmentation (do not stack short punchy sentences). "Not always. Not perfectly." (hedging disguised as reassurance).

### Word patterns
Lazy extremes (every, always, never, everyone, everybody, nobody) assert false authority; use specifics. All adverbs (see Phrases).

## Scoring

Rate 1-10 on each dimension. Total below 35/50 means revise.

| Dimension | Question |
|-----------|----------|
| Directness | Statements, or announcements? |
| Rhythm | Varied, or metronomic? |
| Trust | Respects the reader's intelligence? |
| Authenticity | Sounds human? |
| Density | Anything cuttable? |

## Before / after

- "Here's the thing: building products is hard. Not because the technology is complex. Because people are." becomes "Building products is hard. Technology is manageable. People aren't."
- "It turns out most teams struggle with alignment. The uncomfortable truth is nobody admits they're confused. And that's okay." becomes "Teams struggle with alignment. Nobody admits confusion."
- "In today's fast-paced landscape we need to lean into discomfort and navigate uncertainty. This matters because your competition isn't waiting." becomes "Move faster. Your competition is."
- "The decision emerged from the data, which told us the market was shifting." becomes "We read the usage numbers and cut the feature."

## License

MIT.
