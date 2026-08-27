# Agent Instructions

- Do not create or publish a release unless the user explicitly asks for that
  exact release. Approval for one version never carries over to another.

## Releases

- Confirm the exact version and build number before changing release metadata.
- Require brief Markdown release notes and pass them with `--notes` so they
  appear in both Sparkle and the GitHub release.
- Run `make check`, then release from a clean commit with
  `./script/release.sh <version> --build <build> --tag v<version> --notes <notes> --upload`.
- Verify the tag target, uploaded assets, signing/notarization, and that the
  appcast contains the correct version, build, download URL, and release notes.
- Never replace or delete a published release without explicit permission.
