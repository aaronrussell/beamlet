# Protocols

**Status:** An option, not a plan (2026-09-30). Roadmap, Backlog, Agent runtime.

Full support for agent-defined protocols and for agent implementations of library ones (`defprotocol`, `defimpl`, `@derive`), all refused by the scanner today. An agent's own protocol is the easy half: compiled at runtime it is never consolidated, so it dispatches dynamically and its implementations would work as loaded. Implementing a library protocol is the hard half, because Mix consolidates protocols at build into a fixed list of implementations and one loaded later is never dispatched to. Two routes, the choice open:

- **No consolidation.** `consolidate_protocols: false` in the server, and asked of embedders. Simple, and runtime implementations just work. Every protocol dispatch in the VM gets slower (`Enum` over non-lists, JSON encoding, Phoenix rendering), Elixir advises against it, and Beamlet cannot impose it on an embedder.
- **Re-consolidation at runtime.** `Protocol.consolidate/2` builds a protocol's binary for a given implementation list; proven in a spike (2026-09-30) by deriving `Jason.Encoder` at runtime, re-consolidating and hot-loading it. Costs: releases must keep the debug info chunk consolidation reads, which `strip_beams` removes today, and embedders must too; the code server tracks agent implementations per protocol and re-consolidates on every define, replace, remove, rollback and boot that changes the set; it rewrites library modules VM-wide, the host's `Enumerable` when embedded, the first time agent actions would; and the scanner needs rules for a nested `defimpl` against a granted protocol with a literal `for:`. M to L, mostly the code server.

Demand today is `@derive Jason.Encoder` for JSON APIs, which building a map covers, as Phoenix's generated JSON views already do.
