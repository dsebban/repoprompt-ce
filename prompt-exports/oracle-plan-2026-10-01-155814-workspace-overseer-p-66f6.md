## Final Prompt
<taskname="Workspace Overseer Plan"/>

<task>
Produce a full, code-grounded implementation plan for a minimal workspace Overseer feature in RepoPrompt CE, suitable to share as a draft upstream issue. Investigate and reuse existing oversight capabilities before proposing new ones. Do not implement code, edit repository files, create a GitHub issue, or publish anything. The deliverable is the reviewable plan itself, with concrete repository-relative source references and a clear distinction between verified behavior, proposed design, and open decisions.
</task>

<architecture>
RepoPrompt already has cross-session oversight, but its responsibilities are deliberately separated:

- `DomainAgentSessionLinkAuthority` and its models/authorizer own directional grants, endpoint incarnation, generation, capability checks, revocation fences, and transcript cursors. The architecture note documents why observation, sending, management, inverse attention, and auto-wake are distinct. Any workspace observer must preserve those exact boundaries.
- `AgentSessionOversightIntentStore` durably stores observer→target intent pairs; `AgentSessionOversightLaunchCoordinator` restores only after workspace/session topology is ready. Runtime authority is rebuilt, not persisted as a capability. `AppLaunchConfiguration` suppresses production oversight file I/O for deterministic test launches and distinguishes dormant saved intent from suppressed persistence.
- `AgentSessionLinkMCPToolService` already exposes `list`, `poll`, `wait`, `read`, `send`, cancellation, management, `create_lane`, and `retire_lane`; ownership annotations and authority checks already exist. Verify implementation, exact visibility, and current tool registration before proposing any tool additions. `retire_lane` must be scoped to lanes the caller owns and preserve their session history.
- The existing `agent_session_link.send` path persists an attributed target row before starting a provider run. A failed start is a distinct partial outcome; a durable row does not prove that a run began. Preserve explicit delivery/run-start state, idempotency, and truthful status rather than retrying blindly.
- `AgentSessionLinkTranscriptSanitizer` maps tool calls/results structurally to normalized tool name and status, with no result text. Explicit error rows follow a separate redaction/capping policy. A safe diagnostic design must distinguish bounded provider/tool failure detail from raw results, arguments, prompts, secrets, and interaction payloads.
- `AgentChatItem` and persisted rows support image attachments, but cross-session send requests/service currently carry text. Trace the provider attachment pipeline before describing how observer-to-target images become actual model input, and protect local paths and image bytes in logging/projections.
- `AgentMonitorPill` is the current eye-pill dashboard and contains existing per-thread management/exclusion surfaces. Keep those surfaces in place; a new settings page must not duplicate them.
- `SettingsView` owns tab routing/search; `GlobalSettingsDocument` and `GlobalSettingsManager` own durable settings; `AgentModelsSettingsView` and `AgentModelCatalog` show established catalog reuse. Reuse current catalog availability and effort validation; do not guess model defaults or freeze time-sensitive names.
- Session inventory/lifecycle evidence lives across `AgentSession`, `AgentSessionDataService`, `AgentSessionMetadataIndex`, and `AgentWorkspaceSessionIndexStore`; active endpoint binding is resolved separately. Trace the live authoritative state used to identify active/new sessions and workspace membership. Avoid treating quiet/idle as task completion or scanning full history just to discover current activity.
- Conductor serializes named operations/lanes and uses a machine-wide live-app lock, but the existing lanes protect individual jobs, not an investigator's full QA loop. Debug artifact provenance records worktree/branch/commit/dirty boolean, while the app manifest hashes packaged executables and related artifact metadata. The plan must address an exclusive whole-QA-slot coordination seam and stronger artifact/worktree/commit/dirty-patch provenance; do not claim current launch-job serialization reserves a QA slot.
</architecture>

<selected_context>
- `AGENTS.md`: source ownership, coordinated conductor contract, validation rules, and required real-app verification tool plus feature map.
- `.agents/skills/rpce-maintainer-guidance/SKILL.md` and `references/guidance-sources.md`: evidence-led planning, state-safety, one-authority, latency, observability, and current-catalog/default guidance.
- `docs/architecture/agent-session-oversight-auto-wake.md`: current oversight owners, directional grants, management and attention distinctions, and existing periodic idle wake (which is not workspace monitoring).
- `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionOversightIntentStore.swift` and `AgentSessionOversightLaunchCoordinator.swift`: persistence/restoration lifecycle and ownership boundaries.
- `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift`, `DomainAgentSessionLinkModels.swift`, `DomainAgentSessionOperationAuthorizer.swift`, and `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift`: current permissions/tool surface; service slices show existing operation list, owned-lane APIs, text send, and delivery receipt.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentModeViewModel+SessionLinkSend.swift`, `AgentSessionLinkSendTransaction.swift`, and `AgentSessionLinkEndpointResolver.swift`: exact cross-session delivery transaction, endpoint identity, durable-row/provider-start ordering, and failure semantics.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkTranscriptSanitizer.swift`: redaction, paging, and structural sanitization behavior.
- `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift`: persisted cross-session attribution and image attachment-capable chat rows.
- `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentMonitorPill.swift`: current eye-pill/dashboard behavior to preserve.
- `Sources/RepoPrompt/Features/Settings/Views/SettingsView.swift`, `Models/GlobalSettingsDocument.swift`, plus codemaps for `GlobalSettingsManager`, `AgentModelsSettingsView`, and `AgentModelCatalog`: settings insertion points, serialization owner, and current provider/model catalog pattern.
- Codemaps for `AgentSession`, `AgentSessionDataService`, `AgentSessionMetadataIndex`, and `AgentWorkspaceSessionIndexStore`: session inventory and lifecycle entry points.
- `Sources/RepoPrompt/App/AppLaunchConfiguration.swift`: test-launch/persistence policy.
- `Scripts/conductor.py` slices, `Scripts/package_app.sh`, and `Scripts/write_app_artifact_manifest.py`: named per-operation lanes, current provenance, and artifact verification capabilities.
</selected_context>

<relationships>
- Workspace settings → app lifecycle/composition → active session inventory → app-owned Overseer session/coordinator → exact existing observer-to-target link intents → current authority revalidates every observation/action.
- Do not make automatic observation imply `.manage`, user publication, approvals, link-grant expansion, or arbitrary workspace access. State explicitly what the user authorizes by enabling workspace oversight and what still needs a separate directional grant.
- “Oversee this workspace” and “Autostart” belong in one dedicated settings tab beside Agent Models, with independent Overseer provider/model/effort selection. Keep controls minimal and use live catalog entries.
- The existing eye-pill remains owner of exclude-thread and per-thread Manage UI. Define whether workspace-wide opt-out revokes only links created by that Overseer, leaving user-created links untouched.
- Session inactivity may quiet/retire monitoring work and later reactivate it; it never declares the user's task complete and never deletes transcript history. Distinguish temporary monitoring lifecycle from `retire_lane` and from stop/cancel.
- A coordinated workstream registry should prevent overlapping review threads; durable brief/MEMORY ownership, priorities, lanes, open threads, decisions, restart inventory validation, status-driven updates, and compacting under context pressure are useful only to the extent current tools actually expose them.
- Whole-QA-slot coordination must reserve the complete live QA sequence (including Oracle image/lane QA) against competing sessions that would replace the singleton debug app. Bind the slot to exact app artifact, checkout/worktree, commit, and dirty-patch identity; release/cancel/expiry must be observable. Reuse conductor coordination mechanisms as a seam, while recognizing its current per-operation queue is insufficient.
</relationships>

<ambiguities>
Resolve what code can establish, and label remaining choices rather than silently picking policy:

