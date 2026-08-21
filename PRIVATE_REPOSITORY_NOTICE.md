# Export notice

This is the sanitized public export of the artifact. It is licensed for reuse
under Apache-2.0 (`LICENSE`), which is what artifact-evaluation "Available"
badges require.

The export deliberately omits material that is not needed to rerun the formal
and executable campaign; see `PUBLIC_EXPORT_EXCLUSIONS.md` for the categories
and `PUBLIC_EXPORT_MANIFEST.txt` / `PUBLIC_EXPORT_CHECKSUMS.sha256` for the
exact contents.

Reviewers should start from `ARTIFACT_EVALUATION.md` if present, otherwise from
`README.md`, and can reproduce the whole campaign with:

```sh
make public-artifact-acceptance
```
