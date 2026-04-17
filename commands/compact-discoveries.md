Compact old discoveries into a condensed summary and trim the active file.

Use the Task tool to delegate this work to a subagent with `model: sonnet` and `subagent_type: general-purpose`. Pass the following prompt to the subagent:

---

You are working in a cs session. Your task is to summarize old discoveries and trim the active file to stay within its size budget.

## Steps

1. **Check if compaction is needed:**
   - Read `.cs/discoveries.md`
   - Measure the file size with `wc -c`
   - Get the budget: `${CS_DISCOVERIES_MAX_SIZE:-60000}` bytes (default 60KB, override via env var)
   - If the file is under the budget, report that there's nothing to compact and stop

2. **Read the full discoveries.md** and identify all `##` entries

3. **Decide what to keep vs compact:**
   - The most recent entries (roughly the last half of the budget) stay in `discoveries.md` untouched
   - Older entries get summarized into `.cs/discoveries.compact.md`

4. **Produce a condensed summary of the older entries** with these rules:
   - Each original `##` entry becomes 1-3 bullet points capturing the key technical finding
   - Merge entries that cover the same topic into a single section
   - Drop entries that were superseded or corrected by later entries
   - Preserve actionable information: file paths, command patterns, configuration values, workarounds
   - Drop exploratory dead-ends unless they contain useful "don't do this" warnings

5. **Update `.cs/discoveries.compact.md`** using this format:

```markdown
# Compacted Discoveries

> Condensed summary of older findings. See discoveries.md for recent entries.

## [Topic or Finding Title]
- [Key point 1]
- [Key point 2 if needed]

## [Next Topic]
- [Key point]
```

If `discoveries.compact.md` already exists, merge the new compacted entries into it (don't duplicate existing sections — update them if the new entries add information).

6. **Trim `discoveries.md`:**
   - Keep the `# Discoveries & Notes` header
   - Keep only the recent entries (the ones NOT compacted)
   - Write the trimmed file back

7. **Report back:**
   - How many entries were compacted vs kept
   - The size reduction (before vs after in characters)

## Important

- Read the ENTIRE discoveries.md before writing — context from later entries may supersede earlier ones
- Split on `##` heading boundaries — never break an entry mid-section
- Favor precision over brevity: a specific file path or command is more useful than a vague description