- Whether Overseer provider/model/effort and enable/autostart flags are global or workspace-scoped, and how settings survive schema migration, disabled auto-restore, restart, and unknown/future settings fields.
- The canonical workspace identity (workspace UUID/root/path/worktree) and how multiple windows, worktrees, workspaces, duplicate session incarnations, child lanes, and multiple Overseer sessions are handled without duplicate ownership.
- Which live runtime state is authoritative for active/new sessions and monitor quiet/reactivation. Idle/quiet is never evidence of completion.
- Whether enabling Overseer explicitly authorizes creation of observer links, while management and each other capability remain independently authorized; how the user can review/revoke this exact authority and how revocation races with observation/delivery.
- Creation/autostart failure, cancellation, restart inventory reconciliation, stale endpoint cleanup, delivery run-start failure, retry/idempotency, rate limits/backpressure, and safe session ownership/retirement.
- Safe, useful bounded tool-error detail; image attachment storage/provider compatibility and privacy; oversized/unsupported attachment behavior.
- Multiworkspace ownership, application exit, permissions, and preference behavior. Cursor Projects' responsive coordinator, durable shared context, and visible subscriptions are inspiration only; cloud fleet, Slack, and general-purpose scheduling are deferred.
- User-provided context says public issue #1078 is about persistent lane status and routine wake compaction, not new authority/tool behavior. Treat that as a stated dependency/overlap lead, not independently verified repository fact; identify what code/issue review must confirm.
- User-provided kickstart notes claim `create_lane`, `retire_lane`, `stop`, `agent_self`, and compaction support. Current code exposes those names, but verify actual current tools, ownership, and scope instead of trusting the guide or duplicating them.
- `AGENTS.md` requires a project verification tool and feature map. Locate the current canonical tool/map (if present) and plan the necessary updates; do not invent that one already exists.
</ambiguities>

<requirements>
Preserve all user requirements from the task context: a dedicated Overseer settings tab beside Agent Models; independent provider/model/effort; “Oversee this workspace” and “Autostart”; few sensible controls; automatically observe existing and newly active sessions in an approved workspace; periodically quiet/retire inactive monitoring and reactivate when activity resumes; never infer completion from idle; never delete session history; keep per-thread exclusion and Manage controls in the eye-pill; user-authorized link/unlink management; sanitized tool-error visibility despite structural omission in the current sanitizer; image-capable observer-to-target messages; exact directional grant/revocation/privacy limits; no implicit management/publication/approval/access; avoid overlapping review threads; report messages whose durable delivery row exists but run start failed; exclusive whole-QA-slot coordination with exact provenance; and ensure competing Oracle QA cannot replace the singleton QA app.

Inspect existing capabilities first. Verify actual tool exposure, current authorities, launch wiring, persistence format/migrations, catalog defaults, session lifecycle/inventory, and test/verification seams. Do not propose guessed model defaults. Do not add private usage details to a public-facing issue draft; describe them in generic observable terms. The existing draft remains unpublished.
</requirements>

<plan_output>
Write a concise but complete issue-ready plan with:
1. Suggested issue title and a short problem/goal statement.
2. Verified current behavior with repository-relative file/symbol references; mark user-reported facts and #1078 overlap separately from code-confirmed facts.
3. A staged scope: smallest complete first milestone versus explicit later follow-ups/non-goals. Consolidate related workstreams without turning this into cloud fleet/Slack/general scheduler work.
4. Domain ownership and explicit data/state transitions: settings, workspace Overseer lifecycle, session inventory, link ownership/revocation, monitoring quiet/reactivation, delivery/error/image path, durable shared brief/MEMORY and workstream subscriptions, and whole-QA-slot coordination/provenance. Name invariants and avoid parallel authorities.
5. Restart, cancellation, revocation, multiworkspace/multiple-overseer, races, run-start partial failure, idempotency, backpressure, permission changes, and ownership-safe retirement behavior.
6. Observable acceptance criteria and focused validation/live-app evidence, including settings migration preservation, deterministic launch isolation, exact directional permission/revocation tests, idle-not-completion behavior, no duplicate observer/session creation, sanitized error cases, image reaching target model, run-start failure truthfulness, and QA-slot artifact binding/serialization. Follow project conductor instructions; planning only means do not execute checks here.
7. Risks, dependencies, and concrete open product/policy decisions. Include current #1078 as a lead to cross-reference/update after verification, not as verified duplicate or a grant of new authority.

Keep the plan actionable and grounded without prescribing unsupported implementation detail. No code changes, documentation edits, issue filing, publication, or external messages.
</plan_output>

## Selection
- Files: 18 total (10 full, 8 slice)
- Total tokens: 72486 (Auto view)
- Token breakdown: full 61966, slice 10520
- Token accounting: incomplete from active_tab_published; refresh pending; incomplete: files, codemap_presentation

### Files
### Selected Files
├── .agents/
│   └── skills/
│       └── rpce-maintainer-guidance/
│           ├── references/
│           │   └── guidance-sources.md — 0 tokens (full)
│           └── SKILL.md — 1,971 tokens (full)
├── Scripts/
│   ├── conductor.py — 0 tokens (lines 1-70 (Conductor named build/debugArtifact/liveApp/release/style lane constants and coordination entry points; existing serialization is per operation.), 3528-3600 (Operation-to-lane mapping for build, run, app launch/relaunch, smoke, and agent diagnostics; does not reserve a complete multi-step QA session.), 7547-7618 (Debug app provenance reporting: repo/worktree, branch, commit, dirty-at-build, time and stale/foreign warnings.))
│   ├── package_app.sh — 0 tokens (lines 420-452 (App bundle provenance writer captures checkout, branch, commit, dirty boolean and build timestamp; evidence that exact dirty-patch identity is not currently captured here.))
│   └── write_app_artifact_manifest.py — 0 tokens (lines 125-210 (Artifact manifest computes app/helper executable hashes, architectures, signing/entitlement metadata, and verifies a packaged bundle against a supplied manifest.))
├── Sources/
│   └── RepoPrompt/
│       ├── App/
│       │   └── AppLaunchConfiguration.swift — 0 tokens (full)
│       ├── Features/
│       │   ├── AgentMode/
│       │   │   ├── Models/
│       │   │   │   └── AgentChatModels.swift — 0 tokens (lines 1-15 (Agent chat item type declarations and imports relevant to attributed cross-session messages.), 117-144 (AgentCrossSessionAttribution persisted metadata fields; current cross-session direction and source identity.), 183-355 (AgentChatItem user row shape, image attachments and attribution fields plus factory construction; potential image-capable oversight delivery boundary.), 553-617 (Persisted chat-item shape and conversion from AgentChatItem; proves transcript rows can store attachment and attribution data.))
│       │   │   ├── Runtime/
│       │   │   │   └── SessionLinks/
│       │   │   │       ├── AgentModeViewModel+SessionLinkSend.swift — 5,549 tokens (full)
│       │   │   │       ├── AgentSessionLinkSendTransaction.swift — 9,251 tokens (full)
│       │   │   │       ├── AgentSessionLinkTranscriptSanitizer.swift — 11,575 tokens (full)
│       │   │   │       ├── AgentSessionOversightIntentStore.swift — 9,214 tokens (full)
│       │   │   │       └── AgentSessionOversightLaunchCoordinator.swift — 11,835 tokens (full)
│       │   │   └── Views/
│       │   │       └── Components/
│       │   │           └── AgentMonitorPill.swift — 6,019 tokens (lines 1-220 (Eye-pill entry and popover layout; establishes that the existing dashboard is a two-direction session link surface, not workspace Overseer settings.), 330-490 (Outbound session rows expose per-thread navigation and unlink plus existing per-lane controls; preserve this owner for management and exclusion flows.), 750-850 (Inbound 'Overseen by' list and per-link actions; preserves explicit directional grant/revocation handling in the current eye-pill dashboard.))
│       │   └── Settings/
│       │       ├── Models/
│       │       │   └── GlobalSettingsDocument.swift — 12,571 tokens (full)
│       │       └── Views/
│       │           └── SettingsView.swift — 2,559 tokens (lines 1-10 (Imports and settings view module context.), 380-430 (Settings content switch around Agent Models: insertion point for the dedicated Overseer page.), 515-625 (SettingsTab cases, titles, icons, and sidebar section routing.), 1110-1185 (Settings search tags and tab discoverability conventions.))
│       └── Infrastructure/
│           └── MCP/
│               └── Agent/
│                   └── AgentSessionLinkMCPToolService.swift — 500 tokens (lines 1-180 (Current MCP operation inventory, call identity resolution, exact grant distinction, and prompt-level authority contract; establishes existing capabilities to reuse.), 520-615 (Existing create_lane/retire_lane service behavior and ownership-oriented API surface; verify these tools rather than duplicating them.), 1080-1165 (Existing text-only send request validation and capability-gated target delivery; boundary where image payload support would need a deliberate extension.), 2065-2085 (Stable send receipt reports delivery_state separately from delivered result; relevant to start failure semantics.))
├── docs/
│   └── architecture/
│       └── agent-session-oversight-auto-wake.md — 1,442 tokens (lines 1-132 (Current oversight architecture, four owners, outbound-grant authority and autonomy constraints; background for adding an app-managed observer without widening link grants.), 202-348 (Management capability, redacted prompt inspection and exact send/steer/revocation semantics; informs privacy and failure boundaries.), 382-435 (Purposeful attention is a separate inverse signal, with no reverse send grant; guards against automatic observation creating authority.), 606-632 (Existing periodic idle model wake is a separate default-off setting and does not schedule target observation.))
└── AGENTS.md — 0 tokens (full)


