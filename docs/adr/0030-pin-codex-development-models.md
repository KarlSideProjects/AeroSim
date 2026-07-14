# Pin Codex implementation and advisory models

Project Codex sessions default to `gpt-5.6-luna` with high reasoning effort for repeatable implementation work. A read-only `sol_advisor` custom agent uses `gpt-5.6-sol` with high reasoning effort only for bounded, ambiguous, high-value questions; the main agent validates its evidence and owns the decision. Model unavailability must be reported rather than silently substituting while claiming the pinned model was used.
