# Repository Guidance

## Use this lane when

- Use when repository-root or path-scoped instructions, component documentation, schemas, or another explicit current repository source governs changed paths or behavior.
- Skip when no explicit, current, and applicable repository source can be identified.

## Source authority

- Default-branch policy governs behavior the pull request does not intentionally redefine. When a pull request updates governing policy alongside its implementation, review the proposed policy on its merits and verify that any required approval is explicitly recorded by a repository-authorized maintainer in the pull request or linked issue. Do not block solely because the implementation conflicts with text the same change supersedes, and do not require a separate prerequisite pull request merely to make the old text cease governing.
- The most-specific applicable path instruction may strengthen requirements, but it cannot weaken repository-root vetoes or outcome rules.
- Current code, tests, schemas, and neighboring patterns are evidence, not authoritative policy without an applicable normative instruction.
- The pull request body and conversation provide context rather than durable policy. However, an explicit decision from a repository-authorized maintainer satisfies a human approval gate when the governing policy update is committed in the same pull request; it does not waive independent correctness, security, privacy, or data-loss risks.

## What this lane should catch

- **Applicable repository requirement violations**
  - **Report when:** A changed path or behavior conflicts with an explicit current repository requirement that applies to it.
  - **Evidence:** Cite the repository-relative source and relevant requirement, explain why it governs the change, and identify the conflicting path or behavior and its consequence.
  - **Do not report:** Generic industry advice, personal preference, optional examples, aspirational guidance, or an isolated neighboring pattern that is not an authoritative requirement.

- **Documented contract regressions**
  - **Report when:** Changed behavior no longer satisfies a documented component, interface, data, compatibility, operating, or lifecycle contract that remains current and applicable.
  - **Evidence:** Cite the governing repository source, connect it to the changed behavior, and explain the concrete consequence for a caller, consumer, operator, or persisted state.

- **Missing required safeguards or verification**
  - **Report when:** An applicable repository source explicitly requires a safeguard or verification step for this kind of change and the pull request does not satisfy it.
  - **Evidence:** Cite the requirement, show why it applies to the change, and identify the required evidence or protection that is missing.
  - **Do not report:** Merely absent tests, documentation, or verification that no applicable repository source requires and that does not establish a concrete correctness problem.
