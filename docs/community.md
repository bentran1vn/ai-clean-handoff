# Repository presentation

Keep positioning focused on workspace hygiene and clean handoffs. Do not imply that removing tool artifacts changes authorship or replaces disclosure, license notices, review, or testing.

## About, topics and roadmap issue

After authenticating GitHub CLI, maintainers can run:

```bash
./scripts/update-github-metadata.sh OWNER/REPOSITORY
```

The script sets an About description, adds 20 relevant topics, and creates the TypeScript roadmap issue only if an issue with the exact title does not already exist. It does not change repository visibility or publish code.

## Social preview

Use `docs/images/social-preview.jpg` in repository **Settings → Social preview → Edit → Upload an image**. The asset is a compressed version of the README meme, under 1 MB.

[GitHub's social preview requirements](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview).

## Naming

The repository keeps `copybara-release-sync` for URL stability. The README title, description and topics explicitly include AI-assisted development, agent artifacts and clean handoffs. Revisit a rename separately if desired.
