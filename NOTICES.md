# Third-party notices

privacycommand is released under the MIT License (see `LICENSE`). It also
draws on the following third-party work.

## Curated tools catalog

The "Further analysis tools" catalog (`Sources/privacycommandCore/KnowledgeBase/ToolCatalog.swift`)
is distilled and curated from:

- **ashishb/osx-and-ios-security-awesome** — https://github.com/ashishb/osx-and-ios-security-awesome
  Licensed under **CC0-1.0** (public-domain dedication). Stale entries were
  pruned and blurbs rewritten; no code is vendored.

The external tools listed in that catalog (Ghidra, Hopper, Rizin/Cutter,
class-dump, Malimite, Frida, Objection, mac_apt, Objective-See tools,
Suspicious Package, Wireshark, Proxyman, …) are each distributed under their
own licenses by their respective authors. privacycommand only links to them;
it does not bundle or redistribute them.

## Optional interoperability

privacycommand can *import* output produced by, but does not bundle or
redistribute, these tools:

- **LaurieWired/Malimite** (Apache-2.0) — https://github.com/LaurieWired/Malimite
  privacycommand reads a Malimite project's SQLite database to display its
  decompiled classes.
- **ydkhatri/mac_apt** (MIT) — https://github.com/ydkhatri/mac_apt
  privacycommand reads a mac_apt SQLite export's `TCC` table.
