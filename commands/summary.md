Generate an intelligent summary of this cs session by synthesizing all documentation files.

You are working in a cs session. Your task is to create a comprehensive summary of the entire session by reading and synthesizing all documentation files.

## Steps

1. **Read all session documentation:**
   - .cs/README.md (objective, environment, outcome)
   - .cs/discoveries.md (findings, observations, and ideas)
   - .cs/changes.md (auto-logged file modifications)
   - .cs/artifacts/MANIFEST.json (list of created files)

2. **Synthesize into a cohesive summary** that tells the story of this session. The summary should:
   - Explain what you were trying to accomplish
   - Describe the environment and context
   - Highlight key discoveries and insights
   - Summarize the changes and modifications made
   - List important artifacts created
   - Conclude with the outcome and results

3. **Write the summary to .cs/summary.md** in the session metadata directory. Use this structure:

```markdown
# Session Summary: [SESSION_NAME]

**Date:** [Session date]
**Duration:** [Approximate duration if determinable]

## Objective

[What was the goal of this session?]

## Environment

[What system/server/context were you working in?]

## Key Discoveries

[What did you learn? List important findings with brief explanations]

## Changes Made

[What modifications were made? Organize by category if appropriate]

## Artifacts Created

[List scripts, configs, or other files created with brief descriptions]

## Outcome

[What was accomplished? Were objectives met? What's the current state?]

## Notes for Future Reference

[Any important context or gotchas for future work]
```

4. **Make the summary narrative and insightful**, not just a concatenation of files. Explain the "why" behind discoveries and changes. Connect related pieces of information.

5. **Inform the user** when the summary is complete and where it was saved.

## Important

- Read ALL documentation files completely before writing the summary
- If files are empty or minimal, note what was not documented
- Use your intelligence to create a cohesive narrative, not just bullet points
- The summary should be understandable by someone who wasn't present in the session
- If the session is still in progress, note that in the summary
