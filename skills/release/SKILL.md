---
name: release
description: >-
  Repository-scoped release instructions for Joblet. Use this when the user
  asks to cut a release, create or push a tag, watch the Release workflow, run
  a validation build, or verify the Sparkle appcast for this repository.
  Releases are tag-driven, so do not create a version bump commit just to
  publish a release.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
metadata:
  short-description: Tag-driven release workflow for Joblet
---

# Joblet Release

The canonical reference is the release section in `README.md`. If the skill and
the README diverge, update the README first and then align this skill.

## When to use

- Cut a Joblet release
- Run the `Release` workflow manually for validation
- Verify Sparkle, GitHub Release, and Homebrew release artifacts

## Release

1. Confirm the release changes are already merged to `main` and the `Test`
   workflow is green.
2. Choose `VERSION` and push the release tag.

```bash
VERSION=0.1.0
git tag "v${VERSION}"
git push origin "v${VERSION}"
```

3. Watch the `Release` workflow.

```bash
gh run list --workflow Release --limit 5
gh run watch
```

4. Verify the published artifacts.

```bash
gh release view "v${VERSION}"
curl -fsSL https://mkusaka.github.io/joblet/appcast.xml | rg "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>"
```

Expected results:

- `Joblet.zip` is attached to the GitHub Release
- the matching version is present in `gh-pages/appcast.xml`
- `Contents/Helpers/joblet-mcp` is signed and inside the notarized app
- the dispatch to `mkusaka/homebrew-tap` succeeded inside the release workflow

## Validation Build

Use `workflow_dispatch` when you want to validate signing, notarization, and
export without publishing a release.

```bash
gh workflow run Release --field version=0.1.0
gh run list --workflow Release --limit 5
gh run watch
```

This run does not create a GitHub Release, dispatch Homebrew updates, or update
`gh-pages`.

## Notes

- The release version comes from the tag name. Do not create a version bump
  commit just to publish a release.
- The machine-readable Sparkle version is derived inside the workflow as
  `major * 10000 + minor * 100 + patch`.