---

## Generated Plan
- Oracle group status: partial_failure
- Oracle group: `0147BB04-1CDF-42CC-BD9B-8AE412E4AEB9`

**Reconciling these Oracle lanes**
2 independent answers to the same request follow. Lane order is not a ranking; the first lane supplies the top-level continuation handle, and a successful follow-up through any lane's chat ID re-runs every lane.
- Read every lane through the end-of-group marker (`End of Oracle group: 2 lanes above.`). If the marker or a lane is missing, page the export or try the read-only `oracle_chat_log` with that lane's chat ID. Logs may be scoped or clipped; report any remaining gap. Do not start a follow-up just to retrieve prior text.
- Reconcile by evidence, not lane order, answer length, or model identity: check material single-lane and conflicting claims against the code, and report unresolved disagreements. A failed or partial lane is incomplete evidence.

Lanes (2):
- Oracle — `gpt-6-astra-pro` — Completed — chat ID `workspace-overseer-plan-CF1AD8`
- Oracle 2 — `claude-opus-5-5-xhigh` — Failed — chat ID `workspace-overseer-plan--3C1FF1`

### Oracle
- Status: Completed
- Provider: `Custom`
- Model: `gpt-6-astra-pro`
- Effective effort: Provider default / not specified
- Chat: `workspace-overseer-plan-CF1AD8`

Draft upstream issue plan:

:::writing{variant="document" id="74831" title="Workspace Overseer — implementation plan"}
## 1. Summary

**Suggested issue title:** Add an opt-in workspace Overseer using exact session links, safe delivery, and exclusive live-QA coordination

Add one app-managed Overseer session per approved workspace, configured in a dedicated **Overseer** settings tab beside **Agent Models**, with independent provider/model/effort selection and **Oversee this workspace** / **Autostart** controls. Reuse existing session creation, link authority, transcript sanitization, delivery transactions, and wake machinery. Automatically created relationships must be observation-only unless the user separately delegates management. Quiet inactive monitoring without declaring tasks complete or deleting history. Include bounded failure diagnostics, image-capable attributed sends, a small durable workstream registry, and a conductor lease that protects an entire live-QA sequence. This is a targeted cross-subsystem extension, not a replacement oversight framework.

## 2. Current-state analysis

### Evidence boundary

**Direct observation** below means visible in the supplied source or documentation; documentation observations are identified separately. **Inference** identifies conclusions drawn from those observations. **Proposed** identifies new behavior.

The supplied packet does **not** contain several implementations named in its context description: domain authority internals, the runtime bridge, canonical tool registration, settings-manager persistence, session indexes, provider attachment transport, or the mentioned codemaps. Their behavior cannot be independently verified from their names. These are explicit implementation gates, not evidence that the desired functionality already exists.

### Verified responsibilities and execution paths

| Evidence | Direct observation and repository reference | Consequence |
|---|---|---|
| **D1 — Oversight ownership** | The architecture document separates link authority, passive reduction, immutable provider claims/receipts, and wake admission. It also distinguishes operation authorization from the instruction under which a model should act. **Documentation observation:** `docs/architecture/agent-session-oversight-auto-wake.md:1-84`. | A workspace coordinator may manage enrollment and lifecycle, but must not become another grant authority, notification queue, or provider-acceptance ledger. |
| **D2 — Management default** | Newly created and restored links are documented as managed by default; explicitly restricted live grants remain restricted. The document expressly says there is no dashboard Manage toggle. **Documentation observation:** `docs/architecture/agent-session-oversight-auto-wake.md:202-253`. | Calling ordinary Add is not evidence of observation-only enrollment. The requested per-thread Manage control is a proposed change, not a verified existing control. |
| **D3 — Existing tool service** | `executeOperation` dispatches existing oversight operations, including `send`, `steer`, `stop`, `create_lane`, and `retire_lane`. Lane creation delegates to `bridge.createLane`; retirement delegates to `bridge.retireLane`. **Code observation:** `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:90-180`, `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:520-615`. | Do not introduce replacement tools. Service dispatch alone does not prove catalog exposure, caller eligibility, ownership-safe retirement, or history preservation. |
| **D4 — Durable intent versus authority** | The intent document is version 1 and stores directed UUID pairs. Its comments explicitly exclude live link IDs, generations, capabilities, and wake state. Persistence distinguishes enabled, dormant, and suppressed modes. **Code observation:** `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionOversightIntentStore.swift:1-90`. | Store user intent and ownership provenance, not reusable authorization. Workspace-owned restore needs different treatment from legacy managed-by-default restore. |
| **D5 — Restore lifecycle** | The launch coordinator is documented as bounded to its launch snapshot, restoration-readiness gated, and at-most-once for automatic reservation. Launch policy separately derives dormant versus suppressed persistence. **Source/documentation observation:** `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionOversightLaunchCoordinator.swift:1-170`, `Sources/RepoPrompt/App/AppLaunchConfiguration.swift:1-74`. | Continuous enrollment of newly active sessions belongs in a separate workspace lifecycle owner, not a conversion of the existing launch coordinator into perpetual desired-state enforcement. |
| **D6 — Send linearization** | The target transaction claims composer submission, commits authorization, revalidates, appends an attributed row, and flushes persistence before dispatch admission. A failed initial flush triggers compensating removal and another required flush. The wire receipt separately exposes `delivery_state`, `target_item_id`, and `duplicate`. **Code observation:** `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentModeViewModel+SessionLinkSend.swift:90-330`, `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:2065-2085`. | Durable delivery must not be presented as proof of provider start. Preserve the existing transaction and its indeterminate-persistence distinction. |
| **D7 — Sanitized observation** | Observer transcript rows carry coarse roles and bounded metadata. Tool calls/results are structurally reduced rather than returned as narrative result text; narrative/error processing has separate redaction and budgeting. **Code observation:** `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkTranscriptSanitizer.swift:1-265`, `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkTranscriptSanitizer.swift:375-570`. | Useful tool-failure detail needs a deliberately safe projection. Removing structural stripping would expose a different class of data. |
| **D8 — Image storage is not image delivery** | Runtime and persisted chat rows contain image attachments. The supplied send-service calls pass message, key, workflow, and queue options, but no image payload. **Code observation:** `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift:183-355`, `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift:553-617`, `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:1080-1165`. | Attachment-capable persistence does not establish that cross-session images reach a provider. |
| **D9 — Settings integration** | `SettingsTab` owns cases, labels, icons, grouping, and search terms; `SettingsView` renders Agent Models through its existing settings surface. `GlobalSettingsDocument` has fixed feature-version boundaries and current schema 10. **Code observation:** `Sources/RepoPrompt/Features/Settings/Views/SettingsView.swift:380-430`, `Sources/RepoPrompt/Features/Settings/Views/SettingsView.swift:515-625`, `Sources/RepoPrompt/Features/Settings/Views/SettingsView.swift:1110-1185`, `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift:1-157`. | Add a workspace-scoped settings record and tab, without changing ordinary Agent Models defaults. Verify the manager’s raw-preserving writer before extending serialization. |
| **D10 — Existing eye-pill** | Outbound rows provide navigation, Unlink, Auto-wake, and snooze controls. Inbound Unlink supplies exact endpoints and a generation-qualified reference. **Code observation:** `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentMonitorPill.swift:330-490`, `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentMonitorPill.swift:750-850`. | Keep relationship controls here. Persistent workspace exclusion is not established by the supplied Unlink implementation. |
| **D11 — QA coordination gap** | Conductor assigns lanes to individual build/run/app/smoke operations. Debug provenance records worktree, commit, and a dirty Boolean; its reader reports stale/foreign warnings. The artifact manifest records executable hashes, architectures, and signing metadata. **Code observation:** `Scripts/conductor.py:3528-3600`, `Scripts/conductor.py:7547-7618`, `Scripts/package_app.sh:420-452`, `Scripts/write_app_artifact_manifest.py:125-210`. | Neither per-operation admission nor a dirty Boolean identifies and protects a complete multi-step QA investigation. |

