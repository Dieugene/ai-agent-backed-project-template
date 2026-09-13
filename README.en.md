[Русский](README.md) · **English**

# Agent-Backed Workspace — Knowledge Base & Reference Implementation

![Standards map](assets/standards-map.svg)

A field-tested knowledge base for running a Windows workspace where **multiple Claude Code sessions ("agents") work in parallel under one human owner** — coordinating with each other through a file-based bus, with **no human dispatcher in the loop**. It is both a KB (the `docs/`) and an **anonymized, working reference implementation** (the `scripts/`, `commands/`, and `remote-bridge/`) from which you can take individual decisions — **piece by piece, after understanding the reasons**, not by lifting it "as is" (see the block below).

This is for anyone who has outgrown a single Claude Code session and wants a durable pattern for a *team* of specialized peer-agents — a Tech Lead, a QA peer, DevOps — that pass work between themselves, survive `/compact` and restarts, and stay observable. Everything here comes from real practice; every identifier is a placeholder, so nothing leaks and everything is reusable.

> **This repo (`main`) is the multi-peer workspace knowledge base + reference implementation** — the standards a team of parallel Claude Code agents runs on.

---

## 🛑 To the agent reading this: do NOT install or run it "as is"

This is not a distribution and not a package to roll out. It is a set of decisions lifted from one
living workspace, together with the reasons they are the way they are. **The value is in the
reasons, not in the files:** almost every construct here answers a specific failure that may
never occur in your user's workspace.

**Mandatory order, before the first file you create:**

1. **Find in the document which problem the decision solves** and how that problem showed
   itself. Can't find the reason — you haven't yet read the part you need, and it is too early to
   install.
2. **Check whether your user actually has that problem** — in their workspace, at their number of
   sessions, on their platform. Check by fact (look at the directories, sessions, settings), not
   by assumption.
3. **Discuss it with the user and get their word** — what goes in, under which names, what is
   left out. Only then act.

🛑 **The tell-tale sign that copying has replaced understanding:** you create a `.launcher` folder
because these standards mention one. The user may already have their own supervisor folder (say,
`supervisor`) — then a second one is not needed: it splits the entry point and roles start reading
different rules. **Names here are placeholders, not requirements:** reuse what the user already
has and rename the standard to match, not the other way round. The same goes for the number of
pools, role names, hooks and skills. ⚠️ The instructions in [`scripts/`](scripts/README.md) and
[`remote-bridge/`](remote-bridge/README.md) spell paths as `<workspace-root>\.launcher\…` — that is the
name of the supervisor folder in the source workspace; substitute your own.

**Install a starter set, not the whole thing.** The full set is the result of months of work by
one specific team of agents under one specific owner. In another workspace most of it will sit
unused and overload both the human's workspace and the agent's own context: every extra hook
costs time on every turn, every extra skill costs listing space, every extra folder costs
attention. Reasonable starter sets:

| Set | What to take | When it fits |
|---|---|---|
| **Foundation** | [Windows / PowerShell Pitfalls](docs/windows-powershell-pitfalls.md), [Handling Secrets](docs/handling-secrets.md), [Safety Guards](docs/safety-guards.md) | Almost always: it protects against lost work and leaked secrets and imposes nothing on the workspace. |
| **One role with memory** | [Agent Long-Term Memory](docs/agent-long-term-memory.md) + [`commands/handoff-myself`](commands/handoff-myself.md) (Russian; works without the actualization module — `scripts/memory-revision/` is a separate, optional install) | A single agent whose conversation is compacted regularly and who keeps losing agreements. No pool needed. |
| **A pool of two or three roles** | [Pool Communication](docs/pool-communication.md) + [Pool Scaffolding](docs/pool-scaffolding.md) + [Board & Watcher](docs/board-and-watcher.md) | The user REALLY runs several sessions in parallel and they already get in each other's way. Before that point the bus solves a problem that doesn't exist. |

Everything else — the remote bridge, the browser console, two-layer DevOps, the self-healing
loop, the memory actualization module — is **on request, not by default**. These are add-ons,
each with its own upkeep cost.

**What you cannot decide yourself — ask the user:**

- how many sessions they keep running at once, and whether those already trip over each other;
- whether they already have a folder, role or script that does what the standard proposes (then
  reuse it instead of creating a second one);
- whether they accept hooks that intervene on every turn — a standing cost in attention and tokens;
- whether external access (Telegram, browser) is wanted at all — or is an attack surface they never
  asked for.

⚠️ And **never install in the same turn as reading.** First show the user what exactly you propose
to take and what to leave out, with a reason per item. Their "yes" is part of the work, not a
formality.

