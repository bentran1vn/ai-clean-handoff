# TypeScript and JavaScript support (planned)

Status: planned; not implemented. Unsupported source formats currently stop the comment-cleanup workflow.

The goal is parser-backed cleanup for `.ts`, `.tsx`, `.js` and `.jsx` without changing executable content.

## Acceptance criteria

- Use a language parser; do not strip comments with regular expressions.
- Preserve strings, template literals, regular expressions, JSX text and directives.
- Preserve existing destination comments by the configured matching policy.
- Check syntax and executable token/AST equivalence before accepting cleanup.
- Handle source maps and required license notices deliberately.
- Add regression fixtures for inline, block, JSDoc, JSX and mixed-language cases.
- Fail closed for unsupported syntax or ambiguous transformations.
- Keep the review-before-publish flow and file-preservation checks.

Share minimal examples and expected output in a roadmap issue. Reactions help prioritize this work; this is not a release-date commitment.
