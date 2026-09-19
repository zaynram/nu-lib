# 02 — Scorecard

Scored against the per-principle anchors; worst instance scored; ties broken downward.

1. Good design is innovative — Score: 1/3
   Evidence: E5 (structured issue file pushed to GitHub, sqlite mirror); peers git-issue, tissue, `gh issue`.
   Justification: imitates the file-backed-issue pattern with a mirror added; no clear improvement over peers, not a wholesale copy.

2. Good design makes a product useful — Score: 1/3
   Evidence: E5 three load paths; E4 import→dump→push chain; E3 L229 recovery deleted.
   Justification: the primary task completes, but only through the mirror detour (import, then dump, then push) and the failure path strands the user.

3. Good design is aesthetic — Score: 1/3
   Evidence: E1 shape drift (`output` table vs array, `outcome` string vs record, `tasks.0` vs `tasks.1`), split `[issue.vision.landscape]`.
   Justification: a system exists (v3) but 4 inconsistencies show across 9 files; not 0 because most files do follow one shape.

4. Good design makes a product understandable — Score: 1/3
   Evidence: E5 `main`/`fetch`/`load` overlap; E3 L248 `all flags are mandatory`; E3 L202 recovery hint that names a `gh` passthrough flag absent from the module help.
   Justification: three controls are unclear without reading source; not 0 because `issue main <slug>` and `tasks list` are identifiable.

5. Good design is unobtrusive — Score: 1/3
   Evidence: E4 L697 auto `git commit`; E4 L243–247 `undo` constrained by "sync commits".
   Justification: the tool writes into the user's git history and then polices it; that competes with the user's own work, short of dominating it.

6. Good design is honest — Score: 0/3
   Evidence: E4 L1 "TOML as source of truth" vs 30 db calls; E3 L202 recovery hint names a `gh` passthrough flag the module's help never mentions; E3 L229 resume file deleted after being offered; E3 L355/L395 v2 completions on v3.
   Justification: the failure-path message directs the user to a recovery whose input file is deleted before they can use it; that is a deceptive flow even if unintended, plus two further mismatches.

7. Good design is long-lasting — Score: 1/3
   Evidence: E2 8/9 files rejected by TOML 1.0; E1 numbered task keys; E3 L355 v2 residue.
   Justification: three dated markers: a parser-specific dialect, order-by-key-name tasks, and a stale property list.

8. Good design is thorough down to the last detail — Score: 1/3
   Evidence: E7 no dry run, unusable recovery, version drift accepted with a warning (E4 L9–11).
   Justification: empty and error states exist; recovery, dry run and validation are missing or rough (3 states).

9. Good design is environmentally friendly — Score: 1/3
   Evidence: E6 duplicated store, 28 db statements per `dump`, 8 git calls per `undo`; import 19–26 ms.
   Justification: startup cost is fine, but every task is stored twice and every sync pays a fan-out of subprocess and db calls.

10. Good design is as little design as possible — Score: 0/3
    Evidence: E5 18 exported commands, 6 of them (`import load dump retarget undo meta`) servicing the mirror; duplicated `list` and three load paths.
    Justification: duplicated affordances dominate the surface; the mirror and its six commands are removable without losing the task.

Total: 8/30
