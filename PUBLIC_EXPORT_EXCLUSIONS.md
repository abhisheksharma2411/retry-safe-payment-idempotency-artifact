# Public Export Exclusions

The sanitized export intentionally excludes files that are not needed to rerun
the formal and executable artifact.

Excluded categories:

- manuscript PDFs and TeX sources;
- final delivery archives and return packages;
- review prompts, audit notes, and private repair instructions;
- raw local logs and temporary build output;
- generated archives;
- credential material and local editor metadata;
- vendored TLA+ tools JARs, which are fetched by checksum instead.

The exported repository can rerun the artifact through:

```sh
make public-artifact-acceptance
```