**Inference I1:** The smallest coherent integration is an app-owned enrollment/lifecycle coordinator layered over the existing authority and wake pipeline, plus narrow extensions at the privacy, persistence, and QA boundaries. This follows from the existing separation of owners, bounded launch restore, and target-side delivery transaction—not from assuming an absent “workspace monitor” service exists. Supporting observations: **D1, D4–D6**.

### Verification gates before implementation

Inspect the following owners before changing their callers:

- **Authority and tool exposure:** `DomainAgentSessionLinkAuthority`, `DomainAgentSessionLinkModels`, `DomainAgentSessionOperationAuthorizer`, `AgentSessionLinkRuntimeBridge`, canonical definitions, provider advertisement, and execution filters. Establish the exact capability combinations for observation, sending, management, compaction, and lane creation. Verify `retire_lane` ownership and history preservation. Verify the separately claimed `agent_self` and self-compaction surfaces.
- **Settings, inventory, and attachment integration:** `GlobalSettingsManager` / `GlobalSettingsStore`, live catalog and effort resolution, `AgentSession`, `AgentSessionDataService`, `AgentSessionMetadataIndex`, `AgentWorkspaceSessionIndexStore`, endpoint resolution, and every provider’s direct-start/queued/replay attachment path. Identify their actual declarations and callers; do not invent signatures from the descriptions.
- **Repository verification integration:** locate the canonical project-verification entry point and feature map, if present. The request identifies these as requirements, but the supplied excerpts do not identify their canonical files. Update existing artifacts rather than creating a competing map.

**User-reported overlap, not independently verified:** issue **#1078** concerns persistent lane status and routine-wake compaction. Review it for reusable state and overlapping acceptance criteria. Do not mark this proposal a duplicate or treat that issue as authorization for new tool behavior.

## 3. Design

### 3.1 Staged scope

**Proposed first milestone:** one visible Overseer per workspace; minimal settings; observation-only automatic enrollment; persistent exclusions and explicit per-thread management; quiet/reactivation; truthful delivery outcomes; bounded failure summaries; image-enabled `send`; a small local brief/workstream ledger; and exclusive artifact-bound live QA.

Land the authority, image, diagnostics, and QA changes as independently testable preparatory work where practical. Ship automatic workspace enrollment only after its consent and restore fences are complete.

**Explicit follow-ups/non-goals:** automatic task decomposition, semantic detection of every overlapping conversation, cross-workspace fleet management, Slack integration, cloud execution, general-purpose scheduling, arbitrary attachment-path imports, and automatic publication. Existing user-directed lane operations remain available only under their verified authority contracts.

### 3.2 Settings and approved scope

**Proposed policy:** configuration is **workspace-scoped**, keyed by workspace UUID. Roots, paths, and worktrees describe execution locations; they do not replace workspace identity. Two workspaces referring to the same repository remain independently configured.

Add optional top-level `workspaceOverseerSettingsByWorkspaceID` to `GlobalSettingsDocument`, containing:

| Field | Stored type and default | Contract |
|---|---|---|
| `enabled` | Optional Boolean; resolves to `false` | User consent for automatic observation within this workspace. |
| `autostart` | Optional Boolean; resolves to `false` | Permits automatic startup after ordinary restoration becomes ready. |
| `modelSelectionRaw` | Optional String; no implicit selection | Reuse the existing canonical provider/model selection representation after verifying its catalog integration. |
| `effortRaw` | Optional String; absent means the selected model’s ordinary default | Validate against that exact provider/model. Model changes clear incompatible effort in the same settings mutation. |

Use the existing settings manager’s scoped mutation and observation mechanisms. Do not introduce another defaults store or write directly from SwiftUI. Blocked persistence must produce persistent feedback, not an apparently successful checkbox.

The new **Overseer** tab has the two requested toggles, provider/model/effort controls, status, and an **Open Overseer** action. Start/resume/retry actions appear only when relevant. Add its case, title, icon, Agent Mode grouping, explicit sidebar ordering, navigation handling, and search tags in `SettingsView.swift`. Reuse current catalog availability and parameter validation; do not copy Agent Models selections or substitute a guessed recommended model. **Basis: D9.**

Enabling must visibly explain—and record acceptance of—the standing instruction:

> Observe status and sanitized transcript content of eligible sessions in this workspace and report relevant developments. Do not invent tasks, manage sessions, approve requests, publish, or access other workspaces without separate authorization.

This is an explicit user-approved instruction, not an instruction inferred from link membership. Explain that observed content may be sent to the chosen provider and that wake turns incur normal provider usage.

**Launch semantics:**

- Enabling interactively requests startup immediately, subject to persistence, model, workspace, and endpoint readiness.
- With Autostart off, restart leaves the feature enabled but paused until explicit Start.
- Dormant restoration does not run an automatic startup pass; explicit Start still works.
- Never open another workspace or manufacture a window to satisfy Autostart.
- Deterministic/test-suppressed launches create neither production state nor provider work. Include `isUnitTestProcess` in the new composition guard rather than assuming the existing UI-test flag covers unit tests. **Basis: D5.**

### 3.3 One workspace coordinator, ordinary sessions, bounded inventory

Add `WorkspaceOverseerCoordinator`, an app-owned `@MainActor` class with one runtime entry per workspace UUID. It owns provisioning, enrollment reconciliation, and automatic-work admission—not grants or transcript data.

Its observable states are:

`disabled`, `paused`, `waitingForWorkspace`, `provisioning`, `running`, `blocked(reason)`, and `stopping`.

`running` means the workspace service is operating; it does not mean the model currently has an active turn.

