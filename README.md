# Chauffeur — install channel

Public distribution channel for Chauffeur, the cross-platform computer-use automation daemon (MCP over stdio and a local socket).

```bash
curl -fsSL https://raw.githubusercontent.com/axetechnologies/chauffeur-dist/main/install.sh | bash
```

- `install.sh` installs the latest release from this repo's Releases into `~/.local/bin` (macOS universal, Linux x86_64 / arm64).
- Pin a version: `CHAUFFEUR_RS_VERSION=0.26.2 bash -c "$(curl -fsSL https://raw.githubusercontent.com/axetechnologies/chauffeur-dist/main/install.sh)"`
- Uninstall: `curl -fsSL https://raw.githubusercontent.com/axetechnologies/chauffeur-dist/main/uninstall.sh | bash`

This repository is published automatically from each release; please don't edit it by hand. Chauffeur is a fork of the MIT-licensed Cua Driver (Cua AI, Inc.).
