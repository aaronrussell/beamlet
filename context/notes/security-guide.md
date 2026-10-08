# Security guide redraft

**Status:** Analysis for the redraft of `guides/security.md` (2026-10-08). Roadmap, Next, v0.1.1. Folds into `security.md` once the Docker hardening lands; the ratings below are a first pass for the guide to test.

A reply to the launch post said the guide disclaims sandboxing without advising on it, and that the threat is not only someone else controlling a beamlet but a coding agent with the run of a remote server, even a disposable one. It suggested Anthropic's sandbox-runtime (srt). The guide today says what a policy is not and lists what is in place; the redraft says what can go wrong, how, how likely, and what the owner does about each.

## Wrapping the process

Anything wrapped around the server process wraps the whole beamlet, not the agent, because agent code runs in the BEAM. So an outer layer cannot keep agent code from the beamlet's own data and secrets; it bounds what full access to the beamlet reaches beyond it. Inside, the policy steers; outside, the OS bounds the beamlet. Containing agent code from the beamlet itself takes the isolation boundary in `security.md` § 1, agent code in a node of its own, where any of these tools would earn its place.

- **srt.** On Linux bubblewrap leaves the process an empty network namespace, so nothing reaches the port; it is built for commands that only connect out. Outbound goes through its proxy via `HTTP_PROXY`, which Req, Finch and Mint ignore. Inside Docker it needs user namespaces or its weaker nested mode. A fork adding exposed ports exists privately; carrying one means a Node beta in the runtime image. A fit for a local beamlet on a Mac, where Seatbelt can allow a local port, once `Host.HTTP` speaks a proxy. Untested.
- **landrun** (Landlock). Keeps the port, and children inherit its limits. But the BEAM needs reads across the release and system, writes to `/data` and `/tmp`, and to run its helpers, `git` and `sh`, so inside the container it adds only two things: no writes to the release, which a root-owned release gives for one line, and a limit on which programs run, which `sh` and the BEAM itself (files, sockets, native code) mostly route around. It would stop the common download-and-run binary. Worth it on a bare Linux VM, or around a separate agent node that need not read `beamlet.db`.
- **smokescreen.** An egress proxy whose one addition over `iptables` is rules by domain name. It enforces nothing alone, since a proxy sees only traffic sent to it; `iptables` must force traffic through it either way. Worth carrying only if a domain allowlist becomes a feature, and the cheaper first step for that is one in `Host.HTTP`, where injection goes anyway.
- **`iptables`.** Filters every packet by address, port and protocol, whatever sent it, and checks the address actually connected to, which closes DNS rebinding for private ranges. Shipped by default, roadmap v0.1.1.

## The risks

Ranked by harm, assuming code past the policy running as `beamlet` in the hardened container. Escape to the host needs a kernel bug; on Fly the container is a Firecracker VM of its own.

1. **Your data.** Read, destroy or quietly alter anything in `/data`. Inherent: a token grants it, no escape needed. Mitigation: backups, and keeping in a beamlet only what a token holder may read.
2. **Secrets.** Two kinds. Beamlet's own (`SECRET_KEY_BASE`, the token and session tables) are reachable only by escaping, and give lasting access: a planted token or boot-time code survives deleting the token used to get in, so a suspected compromise means a reset or a clean restore, not a cleanup. Third-party credentials the owner gives agent code are readable by agent code, escape or not. How secrets are stored and used is its own discussion; one idea is Beamlet applying a credential itself, `Host.HTTP` adding the header, so agent code never holds the key.
3. **Abuse from your beamlet.** Phishing or malware pages on your domain, spam through web APIs, attacks on other services, mining: the reports and the suspension land on the owner. Pages must go through the BEAM's port, the only one published, but escaped code need not use a visible route (an in-memory module, a handler ahead of the router, files in `/tmp`), and it is gone on restart unless persisted in `/data`. Mining runs a downloaded binary from `/tmp` or `/data`, or inside the BEAM. Much of this needs no escape, since a beamlet exists to serve pages and make requests; mitigation is noticing (routes, an outbound request log) and resource limits, which the image cannot set: `--memory`, `--cpus`, `--pids-limit`, or the machine size on Fly.
4. **Reaching beyond the beamlet.** The LAN or VPC, the cloud metadata address and the account credentials behind it, the owner's other Fly apps on the private network, other protocols, the host. Closed by `iptables` and the container. Listed so the guide shows what the hardening is for.

The password hash in `beamlet.db` can be cracked offline after an escape; it matters only for a weak, reused password, which the guide already asks against.

## Ways in

| Way in | What it takes | Risk |
|---|---|---|
| No token, code execution through Beamlet | A bug in the auth edge, OAuth or a dependency. Young code. | Low |
| No token, guessing the password | A weak password; the sign-in has no rate limit, and a sign-in can approve a token. | Low with a good password |
| A leaked or stolen token | Tokens sit in plain text in client config files, which get committed with dotfiles, screenshotted, or read by malware. | Medium |
| The owner | It is theirs. | None |
| Prompt injection through ordinary APIs | "Send the database to this URL", "add this route". The policy allows `Host.HTTP` to public hosts, and a generic exfiltration injection works against any agent with HTTP. | Medium, the likeliest |
| Prompt injection crafting an escape | Beamlet-specific knowledge and a determined attack. Grows if Beamlet becomes known. | Low |
| Bugs in what agents build | Agent pages are public and models write vulnerable code: SQL injection reaches the agent database; XSS on an agent page runs on the app's origin, can act as the signed-in owner and approve a token (`security.md` § 6). | Low to medium |
| Phishing the owner's consent | "Connect your beamlet to this tool", and the owner clicks Allow. | Low |
| The hosting account | Shell on the host outranks everything. | Low |

The likely ways in, a leaked token and injection through ordinary APIs, need no escape. A beamlet hands an agent all three legs of the lethal trifecta: private data, untrusted content, and a way to send it out. The escape-focused tools address the less likely path; the guide should lead with the likely ones.

## For the redraft

- Lead with the risks and the ways in, then what Beamlet does, then what the owner does. Keep "a guardrail, not a sandbox", but say what that means in consequences rather than as a disclaimer.
- What the owner does: a strong password; HTTPS in front; only `/beamlet` and `/.well-known` open to the internet; a token per client, deleted when unused, and client config files treated as secrets; resource limits on the container; backups; third-party keys with narrow scope that can be revoked; treat the beamlet as disposable and reset after a suspected compromise; give it no cloud role or credentials it does not need; be wary of what the agent reads alongside a beamlet token.
- What Beamlet does: today's list, plus the image's network rules and root-owned release once they land.
- Design work this points at, for the backlog when planned: token hygiene (expiry, last used), an outbound request log and an optional allowlist in `Host.HTTP`, credentials applied by Beamlet, and the consent hardening already in the backlog.

## References

- Simon Willison, "The lethal trifecta for AI agents" (2025): https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/
- Anthropic sandbox-runtime: https://github.com/anthropics/sandbox-runtime
- Docker's run reference for `--cap-add`, `--memory`, `--cpus`, `--pids-limit`.
