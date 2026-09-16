---
name: polish-before-merge
description: "At merge gates, Alex chooses to apply reviewer-recommended polish items on the branch BEFORE merging (picked 4 of 4 times: archive, queue supervision, delegation router, force-grace rotation). Default the recommendation to polish-first."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 768dbfbe-d5b0-4144-95d8-242dda091009
---

Every time a final whole-branch review returned "Ready to merge: Yes" with ship-as-is Minors plus recommended follow-ups (archive 2026-07-15, queue supervision 2026-07-16, delegation router 2026-09-06, force-grace rotation 2026-09-16), Alex picked "polish first, then merge" over "merge now, polish later."

**Why:** he prefers the branch to land complete, with the reviewer's cheap fixes already inside the merge rather than on a follow-ups list that may drift.

**How to apply:** when presenting a merge gate after a clean final review that names inexpensive polish items, make polish-first the first, recommended option; keep the fix wave to ONE fixer carrying the complete findings list, re-review the fix commit, then merge, verify suites on merged main, and deploy in the same pass.