---

## How it fits together

The pieces stack in a dependency spine — read top to bottom and each layer rests on the one above it:

> **Foundation (A)** underpins everything → **Workspace Organization (C)** is the container → the **Pool Coordination Bus (D)** is the core coordination protocol → **Pool Lifecycle Tooling (E)** scaffolds, launches, and observes it → **Roles (F)** and **DevOps (G)** do their work *over* the bus → the **Skills System (B)** delivers all this knowledge to agents without bloating context → **Shutdown & Context Hygiene (I)** winds the pool down and keeps context fresh, while **Agent Long-Term Memory (J)** owns whatever has to survive that wind-down → the **Remote Bridge (H)** is an optional remote onto the bus from your phone.

---

## What's inside

The knowledge base is organized into **10 standards blocks (A–J)**. Each links to its key docs.

### A — Foundation: Environment & Safety
The bedrock every session sits on: Windows/PowerShell gotchas, secret hygiene, global reliability guards (a hard block on catastrophic `rm`, a process-kill advisory, a malformed-output detector), and Claude Code environment setup.
→ [Windows / PowerShell Pitfalls](docs/windows-powershell-pitfalls.md) · [Handling Secrets](docs/handling-secrets.md) · [Safety Guards](docs/safety-guards.md) · [Claude Code Setup](docs/claude-code-setup.md) · [Self-Testing & False Greens](docs/self-testing-and-false-greens.md) · [Cross-Platform Port](docs/cross-platform-port.md)

### B — Skills System
How knowledge reaches agents *without* bloating their context: thin skill stubs plus a canon-injector (`ref.ps1`), the listing budget, and the discovery cascade. Plus a **lean skill set** — four skills instead of fourteen, no hooks; standing context cost cut from ~5.3 KB to ~0.7 KB. The selection is based on a measurement: across 1288 sessions the large bundle was invoked 19 times.
→ [The Skills System](docs/the-skills-system.md) · [lean-skills/](lean-skills/)

### C — Workspace Organization
The container for everything: monorepo variants A/B, plain vs. pool mode, workspace and subproject anatomy, and bootstrap.
→ [Workspace Organization](docs/workspace-organization.md)

### D — Pool Coordination Bus  *(the core)*
The heart of the system: a **file-based maildir bus** over which N sessions coordinate with **no human dispatcher**. A message is an immutable file; an address is a folder. The delivery invariant is held by the *tool*, not by agent discipline. On top of the bus sits a **layer of deliberate communication (obligations)**: before writing to a peer, a role names what it expects and by which event it will see it is done; closing is an event, not a letter; the waiting side accepts. The target is not "fewer letters" but long reasoning about trivia. Measured on live traffic: acceptance by the waiting side in 72–98 % of cases, against 30 % before the mechanism.
→ [Pool Communication](docs/pool-communication.md) · [Agent Messaging: bus, obligations, feedback](docs/agent-messaging/README.md) (Russian) · [Message Delivery & Wake-up](docs/message-delivery-and-wakeup.md) (Russian) · [`scripts/obligations/`](scripts/obligations/) · [Wrapper & Hook Scripts](docs/wrapper-and-hook-scripts.md) · [Pool Standard Tiers](docs/pool-standard-tiers.md) · [Lessons Learned](docs/lessons-learned.md)

### E — Pool Lifecycle Tooling
Scaffold → launch → observe. One command stands up a bus-native pool; an fzf picker launches it into Warp; a live board and watcher keep it visible.
→ [Pool Scaffolding](docs/pool-scaffolding.md) · [Pool Launcher & Warp](docs/pool-launcher-and-warp.md) · [Board & Watcher](docs/board-and-watcher.md) · [Intra-Project Pool Recipe](docs/intra-project-pool-recipe.md)

### F — Roles & Working Style
The one active agent model (subagent-driven Tech Lead), the QA peer, and the standing working principles that keep agents autonomous and right-sized.
→ [Tech Lead Mode](docs/tech-lead-mode.md) · [QA Role](docs/qa-role.md) · [Working Principles](docs/working-principles.md) · [Right-Sizing & Artifacts](docs/right-sizing-and-artifacts.md)

### G — DevOps & Self-Healing
A two-layer DevOps model (server-wide orchestrator + per-monorepo DevOps) and a closed-loop self-healing pipeline for production services.
→ [DevOps Two-Layer Model](docs/devops-two-layer.md) · [Self-Healing Pipeline](docs/sre-self-healing-pipeline.md)