Each entry owns a monotonically changing lifecycle generation, the reserved owner/session identities, one reconciliation task, and a dirty flag. Every asynchronous result carries its captured generation and is discarded when stale.

#### Durable ownership

Add an actor-backed `WorkspaceOverseerStateStore` with one versioned document at:

`~/Library/Application Support/RepoPrompt CE/WorkspaceOverseer/<workspace UUID>.json`

Its version-1 fields are:

- `workspaceID`, `ownerID`, `observerSessionID`;
- `excludedTargetSessionIDs`;
- revisioned `brief`, `memory`, and `workstreams`.

These are orchestration records, never link capabilities. Use injected URLs and writers for tests; production suppression must prevent existence checks as well as reads/writes.

Add an optional ownership marker containing `workspaceID` and `ownerID` to the ordinary session metadata and its indexed projection. Do not identify an Overseer by display name.

#### Provisioning sequence

1. Resolve the workspace’s current registered windows and settled inventory.
2. Durably reserve `ownerID` and `observerSessionID` before creating the session.
3. Reuse a matching owned session, or create an ordinary top-level session using that reserved identity.
4. Persist its ownership marker and the explicitly selected model configuration.
5. Wait for exact endpoint/restoration readiness before enrollment or startup.
6. On uncertain creation/persistence outcomes, reconcile the reserved identity; never allocate another session merely because a callback failed.

The ordinary creation path—not synthetic MCP-origin creation—must produce an observer-eligible session. Its exact API is an implementation verification gate.

For an initial interactive start, prefer the requesting eligible window. Otherwise select deterministically among eligible windows belonging to the same workspace. Duplicate live incarnations, conflicting ownership markers, or multiple owned Overseers block automation and surface repair guidance; never select an arbitrary winner.

Closing or explicitly stopping the Overseer pauses automatic work for the rest of that activation. Activity elsewhere must not recreate its tab immediately. Its history remains reopenable.

#### Inventory and reconciliation

Add a thin `WorkspaceOverseerSessionInventory` adapter over the verified workspace/session indexes and live endpoint host. The indexes establish workspace membership and described sessions; live endpoint identity establishes whether an operation is currently possible. Neither substitutes for the other.

Enroll existing eligible live top-level sessions, including idle sessions. Later enrollment follows new-session, binding-readiness, and meaningful activity events. Exclude children, all app-owned Overseer sessions, explicitly excluded targets, and endpoints that fail existing eligibility. Do not scan historical transcripts to discover current activity.

Coalesce events into one dirty-drain task. Build one live metadata snapshot per pass, calculate additions/removals, and process establishment serially. Proposed defensive limits are at most eight establishment attempts before yielding and 64 automatically owned live links per workspace, further limited by any lower existing authority limit. Show incomplete coverage rather than evicting relationships.

**Quiet policy:** after 15 minutes without meaningful target activity, and with no active run, pending interaction, or pending delivery, quiet that target’s routine monitoring work. Use one next-deadline task per workspace, not one timer per target. A delayed timer performs one reevaluation; it does not replay missed ticks.

Quiet retains history, exclusion/consent state, and valid grants. It stops routine automatic work for that subscription; it is not `stop`, `retire_lane`, or completion. Meaningful activity reactivates it. Polling, viewing, and acknowledgment do not manufacture activity.

Feed quiet eligibility into existing **routine** wake admission without changing the user’s saved toggles or consuming reducer entries. Purposeful attention and explicit Wake now retain their existing exceptions; disabled/paused ownership, missing authority, or stale endpoints remain hard gates. Do not create another notification queue. **Basis: D1, D5.**

### 3.4 Exact grants, exclusions, management, and restoration

**Proposed requirement:** automatic enrollment requests an authority-owned **observation-only profile**. Map that profile to the existing capability representation after inspecting the domain implementation. It must permit authorized status/transcript observation, but must not implicitly confer management, sending, compaction, worker creation, publication, or unrelated workspace access.

This is a required structural change if the current authority cannot express that profile. Prompt wording alone is insufficient. Ordinary manual Add retains its existing behavior. **Basis: D1–D3.**

#### Preserve pair identity; add intent provenance

Keep `AgentSessionOversightIntent` as the observer/target pair key so existing token and assertion-generation comparisons remain meaningful.

Introduce a version-2 encoded intent record retaining `observerSessionID` and `targetSessionID`, with optional `workspaceOverseer` metadata:

- `workspaceID: UUID`;
- `ownerID: UUID`;
- `access: "observe" | "manage"`.

This records the user-requested policy and ownership source, not live capabilities. Missing metadata identifies legacy/manual intent. Unknown access values or conflicting records must preserve-and-block, never default to managed.

The store remains the only durable relationship owner. Existing manual insert/remove interfaces remain supported; additive workspace-intent mutation interfaces carry provenance and expected ownership. Policy changes rotate the applicable intent identity and grant generation under the existing pair-serialization discipline.

The launch coordinator must exclude workspace-owned records from its legacy restore worklist. The workspace coordinator restores them only after settings, ownership, exclusions, and endpoint readiness all validate. Both use the shared bridge establishment core; neither creates grants independently. This prevents a saved observation-only relationship being restored through managed-by-default behavior. **Basis: D2, D4, D5.**

#### Eye-pill behavior

Keep navigation, Unlink, wake controls, and recovery in the eye-pill.

For workspace-owned relationships:

- **Exclude from workspace Overseer** records the target exclusion and ends that owned relationship. Ordinary Unlink from either endpoint must also prevent immediate automatic re-enrollment.
- **Manage** explicitly authorizes the verified management capability set for that exact relationship. The control must explain that it permits eligible one-time responses and steering, not blanket approval.
- Removing Manage revokes the old generation and establishes a fresh observation-only generation; do not mutate an in-flight lease into a different permission level.

All UI entry points—including inbound actions, sidebar actions, and popup Undo—must pass through the same ownership-aware bridge operation. Undo/reinclude may clear the corresponding exclusion only while its captured exclusion revision still matches; stale recovery cannot overwrite a later user decision.

Persist exclusion before allowing future enrollment, and revoke the exact live grant regardless of a subsequent persistence failure. On failure, suppress re-enrollment in memory and warn that the exclusion was not saved. Do not claim restart durability when the write failed.

Workspace-wide disable revokes only relationships marked as owned by that workspace Overseer. Manual relationships—including a manual relationship involving the same observer—are not adopted, downgraded, or deleted. Existing manual links are displayed as such, not presented as observation-only.

Revocation remains enforced by the domain authority at existing operation fences. Preserve the send rule that a transaction which already won its authorization commit may settle; disable cannot honestly promise to retract an already accepted delivery. **Basis: D6, D10.**

### 3.5 Durable brief, MEMORY, and workstream subscriptions

Use `WorkspaceOverseerStateStore` for a small local coordination ledger, not a general scheduler or arbitrary repository `MEMORY.md` writer.

Separate:

- **Brief:** explicit user instructions, with revision and approval provenance.
- **Memory:** model-generated summaries and observations; these never become instructions or permission.
- **Workstreams:** structured coordination records with ID, subject key, kind, priority, owning session, participating/created lane IDs, subscriptions, state, and attributed decisions.

Proposed workstream kinds are `analysis`, `implementation`, `review`, and `qa`; priorities are `low`, `normal`, and `high`; states are `reserved`, `open`, `waiting`, `quiet`, `needsValidation`, and `closed`. Only explicit completion/cancellation decisions close work; idle does not.

Use atomic store operations to reserve `(workspaceID, kind, subjectKey)` before creating a worker/review lane. Repository-review subjects use the exact review base and source/patch identity, not a chat title. An existing open reservation is joined or reported rather than spawning a second thread.

