# Reviews

Dated code reviews of `ivaliceCluster` and the `sphinx-asr` submodule.
Each review is a page with one table row per finding and a **Status**
column. Reviews are records: the findings and their wording stay as
written; only the Status column changes as findings are fixed.

| Review | Scope | Findings | Verdict |
| --- | --- | --- | --- |
| [2026-10-04 baseline](2026-10-04-baseline.md) | sphinx-asr @ bf06688, ivaliceCluster @ 9c6c4aa | 21 sphinx-asr (SA-1 to SA-21), 15 ivaliceCluster (IC-1 to IC-15) | request changes, both |

## Status values

| Value | Meaning |
| --- | --- |
| `open` | Not addressed yet (default) |
| `in progress` | A branch or PR is working on it |
| `fixed (<sha>)` | Fixed; the sha is the commit (or submodule bump) that fixed it |
| `wontfix: <reason>` | Rejected, with the reason |

The post-commit vault export (see
[Documentation workflow](../standards/documentation-workflow.md)) counts
rows whose status is `open` or `in progress` across every review page and
puts the totals in the research vault note.

## Adding a review

Create `docs/reviews/YYYY-MM-DD-<scope>.md`, keep the
`| ID | Sev | Where | Defect | Fix | Status |` column layout so the export
can parse it, add a row to the table above and an entry to
`docs/SUMMARY.md`.