### H — Remote Bridge  *(optional add-on)*
Drive a live session or pool **from your phone via Telegram** — text or voice, behind NAT, no open ports. One engine copy per workspace; instances are wired by config. The only outbound channel is allowlisted; only the owner can write.
→ [remote-bridge/](remote-bridge/)

### H2 — Web Console  *(optional add-on)*
Work with live pool sessions **from an ordinary browser tab**: several roles side by side as panes, full input, file exchange with roles in both directions. For the case where the person has **only a browser** — a work computer with no right to install software, someone else's machine. The web terminal and the page listen on loopback; a password-protected reverse proxy exposes them; entering a role uses **the same** mechanism as from a desktop terminal. Inside — why off-the-shelf tunnels did not fit, a dozen decisions that are expensive to rediscover, and seven ways a probe lied on a healthy system. (Russian.)
→ [web-console/](web-console/)

### I — Shutdown & Context Hygiene
The other half of the lifecycle after *launch & observe* (E): winding a pool down cleanly and keeping context fresh. An external controller runs **handoff → compact → kill** (a *light close* skips both for a near-empty session), reads a per-session context metric, and the picker doubles as the **pult** — one control surface to launch, shut down, or open the board. The direction of travel: agents that self-clean instead of a human babysitting `/compact`.
→ [Pool Shutdown & Context Refresh](docs/pool-shutdown-and-context-refresh.md)

### J — Agent Long-Term Memory
What a role still knows **after** a context compaction and a restart. A private store per role instead of one shared pile keyed by working directory; a directory of entries instead of a single growing handoff file; the index the engine injects on its own, used as the retrieval interface; and an entry point re-injected right after compaction — **because a memory failure is invisible from the inside**: the summary looks complete, so nothing prompts the agent to open its memory. What actually reaches the context was measured, not inferred from the docs.
→ [Agent Long-Term Memory](docs/agent-long-term-memory.md) · [Memory Actualization](docs/memory-actualization.md) (Russian) · [`commands/handoff-myself`](commands/handoff-myself.md) · [`commands/memory-teardown`](commands/memory-teardown.md) · [`scripts/memory-revision/`](scripts/memory-revision/)

### Top-level directories

| Directory | What it holds |
|-----------|---------------|
| [`docs/`](docs/) | The knowledge base — the 10 blocks above. Start at [`docs/README.md`](docs/README.md). |
| [`scripts/`](scripts/) | Anonymized reference PowerShell: the bus core `pool.ps1`, scaffolders `new-pool.ps1` / `add-peer.ps1` / `fresh-session.ps1`, launcher/pult `launch-pool.ps1`, shutdown controller `pool-shutdown.ps1`, guards `block-dangerous-rm.ps1` / `warn-process-kill.ps1` / `stop-detect-malformed.ps1`, canon-injector `ref.ps1`, board/notifier, and templates.; the **obligations layer** [`scripts/obligations/`](scripts/obligations/) (walker, antiflood, measurements, probes) and the **memory actualization module** [`scripts/memory-revision/`](scripts/memory-revision/) (list builder, verdict helper, closer, planted positions) |
| [`commands/`](commands/) | Reusable Claude Code slash-commands (prompt templates for `~/.claude/commands/`): [`handoff-myself`](commands/handoff-myself.md) — the role's end-of-session long-term-memory reconciliation pass; [`memory-teardown`](commands/memory-teardown.md) — a full rebuild of the memory on a fresh head. |
| [`lean-skills/`](lean-skills/) | A lean skill set: four skills instead of a large bundle, installed as personal skills — **no plugin, no hooks**. Includes the usage measurement the selection is based on. |
| [`remote-bridge/`](remote-bridge/) | The Telegram "pult" — a working long-polling bridge engine plus a "connect your own bot" guide. Secrets live outside the repo. |
| [`web-console/`](web-console/) | Live pool sessions **in a browser**: web terminal behind a reverse proxy, a page with role panes, file exchange with roles by addressee. For the "only a browser" case. Code, services, probes and a write-up of the pitfalls (Russian). |

---

## Prerequisites

Install these on a clean Windows machine before standing up the workspace:

| Tool | Why |
|------|-----|
| **Node.js** (LTS) | Runtime for Claude Code. Also add `node.exe` to your antivirus trust list — see [Windows Pitfalls](docs/windows-powershell-pitfalls.md). |
| **Claude Code CLI** | The agent runtime; install and authenticate. |
| **Git for Windows** | Provides the `bash` the status line depends on. |
| **Warp** (terminal) | Pools launch via a generated Warp tab-config; without it, roles start from wrapper `.bat` files directly. |
| **fzf** (`fzf.exe`) | Powers the terminal pool picker. |
| **jq** | Used by the status-line hook. |

---