Extend existing `create_lane` with an optional `workstream_key`, required for creation initiated by an app-owned Overseer. This is a parameter extension, not a new tool. The bridge validates the reservation and retains all existing lane-creation authorization. Definite pre-creation failure releases the reservation; uncertain outcomes become `needsValidation` and block replacement creation until inventory reconciliation.

This prevents duplicate **registered** work, not every semantic overlap across arbitrary user-created chats. Do not advertise a stronger guarantee.

Subscriptions reference sessions and workstreams but confer no read access. A model receives brief/memory/registry context only through its own permitted workspace context and current grants.

Use revision-checked writes, bounded documents, and aggregate publication. Proposed limits: 64 KiB combined brief/memory, 512 workstream records, and 1 MiB per document. At a limit, preserve existing data and require explicit archival/export; never silently evict decisions.

After restart, validate recorded lanes against authoritative inventory and ownership before renewing claims. Missing data under incomplete restoration means uncertain, not deleted. Use verified existing self-compaction for context pressure; where unavailable, show a context-limit state rather than inventing an operation. **Basis: D3–D5; self-compaction wiring remains unverified.**

### 3.6 Truthful delivery, safe failures, and image input

#### Delivery and run-start state

Keep the existing target transaction and idempotency authority. Propagate `persisted`, `run_started`, and `run_start_failed` distinctly through the observer tool result and local UI. A `run_start_failed` result means “message saved; provider did not start,” not “send failed; resend.”

Add optional local transcript metadata `crossSessionDeliveryStatus`, with cases:

`accepted`, `dispatching`, `runStarted`, `runStartFailed`, `persistedOnly`.

Default it to absent for old rows. Record durable acceptance with the row and update later phases using the existing save path. On restore, `accepted`, `dispatching`, or missing start metadata means **start unconfirmed**, not proof that no call occurred. Terminal metadata-save failure must not reverse the known execution outcome.

Offer navigation to the target and its existing recovery controls. Do not automatically append another user row or generate a new idempotency key.

The durable workstream ledger retains pending operation identities and received outcomes. Because runtime authority is process-local, restart must not assume an old idempotency key still has a live receipt. An interrupted operation becomes `needsValidation`; inspect current state before any explicitly authorized retry. **Basis: D4, D6.**

#### Safe failure detail

Add optional `AgentFailureDiagnostic` metadata to runtime/persisted rows, populated at the actual provider/tool failure boundary—not by copying arbitrary `toolResultJSON`.

Its closed fields are:

- source: `tool`, `provider`, or `runStart`;
- code: `authenticationRequired`, `rateLimited`, `contextLimit`, `timeout`, `permissionDenied`, `unsupportedInput`, `executionFailed`, `cancelled`, or `unknown`.

Render a fixed, bounded summary from those fields, optionally using the already normalized tool name. Unknown failures receive generic guidance to inspect the local transcript. Do not include provider bodies, arguments, result text, interaction IDs, option bodies, URLs, or paths.

The sanitizer may emit this metadata for failed tool results while preserving structural omission of all other tool payloads. Include its cost in whole-row budgeting and preserve it through row truncation. Existing explicit error rows retain their separate redaction/capping behavior. Unknown/malformed optional diagnostic metadata is dropped locally without discarding the transcript row. **Basis: D7.**

#### Image-capable `send`

Extend existing `send`, including `delivery: "when_sendable"`, with optional image references. First milestone references are limited to image attachments already stored on a row in the sending session:

`images: [{ source_item_id: UUID, attachment_index: nonnegative integer }]`

Do not accept arbitrary local paths, URLs, or base64 payloads. Importing generated files is a separately scoped follow-up unless an existing safe attachment-import surface is verified.

The required path is:

**argument validation → exact authorization/idempotency reservation → source attachment snapshot → target-owned durable attachment retention → attributed row flush → final endpoint/model validation → provider attachment input → acceptance receipt.**

Proposed bounds are four PNG/JPEG images, 5 MiB per normalized image, 10 MiB total, and 16 million pixels per image. Apply lower existing provider limits where applicable. Decode/normalize off the main actor and reject unsupported or oversized input before row acceptance.

The first authorized attempt freezes attachment content and hashes. Digest the canonical message, workflow selector, and ordered image references under an image-specific digest domain. Completed retries consult the ledger before reopening attachments; they replay the original receipt even if the sender later removes the source row. Changed content under the same reference requires a new logical send/key.

Pending sends retain the frozen snapshot rather than rereading mutable source rows. Add attachment-byte backpressure—proposed 32 MiB per observer and 128 MiB process-wide—to existing queue limits. Cancellation and settled refusal release retention; indeterminate persistence retains it until reconciliation.

**Required interface changes at visible boundaries:**

| Boundary | Change |
|---|---|
| `executeSend(args:)` | Parse `images`; authorize before attachment lookup; pass typed references to both immediate and queued paths. |
| `bridge.send(...)` / `bridge.queueSend(...)` | Add a default-empty image-input argument; retain existing text-only callers. Exact declarations must be inspected. |
| `AgentSessionLinkSendRequest` | Add default-empty, immutable resolved image payload/retention data. Existing steer/compact callers remain unchanged. |
| `AgentChatItem.user(...)` inside `agentSessionLinkPerformSend` | Supply the resolved attachments to the existing attachment parameter. |
| Direct provider start and queued/replay paths | Pass the frozen attachments through the ordinary provider input mechanism, never through the target composer. |

A queue drain or post-persistence model change must revalidate image support. Never silently send only the text. After durable acceptance, inability to start remains a persisted delivery with an explicit start failure/unconfirmed state.

The provider attachment implementations are a blocking verification dependency: stored thumbnails or a target transcript row are not acceptance evidence. Test direct delivery, queued delivery, and interrupted ACP replay with actual provider input capture. Keep image content, storage paths, and source filenames out of observer projections and logs. `steer` and `create_lane` remain text-only initially and reject image arguments rather than ignoring them. **Basis: D6, D8.**

### 3.7 Whole-QA-slot coordination and artifact provenance

Add a **machine-wide QA lease** to conductor. It supplements existing lanes and the live-app lock; it does not replace them. **Basis: D11.**

#### Lease contract

Proposed operations are acquire, status, bind-artifact, renew, release, and cancel. A lease contains an opaque token, generation, owning conductor ticket/workstream, originating checkout identity, source identity, optional bound artifact identity, and deadline.

States are:

`reserved`, `bound`, `draining`, and terminal `released`, `cancelled`, or `expired`.

Use a 30-minute renewable lease with a two-hour maximum lifetime per acquisition. Acquisition/release and expiry are observable through conductor status and the workspace workstream.

Reserve before the first QA lifecycle action. Build privately, bind the resulting artifact, then perform launch, MCP smoke, screenshots, Oracle/image review, and follow-up inspection under the same token. An active bound lease cannot switch artifacts; another build requires explicit completion/cancellation and a new lease.

#### Admission and locking

All repo-owned operations that can replace the shared debug bundle, redirect its CLI helper, stop/open/relaunch the app, or initiate competing live QA must consult the lease. This includes interactive lifecycle **supersession before it cancels older jobs**, not merely the eventual launch runner.

A non-owning operation is refused as `qa_slot_busy` before claiming build/lifecycle lanes. Do not let a blocked foreign job hold a lane the lease owner needs.

Use the existing per-user coordination directory and lock discipline, adding a short-held QA-admission gate. Establish a single lock order between that gate and `live-app.lock`. Lease establishment waits for an already admitted lifecycle mutation to settle; lifecycle admission checks the current lease atomically with taking the live-app lock.

Do **not** hold `live-app.lock` for the whole QA loop: owner commands already acquire it and would otherwise self-deadlock. The long-lived lease is a separate coordination record.

