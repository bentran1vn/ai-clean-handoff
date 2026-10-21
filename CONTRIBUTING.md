# Contributing

Open an issue describing the behavior or propose a pull request with a small, focused change.

- Use temporary repositories and synthetic fixtures; never commit client code, tokens, personal paths or migration caches.
- Add regression coverage when changing file preservation or comment parsing.
- Preserve fail-closed behavior for unknown syntax and path collisions.
- Run the checks listed in README.md before submitting.
- Do not add workflows that publish or modify external repositories by default.

New language support should use an appropriate parser and prove that executable content is preserved; regex-only comment stripping is not sufficient.