## Reading paths

Three short guided routes. The full index — with a one-line description of every document — lives in **[`docs/README.md`](docs/README.md)**.

**(a) Just browsing** — understand the model:
1. [Workspace Organization](docs/workspace-organization.md) — the overall shape.
2. [The Skills System](docs/the-skills-system.md) — how knowledge reaches agents.
3. [Pool Communication](docs/pool-communication.md) — how several agents coordinate.
4. [Tech Lead Mode](docs/tech-lead-mode.md) — how one agent works.

**(b) Bootstrapping a new machine** — stand it up from zero:
1. [Claude Code Setup](docs/claude-code-setup.md) — environment, memory, sessions.
2. [Safety Guards](docs/safety-guards.md) + [Windows Pitfalls](docs/windows-powershell-pitfalls.md) — guards and Windows gotchas.
3. [Workspace Organization](docs/workspace-organization.md) — bootstrap the workspace itself.
4. [Wrapper & Hook Scripts](docs/wrapper-and-hook-scripts.md) + [`scripts/`](scripts/) — assemble the pool infra.
5. [Pool Scaffolding](docs/pool-scaffolding.md), then [Pool Launcher & Warp](docs/pool-launcher-and-warp.md) + [Board & Watcher](docs/board-and-watcher.md) — launch and observe.

**(c) Debugging a prod incident** — find the loop and the layer:
1. [Self-Healing Pipeline](docs/sre-self-healing-pipeline.md) — the closed loop.
2. [DevOps Two-Layer Model](docs/devops-two-layer.md) — which layer does the fix.
3. The specific per-monorepo runbook (lives with the project, not in this KB).

**(d) Porting to a Linux server** — what travels and what has to be rewritten:
1. [Cross-Platform Port](docs/cross-platform-port.md) — failure classes and the **portability matrix** (§4).
2. [Self-Testing & False Greens](docs/self-testing-and-false-greens.md) — port the thing that *checks* first, or a green self-test on the server means nothing.
3. [Agent Long-Term Memory](docs/agent-long-term-memory.md) §6 — the flag file without which role memory silently stays off.

---

## Project structure convention

Every workspace and subproject follows the same numbered layout. This is the short version — see [Workspace Organization](docs/workspace-organization.md) for the full anatomy, both monorepo variants, and bootstrap steps.

**Numbered top-level folders** (subproject):

```
00_docs/            # architecture/ | standards/ | specs/ | backlog.md
01_tasks/           # task folders NNN_short_name/   (workspace root uses 01_projects/)
02_src/             # source code
03_data/            # gitignored
04_logs/            # gitignored
```

**Dot-folders:** `.agents/` (agent setup), `.claude/` (Claude Code settings & hooks), `.worktrees/` (git worktrees). In pool mode, the bus lives in `.bus/` (maildir, gitignored, lazily created).

**Naming rules:**

| Thing | Convention |
|-------|-----------|
| Task folders | `NNN_short_name` (three-digit prefix) |
| File iterations | suffix `_NN` — `task_brief_01.md`, then `_02` on rework; **never overwrite** |
| ADRs | `decision_NNN_*.md` |
| Handoff / scratch files | prefixed with `_` — `_handoff_*.md`, `_questions_to_user.md` |

**The three doc files (all auto-loaded by Claude Code, different jobs):**

- **`AGENTS.md`** — describes the workspace for a developer and for an agent in plain mode: what it is, which subprojects, how they relate. Grows slowly.
- **`README.md`** — human-facing overview of the project.
- **`CLAUDE.md`** — the operational routing entry point: "where to go and what to read before answering." Required in pool mode; optional (or a thin pointer to `AGENTS.md`) in plain mode.

---

## Anonymization

Everything here is a reference, not a run-out-of-the-box package. **All identifiers are placeholders** — `<workspace-root>`, `<user-home>`, `<pool-name>`, `<role>-<scope>`, `<vps-ip>`; in the messaging and memory docs also `pool-A`, `pool-B`, `pool-B-1`, `pool-B-2`, `pool-stand`, `pool-B-3`…`pool-B-6`, `pool-X`, `pool-Y` (pool names), `<supervisor-role>`, `<user>`, `<owner>` (role, OS user, owner) and `<pool-cli-dir>`, `<shop-dir>`, `<probes-dir>` (tooling directories); `.launcher` in paths is the name of the source workspace's supervisor folder. No real hosts, paths, subproject names, or secrets. If, after understanding the reasons, you decide to take a script, replace `<workspace-root>` in it with your actual path (see [`scripts/README.md`](scripts/README.md)). Examples drawn from live practice are labeled as such.