Cancellation/expiry first fence the lease generation and cancel pending owner work. Keep the slot `draining` until no old producer can replace or launch the app; reuse existing process-identity and delayed-launch safeguards. If settlement cannot be established, expose a blocked recovery state rather than releasing optimistically. Releasing a lease does not implicitly stop the visible app.

Competing Oracle/image/lane QA must acquire its own slot or participate in the existing exact-artifact lease. Carrying an owner token does not permit substituting a different artifact.

#### Exact provenance

For strict QA, bind:

- canonical originating checkout/worktree identity and full commit;
- staged and unstaged binary-diff digests;
- content digests of relevant untracked build inputs;
- a canonical build-input manifest digest;
- packaged executable and complete bundle-content digests;
- toolchain/build-configuration identity and the artifact manifest digest.

The existing dirty Boolean remains descriptive, never identity.

**Important limitation:** hashing the live checkout before and after compilation does not prove files stayed unchanged during compilation. Strict QA must build from a sealed source snapshot whose manifest identifies the actual inputs. Record the originating checkout separately from that snapshot. Hash dependency inputs or pinned resolved revisions used by the build; do not imply that the commit alone covers them.

Extend provenance generation and artifact verification together. Embed provenance before signing, produce the artifact manifest afterward outside the bundle, and avoid self-referential hashes. Revalidate bundle/helper identity before launch and before associating subsequent evidence with the lease. Preserve current non-QA workflows; label their source identity as observed rather than sealed.

Conductor coordination protects cooperating repo tooling. Direct external process manipulation or arbitrary filesystem writes remain outside its guarantee; document that boundary rather than claiming OS-wide exclusion.

### 3.8 Observable acceptance criteria

| Boundary | Required evidence |
|---|---|
| Settings and launch | Old settings retain existing values and unknown fields; two workspaces retain independent choices; unavailable models never silently change; Autostart off and dormant restoration cause no automatic startup. |
| Deterministic isolation | Injected file/provider spies prove zero production Overseer, intent, and settings access from the new automatic path during suppressed/unit-test launches. |
| Provisioning | Concurrent starts and two-window restoration create one owned session. Delayed creation receipts, duplicate incarnations, and interrupted saves cannot create replacements blindly. |
| Exact authority | Automatic relationships are observation-only. Management/send attempts fail without their capability. Stale endpoints, revoked generations, permission loss, and cross-workspace destinations fail at the existing fences. |
| Exclusion and disable | Exclusion survives restart; popup Undo cannot undo a newer exclusion; disabling removes only workspace-owned grants; another observer’s/manual link survives. |
| Quiet/reactivation | A fake clock quiets eligible monitoring; real activity reactivates it; no idle transition marks a task complete, deletes history, or calls `retire_lane`. |
| Workstream ownership | Concurrent same-subject reservations cannot create overlapping registered lanes. Restart uncertainty holds the reservation. Retirement cannot affect unowned lanes or remove history. |
| Delivery | Exercise definite flush failure, failed compensation, post-flush cancellation, provider-start failure, and duplicate replay. UI/result wording agrees with durable delivery versus run start. |
| Diagnostics | Secrets, paths, raw tool payloads, `ask_user` bodies, and malformed diagnostic metadata never appear through the new failure projection. Summary bytes count toward the page budget. |
| Images | Fake-provider capture proves the exact frozen images arrive; queued and ACP replay paths retain them; unsupported/oversized inputs never degrade to text-only success. Live evidence must show the target model interpreting a distinctive test image. |
| Whole QA | Two separate conductor daemons/worktrees cannot replace or supersede the leased app. Test token mismatch, CLI-helper drift, expiry, owner death, cancellation during delayed launch, and blocked-job lane ordering. |
| Provenance | A dirty-patch change, untracked source change, modified bundle resource, or mismatched helper invalidates binding/evidence. The bound manifest identifies the sealed build inputs and resulting app. |

Use focused actor/state-machine tests with controlled suspension points, injected clocks/writers, and fake endpoints. Then use conductor-coordinated app tests/builds and the real CE debug MCP path. Visible launch/relaunch/stop still requires the approval prescribed by `AGENTS.md`; acquiring a QA lease is not that approval. **Repository instruction:** `AGENTS.md:1-45`.

## 4. File-by-file impact

**Proposed new paths are intentional design choices. Named but unprovided owners must be inspected before their exact declarations and callers are changed.**

| File | Change and dependency |
|---|---|
| `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift` | Add workspace settings dictionary, record type, fixed schema-11 feature boundary, and `requiredSchemaVersion` participation. Land with codec/manager preservation tests. |
| `Sources/RepoPrompt/Features/Settings/Views/SettingsView.swift` | Add Overseer routing, ordering, grouping, icon, navigation, and search. Depends on settings view/model. |
| `Sources/RepoPrompt/Features/Settings/Views/Overseer/WorkspaceOverseerSettingsView.swift` **new** | Minimal configuration/status view using existing catalog controls. |
| `Sources/RepoPrompt/Features/Settings/ViewModels/WorkspaceOverseerSettingsViewModel.swift` **new** | Scoped settings bindings, validated selection, persistent errors, and coordinator actions. No independent defaults or grant state. |
| `Sources/RepoPrompt/Features/AgentMode/Models/WorkspaceOverseerModels.swift` **new** | Lifecycle, ownership, document, brief, memory, and workstream value types. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/WorkspaceOverseer/WorkspaceOverseerStateStore.swift` **new** | Versioned atomic state persistence, exclusion revisions, provisioning reservation, and workstream compare-and-set operations. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/WorkspaceOverseer/WorkspaceOverseerSessionInventory.swift` **new** | Thin live/indexed inventory adapter; no historical transcript discovery. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/WorkspaceOverseer/WorkspaceOverseerCoordinator.swift` **new** | App-wide workspace entries, generation-fenced provisioning/reconciliation, quiet deadlines, and publication. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/WorkspaceOverseer/AgentModeViewModel+WorkspaceOverseer.swift` **new** | Ordinary session creation/start integration and workspace automation admission. No provider-specific alternate runner. |
| `Sources/RepoPrompt/App/WorkspaceOverseerComposition.swift` **new** | Construct and attach the coordinator once; connect workspace/window lifecycle, settings, termination, and suppression. Actual composition-root caller must be located. |
| `Sources/RepoPrompt/App/AppLaunchConfiguration.swift` | Expose the single derived policy for the new automatic subsystem, including unit-test suppression. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionOversightIntentStore.swift` | Version-2 ownership/access intent records; preserve pair keys, token fences, legacy manual mutations, and preserve-and-block behavior. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionOversightLaunchCoordinator.swift` | Filter workspace-owned entries from legacy restoration; retain its bounded manual-intent behavior. |
| `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentMonitorPill.swift` | Ownership-aware exclusion/reinclude and explicit Manage controls; preserve existing navigation/wake surfaces and exact-generation actions. Corresponding props/actions must be updated in their actual owners. |
| `Sources/RepoPrompt/Features/AgentMode/Models/AgentFailureDiagnostic.swift` **new** | Closed safe diagnostic and local delivery-status types. |
| `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift` | Optional diagnostic/delivery metadata, defaulted initialization, coding keys, and every runtime↔persisted conversion. Reuse existing attachments. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkTranscriptSanitizer.swift` | Safe failure projection and byte accounting; retain structural stripping, cursors, and attachment privacy. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkImagePayload.swift` **new** | Typed references, immutable resolved payload, limits, and retention contract. Reuse verified image storage/normalization infrastructure. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkSendTransaction.swift` | Default-empty image request data and image-domain digest; preserve text-only digest/envelope behavior. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentModeViewModel+SessionLinkSend.swift` | Attach frozen images to the row/provider input and publish delivery phases. Any added suspension requires the same identity/readiness revalidation. |
| `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift` | Add image parsing and `workstream_key` handling, forward typed inputs, and retain truthful existing receipts. Land with bridge/schema changes. |
| `Scripts/conductor_qa_slot.py` **new** | Machine-wide lease/admission state and expiry/settlement support. |
| `Scripts/app_source_provenance.py` **new** | Shared sealed-source manifest and provenance generation; avoid separate inconsistent hash implementations. |
| `Scripts/conductor.py` | QA commands, token propagation, pre-supersession admission, artifact binding, status, and cross-daemon enforcement. |
| `Scripts/package_app.sh` | Strict-QA snapshot/provenance input and shared-output admission. |
| `Scripts/write_app_artifact_manifest.py` | Strict-QA manifest extension, complete artifact identity, and verification. |
| `docs/architecture/workspace-overseer.md` **new**; `docs/architecture/agent-session-oversight-auto-wake.md`; `AGENTS.md` | Document ownership/consent, restore changes, quiet semantics, attachment/diagnostic boundaries, and whole-QA workflow after implementation. |

