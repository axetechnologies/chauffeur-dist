# Notice

Chauffeur is a fork of **Cua Driver** (`cua-driver`), by **Cua AI, Inc.**,
originally published at <https://github.com/trycua/cua> under the MIT License.

The upstream licence is reproduced verbatim in [LICENSE.md](LICENSE.md) and the
copyright line in it — `Copyright (c) 2025 Cua AI, Inc.` — is theirs and stays.

This repository renames the project throughout: identifiers, bundle id, socket
paths, environment variables, package names and documentation all read
*chauffeur* rather than *cua*. That is a change of product name, not of
authorship. The MIT Licence permits the fork on one condition — that the
copyright notice and permission notice travel with the copy — and that
condition is the reason this file exists. Removing it would not make the
project more ours; it would make it not ours to distribute.

Modifications from upstream are © 2026 memjar and are released under the same
MIT terms.

## What changed

- Project, binary, crate, package and bundle identifiers renamed to Chauffeur.
- Bundle identifier `com.trycua.driver` → `com.axe.chauffeur`.
- npm scope `@trycua/cua-driver` → `@memjar/chauffeur`.
- Update channel and telemetry re-pointed away from upstream's endpoints; see
  [docs/chauffeur-identity-design.md](docs/chauffeur-identity-design.md) for
  the identity model that replaces upstream's anonymous install UUID.

No upstream source was rewritten beyond renaming at the time of the initial
fork commit. The code is upstream's work.

Note on history: the initial commit imported a **snapshot** of
`libs/cua-driver` at upstream commit `88933ac`, so this repository's git
history begins with that import and does not carry upstream's 4,680 commits.
`git blame` here will attribute their lines to the import, which is a
limitation of how the fork was made, not a claim about who wrote them.
Upstream's history is the record: <https://github.com/trycua/cua>.
