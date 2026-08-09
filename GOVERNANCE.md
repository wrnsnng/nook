# Governance

Nook is a maintainer-led open-source project. The goal is a calm, private,
native meeting notebook; governance exists to protect that product contract and
make contribution decisions understandable.

## Decision making

- Small, reversible changes are decided through ordinary pull-request review.
- Significant product, privacy, architecture, dependency, storage-format,
  update-chain, licensing, or brand-policy changes should begin with a GitHub
  issue describing alternatives and tradeoffs.
- Maintainers seek useful consensus but retain responsibility for the final
  decision, release safety, and project scope.
- Security reports and embargoed fixes are handled privately under
  [SECURITY.md](SECURITY.md).

## Roles

- **Contributors** report issues, propose changes, review, test, and improve
  documentation.
- **Maintainers** triage work, review and merge changes, manage releases, enforce
  community standards, and protect credentials and signing continuity.

Maintainer membership is based on sustained, trusted contributions and sound
judgment in privacy-sensitive areas. Existing maintainers invite new maintainers
and record the change in [MAINTAINERS.md](MAINTAINERS.md).

## Releases

Only maintainers with access to the required local signing material can publish
official binaries. Pull requests and normal CI never receive release
credentials. Release decisions must follow [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Changes to governance

Governance changes use the same public pull-request process as code changes and
require approval from an active maintainer. Changes to the project license or
[trademark policy](TRADEMARKS.md) also require explicit maintainer approval.