**Required additional edits whose bodies or exact paths are absent from the packet:** the named domain authority/models/authorizer; `AgentSessionLinkRuntimeBridge` and pending-send owner; endpoint resolver; canonical tool schemas and provider exposure filters; settings store/manager/codec; session metadata/index writers; passive-context and wake-admission integration; provider failure adapters and attachment/replay paths; target-sidebar and eye-pill props/action owners; app composition caller; shared-debug activation/CLI-install/Oracle-QA entry points; and existing manifest consumers.

Before production edits, resolve that list into actual paths, signatures, and all call sites. In particular, do not guess the `startAgentRun` attachment signature, the capability enum cases, or the lane-retirement result shape.

Add focused suites under `Tests/RepoPromptTests/AgentMode/WorkspaceOverseer/`, and extend the existing SessionLinks, Settings, App, and MCP suites. Add cross-process QA/provenance tests alongside the conductor script-test harness. Tests and production boundary changes should land together.

## 5. Risks, migration, and decisions requiring approval

### Persistence and rollback

| Boundary | Proposed migration/rollback behavior |
|---|---|
| Global settings | Introduce fixed `workspaceOverseerSchemaVersion = 11`; raise the required schema only when the new workspace group is present. Preserve lineage and unknown fields through the verified manager/codec. Older unsupported writers must not silently remove consent/configuration. |
| Oversight intent | Read version-1 pairs as legacy/manual intent. New version-2 workspace provenance cannot be interpreted by an older managed-by-default restore path. The existing older store’s future-version guard must preserve-and-block rather than restore these records. Verify this with old/new fixtures. |
| Workspace state | Version 1; unsupported, unreadable, conflicting, or oversized state blocks automatic provisioning/enrollment. Do not replace uncertain ownership with an empty document and create another observer. |
| Transcript metadata | Additive optional fields. Missing values preserve old behavior; malformed optional diagnostics/status do not destroy the enclosing row. Old readers may omit presentation metadata but gain no new authority. |
| QA artifacts | Keep existing non-QA manifest support. Strict-QA manifests require the upgraded verifier and sealed-source identity; old tooling cannot certify them. |

There is no atomic transaction across settings, workspace state, intent storage, and live authority. Use synchronous runtime fencing first, durable writes with explicit receipts, and reconciliation—not an optimistic “all saved” Boolean. Failed writes must distinguish effective in-process revocation from persistence that could reappear after restart.

### Product/policy sign-off

The draft resolves implementation choices as follows, but these are **proposals requiring approval**, not discovered product policy:

1. Workspace-scoped configuration; explicit model selection; Autostart off by default; observation-only automatic grants; separately approved per-thread management.
2. Fifteen-minute quieting without unlinking or task completion; 64-link automatic coverage cap with visible partial coverage.
3. Source-session attachment references and bounded PNG/JPEG support for `send`, rather than arbitrary file-path import.
4. Registered-workstream deduplication, not a promise to detect every overlapping review.
5. A mandatory sealed-source, artifact-bound QA lease for the complete live investigation.

The most consequential dependency is the authority/restore change: adding an observe-only control while retaining managed-by-default restoration would make the UI’s promise false. The second is provider attachment transport: persisted images are not sufficient evidence of model input. The third is QA enforcement coverage: an ungated interactive supersession or shared-bundle writer can invalidate the whole-slot guarantee.

**Maintainer-guidance check:** User impact is automatic observation with explicit authority and truthful outcomes. Root-cause confidence is high for the visible text-only-send and per-job-QA gaps; missing authority/provider integrations remain unverified. Existing stores and domain authority remain authoritative. Primary state risks are duplicate provisioning, consent loss on rollback, stale exclusion cleanup, and partial delivery. Scale is bounded to live metadata and coalesced work. Recommended scope is the targeted staged milestone above, validated at authority/persistence/provider boundaries and then the real CE app.

## 6. Implementation order

1. **Close the source-verification gates.** Record actual capability cases, tool registration/filtering, catalog validation, creation/retirement ownership, settings preservation, inventory events, attachment transport, and canonical verification/map locations. Review #1078 as an overlap lead. Add characterization tests before changing those contracts.

2. **Add value models and persistence tests.** Implement the workspace settings/state records, optional transcript metadata, and migration fixtures behind disabled defaults. This step should compile without starting a coordinator.

3. **Land observation-only authority and restore safety atomically.** Introduce workspace intent provenance, authority profile mapping, bridge establishment/revocation support, and launch-coordinator filtering together. Do not create durable workspace links until every reader can preserve their access policy.

4. **Land ownership-aware eye-pill mutations.** Add exclusion/reinclude, Manage consent, exact-generation mutation, sidebar routing, and stale-Undo tests. Verify that manual links remain untouched.

5. **Add provisioning, inventory, and settings composition.** Wire one coordinator into app lifecycle, reserve/reuse its ordinary session, publish status, and implement quiet/reactivation. Validate concurrent windows, cancellation, dormant restore, and deterministic isolation before enabling Autostart.

6. **Land safe diagnostics and image send end-to-end.** Diagnostics include failure adapters, persistence, sanitization, and budget tests. Image work must atomically include service/schema, bridge/queue, digest, storage retention, target transaction, and provider/replay inputs; do not advertise image support before those paths agree.

7. **Add the bounded brief/workstream ledger and existing-lane integration.** Require durable reservation for app-owned review/QA lane creation, retain uncertainty across restart, and verify ownership-safe retirement without history deletion.

8. **Land whole-QA admission and provenance before live validation.** Test separate daemons/worktrees, interactive supersession, owner death, late launches, dirty-source identity, and artifact drift. Then perform approved real-app/MCP/image/Oracle QA under one bound lease.

9. **Complete repository handoff validation and documentation.** Run the relevant conductor-coordinated focused tests, broader boundary suites, formatting/lint, and build validation; update the canonical feature map/verifier where located. Record source identity, artifact identity, tool visibility, provider image evidence, and outcome-specific failures in the implementation handoff. Keep local investigation artifacts out of the upstream change unless deliberately requested.
:::

### Oracle 2
- Status: Failed
- Provider: `Custom`
- Model: `claude-opus-5-5-xhigh`
- Effective effort: Provider default / not specified
- Chat: `workspace-overseer-plan--3C1FF1`

Error [context_builder_inactivity_timeout]: Context Builder Oracle exceeded its 600s inactivity budget during streaming.

Warning [lane_failures]: One lane did not complete

End of Oracle group: 2 lanes above.



> 💡 The 2 Oracle lanes above are independent answers; reconcile them using the guidance at the top of the group. Lane order is not a ranking.

Optional later follow-up: Continue this plan conversation with ask_oracle(chat_id: "workspace-overseer-plan-CF1AD8", new_chat: false)