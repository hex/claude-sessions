Compact archived discoveries into a condensed summary for context-efficient session resumption.

You are working in a cs session. Your task is to read the raw discoveries archive and produce a condensed technical summary.

## Steps

1. **Check if compaction is needed:**
   - Read `.cs/discoveries.archive.md`
   - If it doesn't exist or has fewer than 50 lines, tell the user there's nothing to compact and stop

2. **Read the archive** and analyze all `##` entries

3. **Produce a condensed summary** with these rules:
   - Each original `##` entry becomes 1-3 bullet points capturing the key technical finding
   - Merge entries that cover the same topic into a single section
   - Drop entries that were superseded or corrected by later entries
   - Preserve actionable information: file paths, command patterns, configuration values, workarounds
   - Drop exploratory dead-ends unless they contain useful "don't do this" warnings

4. **Write the result to `.cs/discoveries.compact.md`** using this format:

```markdown
# Compacted Discoveries

> Auto-generated summary of discoveries.archive.md. Read the archive for full detail.

## [Topic or Finding Title]
- [Key point 1]
- [Key point 2 if needed]

## [Next Topic]
- [Key point]
```

5. **Report to the user:**
   - How many archive entries were processed
   - How many compacted sections were produced
   - The line count reduction (archive lines vs compact lines)

## Important

- Read the ENTIRE archive before writing -- context from later entries may supersede earlier ones
- The compact file replaces the previous version entirely (it's a full re-summary)
- Favor precision over brevity: a specific file path or command is more useful than a vague description
- If `.cs/discoveries.md` (active discoveries) exists, read it too so you don't duplicate content that's still in the active file
