## Final Prompt
<taskname="Workspace Overseer Plan"/>

<task>
Produce a comprehensive, reviewable feature map and PR-sized implementation plan for workspace-wide Overseer in RepoPrompt CE, grounded in this checkout. Planning only: do not implement, run experiments or alter the live app, publish, or change public issue dsebban/repoprompt-ce#10. Save the plan as a local document under docs/plans if appropriate; do not overwrite an existing plan or issue draft without first establishing its exact contents and purpose.
</task>

<architecture>
The existing feature is session-to-session oversight, not workspace-wide enrollment. Four documented owners split current responsibility: `DomainAgentSessionLinkAuthority` owns live link authority/capability leases/generation fencing; `AgentSessionLinkPassiveStatusNotices` projects coalesced status and attention; `AgentSessionLinkPromptContext` builds immutable provider claims/receipts; and `AgentModeViewModel+SessionLinkAutoWake` owns wake admission. `AgentSessionLinkRuntimeBridge` joins service, live session host, persisted intent and domain authority. `AgentSessionOversightIntentStore` persists directed UUID-pair intent, and `AgentSessionOversightLaunchCoordinator` performs bounded startup restoration when app topology is ready. Workspace inventory/lifecycle comes from `AgentWorkspaceSessionIndexStore` and `AgentSessionMetadataIndex`, with live runtime composition and session restoration elsewhere in the app.

The MCP surface is `AgentSessionLinkMCPToolService`, exposed through MCP connection/tool catalog policy. It already has link operations, lane create/retire, send/steer/stop and read/poll/wait paths. Target-side send work is split across `AgentSessionLinkSendTransaction`, `AgentSessionLinkPendingSend`, and `AgentModeViewModel+SessionLinkSend`; the target persists a row before provider run start and distinguishes “saved, run start failed.” Tool receipt delivery state, target item identity, and duplicate status are separate. Existing run-failure projections live in lane/domain status models; transcript sanitization separately reduces tool results.

Images already have an attachment model/store, chat-row persistence representation, and ordinary Agent provider-input path (`AgentAttachmentStore`, `AgentChatModels`, `AgentModeRunService`). The linked-session MCP send interface is presently text-only. Verify actual model-input transport before treating a stored/reference-only image row as vision support.

Existing contributor guidance is in `AGENTS.md` and `.agents/skills/rpce-maintainer-guidance/{SKILL.md,references/guidance-sources.md}`. Existing image acceptance instructions are in `docs/testing.md`; `Scripts/conductor.py` owns job lanes, live-app coordination and some checkout provenance. Reuse these rather than proposing a parallel verification system.
</architecture>

<selected_context>
- `AGENTS.md`: repository engineering, evidence, testing and approval rules.
- `.agents/skills/rpce-maintainer-guidance/SKILL.md` and `references/guidance-sources.md`: evidence confidence, source authority, persistence, latency/coalescing and maintainership checks.
- `docs/architecture/agent-session-oversight-auto-wake.md`: current authority boundaries, managed defaults/restricted grant behavior, UI controls, restore boundaries and separate wake settings.
- `prompt-exports/oracle-plan-2026-10-01-155814-workspace-overseer-p-66f6.md`: prior Oracle output. It contains one completed GPT lane and one Claude timeout; the completed lane itself warns that several candidate owners were outside its selection. Treat it as a research lead, not source proof.
- `docs/testing.md`, `Scripts/conductor.py`: existing real-app Oracle-image proof path, smoke prerequisites, machine-wide live-app coordination, current lanes and provenance limitations.
- `DomainAgentSessionLinkAuthority.swift`, `DomainAgentSessionLinkModels.swift`, `DomainAgentSessionOperationAuthorizer.swift`: live authority, capabilities, leases, statuses, failure reasons, receipts, pending interactions and lane projections.
- `AgentSessionOversightIntentStore.swift`, `AgentSessionOversightLaunchCoordinator.swift`, `AgentWorkspaceSessionIndexStore.swift`, `AgentSessionMetadataIndex.swift`: durable link intent, startup restore and workspace/session index projection.
- `AgentSessionLinkRuntimeBridge.swift`, `AgentSessionLinkMCPToolService.swift`: app/MCP ownership seams, current operation paths, lane APIs, text-only send boundary and receipt wire fields.
- `AgentSessionLinkSendTransaction.swift`, `AgentSessionLinkPendingSend.swift`, `AgentModeViewModel+SessionLinkSend.swift`: deduplication, queued admission, target persistence-before-run and partial delivery outcomes.
- `AgentSessionLinkTranscriptSanitizer.swift`, `AgentModeViewModel+SessionLinkInteraction.swift`: sanitized transcript/tool results and request-scoped consent/ACP one-time allow checks.
- `AgentAttachments.swift`, `AgentAttachmentStore.swift`, `AgentChatModels.swift`, `AgentModeRunService.swift`: safe app-owned image import/cleanup, persisted rows and ordinary provider input handoff.
- `AgentMonitorPill.swift`: current toolbar entry, manual session-ID preview/add, outbound/inbound rows, unlink/undo, activity, persistence feedback and wake controls.
- `GlobalSettingsDocument.swift`, `GlobalSettingsManager.swift`: current schema 10, settings feature-group migration/defaults and durable scoped mutation owner.

The requested `docs/plans/workspace-overseer-issue-draft.md` was read during discovery but RepoPrompt’s current selector could not resolve it as a selectable file (it did not appear in the selected file tree). Its additional proposals were independent model selection and Autostart; treat those as optional product choices rather than established requirements. Do not infer that the draft is absent from every checkout or overwrite it blindly.
</selected_context>

<relationships>
- App toolbar `AgentMonitorPill` → `AgentSessionLinkRuntimeBridge` → endpoint resolution, domain authority and directed intent persistence; Add is explicit user action after preview, and either endpoint can Unlink.
- Startup coordinator → workspace/window topology readiness → live session endpoint resolution → restored intent reservation. Intent persistence records UUID pairs, not the runtime capability grant.
- Domain link authority → operation authorizer/lease → MCP service → bridge/target-side ViewModel → durable chat row → provider run. Admission, persistence, provider execution and receipts are distinct outcomes; preserve their distinctions.
- Lane board is a derived projection (run outcome/failure reason/send blockers/child census), not the durable source of truth.
- Ordinary attachments flow from safe import and chat-row persistence to provider run inputs. Linked-session sends currently stop at text parsing; end-to-end vision requires tracing extension points through actual provider inputs and cleanup.
- Conductor jobs use existing `build`, `debugArtifact`, `liveApp`, `release`, and `style` lanes plus machine-wide live-app coordination. No existing full-QA-session reservation or general Overseer verification tool/map was found; `docs/testing.md` has a feature-specific Oracle image map and conductor smoke procedure, not a universal feature map.
</relationships>

<source_facts_and_scope>
Independently source-confirmed: new and restored manual links default to managed capability (`reserveLink(... capabilities: = .managed)`); capability is fixed for the live grant, and a restricted grant is not silently promoted. The durable intent store saves the directed pair but no capability, and startup restore follows the managed-default normal bridge path. Restricted live grants support monitor/status/read-style observation while respond/steer require `.manage`. The current dashboard has no per-link “Manage” toggle. Therefore automatic observation-only enrollment needs enforceable authority and safe restore semantics; a UI label or prompt instruction is insufficient. Preserve current manual/restored-link semantics unless a migration and consent policy is explicitly designed.

Known run/lane failure reasons (`processCrash`, `timeout`, `agentError`, `cancelled`) are already projected separately from detailed MCP tool errors. Sanitization structurally reports tool name/status but does not generally surface the underlying safe actionable error detail; explicit error rows are bounded/redacted. Plan these as distinct requirements.

The current checkout baseline observed during discovery was branch `feat/oracle-image-attachments` at `60ad7fe46` (29 Sep 2026), tracking its origin branch, with 38 modified files and one untracked investigation note. Do not attribute those changes to this task or assume a clean baseline; inspect current status before implementation. User-supplied upstream leads (#1120, #1123, #1131, #1132, active #1144/#1139/#1133, and fork #27/#33/#34) have not been verified against this checkout. Use them only as leads and identify checkout divergence with evidence. Public issue #10 remains untouched.
</source_facts_and_scope>

<deliverable_requirements>
Create a feature map covering every existing/proposed feature and for each record: exact owner/symbol and source path; user entry point; agent/MCP drive path; permissions and consent; states/transitions; persistence and restart behavior; observable proof; prerequisites/traps; present status (existing/partial/missing/product decision); and proposed milestone. Cover workspace opt-in/enrollment of existing and new active sessions, durable exclusions, managed versus observation-only authority, explicit linking/unlinking, owned lanes versus pre-existing threads, responsiveness, wake/quiet behavior, failures and sanitized actionable tool diagnostics, send/admission/receipt/idempotency, immediate and queued images/provider vision transport/cleanup, workstream context, model configuration, startup/restart/multiwindow, shared QA/resource coordination, and truthful reporting/completion evidence.

Then give a concise Maintainer-guidance check and an evidence-confidence/unknowns section. Distinguish directly verified source facts, Oracle suggestions, user-provided upstream leads, and product choices. Resolve source-verifiable questions rather than returning them to the user. Explicitly identify unresolved choices, including observation-only auto-enrollment authority/restore, scope and exclusion semantics, whether independent model selection or Autostart belongs in scope, and what “shared QA” means.

Offer a recommended minimal default and tradeoffs without implying approval for a new permissions design. A sensible recommendation to evaluate is workspace supervision opt-in, automatic observation of eligible existing/new active threads, durable exclusions, explicit user authorization for link changes and writes, and model choice/Autostart/expanded QA coordination as optional extensions. Make clear that the observation-only proposal needs real capability enforcement and restore safety.

Plan bounded PR-sized stages and dependencies. For each stage name the owner/interface seam, migration and rollback/state-safety approach, concurrency/scale concerns, focused regression evidence, and real app/MCP acceptance evidence. Reuse or extend current owners and verification assets; identify deletion/reuse opportunities. Keep basic supervision useful without optional image, diagnostic-detail, workstream, model-selection, or QA extensions where feasible. Include consent-aware enrollment and truthful delivery as core safety properties. Do not prescribe speculative abstractions, arbitrary caps/timeouts/schema versions, or a sealed-source QA subsystem as mandatory for basic supervision. Plan only; do not implement or publish.
</deliverable_requirements>

<ambiguities>
The draft file was readable in discovery but unselectable in the current context; its key extra proposals (independent model selection and Autostart) are captured above. The Oracle plan’s second lane timed out, and the successful lane lacked coverage of several candidate owners; source-check its every load-bearing claim. The checkout has unrelated dirty work. Upstream/fork issue state is user-provided context, not verified current source. Product decisions remain for enrollment authority/restore, precise workspace scope/exclusion policy, optional model/autostart, and shared QA semantics. Mark any additional uncertainty rather than inventing policy.
</ambiguities>
<oracle_artifact_selection_note>
The Oracle export was read during discovery but is not included in the final selection because its size would push selected context above the hard token budget. Its relevant facts are summarized above: GPT produced one completed lane, the Claude lane timed out, and the completed lane cautioned that several implementation owners were outside its selection. This is not independent source verification.
</oracle_artifact_selection_note>
<selection_update>
Correction to the selected_context inventory above: `AgentMonitorPill.swift` was read and its current toolbar/Add/Unlink/inbound/wake UI was mapped during discovery, but its implementation was removed from the final selection to satisfy the token limit. Use the architecture document and this discovery summary for those current UI facts; inspect the UI source if tools are available before implementation.
</selection_update>

## Selection
- Files: 26 total (1 full, 25 slice)
- Total tokens: 37444 (Auto view)
- Token breakdown: slice 37444
- Token accounting: incomplete from active_tab_published; refresh pending; incomplete: files

### Files
### Selected Files
├── .agents/
│   └── skills/
│       └── rpce-maintainer-guidance/
│           ├── references/
│           │   └── guidance-sources.md — 0 tokens (lines 1-43 (Maintainer evidence ledger and guardrails against treating historical or private guidance as product policy.))
│           └── SKILL.md — 0 tokens (lines 1-102 (Maintainer guidance for evidence, one authority, persistence safety, scope, observability, latency and verification.))
├── Scripts/
│   └── conductor.py — 0 tokens (lines 1-80 (Conductor lane and machine coordination root.), 3520-3610 (Existing per-job lane assignment; no full QA session reservation.), 7540-7630 (Debug app source/worktree/commit and dirty boolean provenance.))
├── Sources/
│   ├── RepoPrompt/
│   │   ├── Features/
│   │   │   ├── AgentMode/
│   │   │   │   ├── Models/
│   │   │   │   │   ├── AgentAttachments.swift — 0 tokens (lines 1-100 (Agent image attachment source/storage model.))
│   │   │   │   │   └── AgentChatModels.swift — 0 tokens (lines 110-355 (Cross-session attribution and persisted-ready runtime chat row; image attachment support.), 553-617 (Persisted chat row image-attachment encode/decode conversion.))
│   │   │   │   └── Runtime/
│   │   │   │       ├── SessionLinks/
│   │   │   │       │   ├── AgentModeViewModel+SessionLinkInteraction.swift — 0 tokens (lines 1-180 (Safe pending-interaction projection and request-specific manual-only policy.), 235-325 (Request-scoped response validation and genuine one-time ACP allow enforcement.))
│   │   │   │       │   ├── AgentModeViewModel+SessionLinkSend.swift — 0 tokens (lines 1-300 (Target-side delivery linearization, persistence flush, provider run start and partial failure handling.))
│   │   │   │       │   ├── AgentSessionLinkPendingSend.swift — 0 tokens (lines 1-280 (Queued when_sendable send state, one-slot admission, idempotency and cancellation behavior.))
│   │   │   │       │   ├── AgentSessionLinkRuntimeBridge.swift — 0 tokens (lines 1-220 (Runtime bridge protocols and ownership seam connecting link service, live host and domain authority.), 350-620 (Exact candidate resolution and existing create/add/unlink/revoke bridge calls.))
│   │   │   │       │   ├── AgentSessionLinkSendTransaction.swift — 0 tokens (lines 1-320 (Typed send request, normalized message digest/idempotency and outcomes.))
│   │   │   │       │   ├── AgentSessionLinkTranscriptSanitizer.swift — 0 tokens (lines 1-530 (Current sanitized transcript paging, structural tool call/result reduction, failed tool status and separate bounded error rows.))
│   │   │   │       │   ├── AgentSessionOversightIntentStore.swift — 0 tokens (full)
│   │   │   │       │   └── AgentSessionOversightLaunchCoordinator.swift — 0 tokens (lines 1-420 (Bounded startup-only restore path, topology readiness, endpoint proof, automatic-reservation uniqueness and failure states.))
│   │   │   │       ├── WorkspaceLifetime/
│   │   │   │       │   └── AgentWorkspaceSessionIndexStore.swift — 0 tokens (lines 1-320 (Workspace session index store owner, notification/coalescing and restoration topology signals.))
│   │   │   │       ├── AgentAttachmentStore.swift — 0 tokens (lines 1-120 (Current safe import into app-owned storage, attachment creation and consumed-file cleanup.))
│   │   │   │       ├── AgentModeRunService.swift — 0 tokens (lines 140-430 (Existing provider start request assembly and attachment handoff to ordinary agent input.), 560-640 (Queued steering attachments at physical provider submission.))
│   │   │   │       └── AgentSessionMetadataIndex.swift — 0 tokens (lines 1-220 (Session metadata index row and workspace membership/activity/provider/lane identity, the persisted inventory projection for workspace supervision.), 400-455 (Projection from live AgentSession into the durable index, connecting runtime lifecycle to workspace inventory.))
│   │   │   └── Settings/
│   │   │       └── Models/
│   │   │           ├── GlobalSettingsDocument.swift — 4,460 tokens (lines 1-170 (Current schema 10 feature-boundary migration rules and requiredSchemaVersion computation.), 640-820 (Settings typed feature groups and defaults.))
│   │   │           └── GlobalSettingsManager.swift — 4,011 tokens (lines 1-180 (Settings manager/store ownership and durable access contracts.), 620-780 (Scoped mutation persistence results and error handling.))
│   │   └── Infrastructure/
│   │       └── MCP/
│   │           └── Agent/
│   │               └── AgentSessionLinkMCPToolService.swift — 5,804 tokens (lines 1-185 (MCP operation inventory, request caller identity and domain authorization contract.), 510-625 (create_lane/retire_lane argument checks and ownership handling.), 1080-1185 (Current send/compact argument and target call path; text-only sending boundary.), 2040-2090 (Wire receipt separates delivery state from target item identity and duplication.))
│   └── RepoPromptDomainRuntime/
│       ├── DomainAgentSessionLinkAuthority.swift — 6,090 tokens (lines 1-40 (Authority invariants and capacity bounds; exact link incarnation authority, managed default, and lack of link-count cap.), 275-465 (Link reservation/activation capabilities, managed default and generation fences.), 1350-1570 (Send/stop idempotency authority and exact capability lease commit fences.))
│       ├── DomainAgentSessionLinkModels.swift — 6,286 tokens (lines 1-570 (Endpoint, grant/capability, lease, status, failure reason, receipt, pending-interaction and workspace lane projections.))
│       └── DomainAgentSessionOperationAuthorizer.swift — 2,048 tokens (lines 1-180 (Targetless outbound list authority and operation/capability mapping.))
├── docs/
│   ├── architecture/
│   │   └── agent-session-oversight-auto-wake.md — 6,795 tokens (lines 1-132 (Current link authority, passive reducer, claim/receipt, wake coordinator and prompt authority boundaries.), 202-300 (Managed-by-default new/restored links, restricted grants, no Manage toggle in dashboard, and exact poll/respond/steer capabilities.), 382-435 (Exact sidebar Add/Unlink controls, current target-side management surface and lifecycle safety.), 606-632 (Existing separate periodic wake policy, default off and not a workspace session monitor.))
│   └── testing.md — 1,950 tokens (lines 1-40 (Existing contributor verification layers and test quality contract.), 54-100 (Current Oracle image real-app/MCP feature map and smoke path; shows image proof prerequisites and verification artifact owner.))
└── AGENTS.md — 0 tokens (lines 1-305 (Repository instructions for code ownership, contributor validation, approval boundaries and coordinated live app/test workflows.))


---

## Generated Plan
- Oracle group status: partial_failure
- Oracle group: `238EB174-31CA-4D9B-BD21-FDC3E5C7B4D4`

**Reconciling these Oracle lanes**
2 independent answers to the same request follow. Lane order is not a ranking; the first lane supplies the top-level continuation handle, and a successful follow-up through any lane's chat ID re-runs every lane.
- Read every lane through the end-of-group marker (`End of Oracle group: 2 lanes above.`). If the marker or a lane is missing, page the export or try the read-only `oracle_chat_log` with that lane's chat ID. Logs may be scoped or clipped; report any remaining gap. Do not start a follow-up just to retrieve prior text.
- Reconcile by evidence, not lane order, answer length, or model identity: check material single-lane and conflicting claims against the code, and report unresolved disagreements. A failed or partial lane is incomplete evidence.

Lanes (2):
- Oracle — `gpt-6-astra-pro` — Completed — chat ID `workspace-overseer-plan-9A92A7`
- Oracle 2 — `claude-opus-5-5-xhigh` — Failed — chat ID `workspace-overseer-plan--CB3EBA`

### Oracle
- Status: Completed
- Provider: `Custom`
- Model: `gpt-6-astra-pro`
- Effective effort: Provider default / not specified
- Chat: `workspace-overseer-plan-9A92A7`

The recommended core is **workspace opt-in that creates enforceable observation-only links**, while preserving existing manual links and their permissions. That permissions policy still requires explicit product approval; the plan below specifies how to implement it safely rather than treating it as already approved.

:::writing{variant="document" id="74829" title="Workspace Overseer: Feature Map and PR-Sized Implementation Plan"}

# 1. Summary

Implement workspace-wide Overseer as a targeted extension of the existing session-link system, not a replacement authority, scheduler, or agent runtime. A user selects an existing Agent session to supervise one workspace and explicitly authorizes automatic **observation-only** enrollment of eligible open sessions, including subsequently opened sessions. Persist the workspace policy and exclusions separately from ordinary directed-link intent; derive fresh, narrowly capable links against exact live endpoints. Preserve manual/restored managed links, explicit restricted grants, existing wake controls, target-side delivery transactions, and receipt semantics. Ship useful supervision before optional diagnostic detail, images, workstream tooling, independent model configuration, Autostart, or broader QA coordination.

# 2. Current-state analysis

## 2.1 Evidence notation and limits

**Direct observation** means the supplied source or architecture document states or implements the claim. **Inference** means the conclusion follows from the cited observations but was not runtime-tested. **Proposal** identifies a new design decision, not existing behavior or approved policy. **Discovery summary** identifies information supplied about an omitted file; it is not independent inspection of that file.

The frozen excerpts are sufficient to establish the main authority, persistence, delivery, and attachment boundaries. They do **not** include the implementation of `AgentMonitorPill`, the complete bridge establishment methods, the host conformance, the settings write backend, provider image codecs, or the earlier Oracle plan. Those implementation locations must be bound during PR 0; this plan does not invent their paths or claim they were inspected.

The reported branch, commit, dirty-file count, issue references, and prior discovery results are historical inputs, not a verified description of the implementer’s eventual working tree.

## 2.2 Current responsibility and control flow

### Links and authorization

**Direct observation.** `DomainAgentSessionLinkAuthority` is the process-local actor owning grants, generations, reservations, cursors, waiters, and send idempotency. Endpoint identity includes window, workspace, tab, session, persistent binding generation, and binding-transition generation. A session UUID alone is not authority. Reservation grants nothing until activation installs a seeded observation snapshot.[^authority]

**Direct observation.** New reservations default to `.managed`; an idempotent reservation returns the existing grant without changing its capabilities. Critically, `.version1` is **not observation-only**: it includes `.sendWhenIdle`, which authorizes both `send` and `compact`. Management operations require `.manage`.[^capabilities]

**Inference.** Neither a “read-only” UI label nor selecting `.version1` implements the proposed safe default. Automatic observation needs the exact capability set `{poll, wait, read}` and protection against paths that could convert an automatically acquired relationship into management authority.[^capabilities]

### Durable intent and restoration

**Direct observation.** `AgentSessionOversightIntentDocument` stores a version and directed observer/target UUID pairs. It stores neither capabilities nor live endpoint identities. The store distinguishes durable success from blocked or failed writes and uses tokens/assertion generations to protect newer intent from stale cleanup. The launch coordinator operates on a fixed launch worklist, waits for topology and binding-qualified readiness, and does not continuously enforce desired membership.[^restoration]

**Direct observation.** The documented restored-link path uses the managed default. New and restored manual links are managed; explicit restricted live grants remain restricted.[^management]

**Inference.** Writing an automatic observation-only pair into the existing intent document would discard the information needed to keep it observation-only after restart. Workspace-derived relationships must not enter that pair-only persistence path.[^restoration][^management]

### MCP and target delivery

**Direct observation.** `AgentSessionLinkMCPToolService` validates operation arguments and resolves a server-derived caller endpoint. `executeSend` obtains authorization and dispatches to immediate `bridge.send` or `bridge.queueSend`. Target-side delivery claims submission ownership, crosses the authorization commit fence, revalidates live state, persists the attributed row, revalidates again, and only then attempts provider startup.[^mcp][^delivery]

The relevant transformation chain is:

> User-approved relationship → exact domain grant → operation-specific lease → bridge request → target admission/commit fence → attributed durable row → provider-only envelope and input → delivery receipt.

**Direct observation.** A durable row is not proof of provider startup. The transaction can return a persisted-only delivery; persistence with unconfirmed compensation is indeterminate and spends the key. Receipts separately carry target item identity, delivery state, resulting run state, and duplicate status.[^delivery][^receipts]

### Observation and wake behavior

**Direct observation.** The passive reducer, immutable provider claim/receipt, and wake coordinator have separate responsibilities. The lane board is derived state, not another authority. Purposeful attention can bypass routine selection and the exact lane’s snooze; unlink/revocation remains a hard gate. Periodic idle waking is a separate, default-off session preference.[^wake]

**Inference.** Workspace enrollment should feed the existing observation pipeline rather than introduce another notification queue, polling loop, or wake timer. Enrollment policy and wake admission remain different questions.[^wake]

### Workspace inventory and images

**Direct observation.** `AgentWorkspaceSessionIndexStore` validates workspace ownership using activation epochs. Its owner-validated projections return empty values when ownership is stale. `AgentSessionMetadataRecord` contains workspace/session identity, parent and creator provenance, saved provider configuration, and activity metadata—not live endpoint authority.[^inventory]

**Inference.** An empty owner-validated index cannot, by itself, prove that a workspace contains no sessions. Enrollment must distinguish unready inventory from a settled empty inventory and resolve grants against the live host.[^inventory][^bridge]

**Direct observation.** Ordinary Agent rows and run startup accept image attachments, but linked-session `executeSend` is text-only. `AgentAttachmentStore` checks file/UTType suitability and copies into app-owned storage; the shown implementation does not perform MCP workspace authorization or establish bounded image decoding. Active ACP prompt submission explicitly rejects nonempty attachments.[^attachments][^mcp-send]

**Inference.** Existing attachment plumbing is reusable, but it is not proof of end-to-end linked-session vision, safe MCP file ingestion, or image-capable live steering.[^attachments]

## 2.3 Feature map

Each row records the current/proposed owner, entry paths, permissions, state/restart behavior, and the observable acceptance condition. Milestones are defined in §6.

### Workspace scope, authority, and lifecycle

| Feature / present status / milestone | Owner and source evidence | User entry / agent drive / consent | States and persistence | Observable proof / prerequisites and traps |
|---|---|---|---|---|
| **Workspace opt-in and enrollment of existing/new open sessions — Missing; product decision. Core PRs 1–4.** | **Direct observation:** workspace ownership and live-host seams already exist.[^inventory][^bridge] **Proposal:** `AgentWorkspaceOverseerPolicy` and `AgentWorkspaceOverseerCoordinator`, at the new paths in §4. | User enables supervision for a selected existing observer. Models use existing `list`, `poll`, `wait`, and `read`; no model-facing workspace-enablement operation. Opt-in explicitly covers current and future eligible open sessions. | Disabled → waiting for workspace/observer → reconciling → active/partially waiting. Persist policy, not derived links. | Current and newly opened eligible sessions acquire narrow live grants without focus changes or provider startup by the enroller. Closed history is not opened or enrolled. |
| **Durable exclusions and stopping supervision — Missing; product decision. Core PRs 2–4.** | **Inference:** pair removal alone cannot encode “do not enroll this target again” under a workspace policy.[^restoration] **Proposal:** exclusions belong to the workspace policy. | Target/observer Unlink records an automatic-enrollment exclusion for the applicable configured pair. Workspace Disable stops derived observation. Models cannot clear either control. | Exclusions survive closing/reopening and restart. Failed saves retain an immediate process-local suppression and show an unsaved warning. | Excluded sessions remain absent after new topology events and restart. A settings failure must not cause current-process re-enrollment. |
| **Observation-only versus managed authority — Partial substrate; new policy required. Core PR 1.** | **Direct observation:** capabilities are fixed, `.version1` includes sends, and managed defaults already exist.[^capabilities] Owner: `DomainAgentSessionLinkAuthority` and `DomainAgentSessionLinkCapability`. | Automatic grants receive only `poll`, `wait`, `read`. Explicit normal Add retains its existing managed-default contract. | Authority tracks automatic provenance in process memory. Fresh grants are reconstructed from the workspace policy, never from saved automatic pairs. | Automatic-only grants cannot send, compact, respond, steer, stop, or retire targets; cannot bootstrap managed lanes or managed fork inheritance. |
| **Explicit Add, Unlink, and existing restricted links — Existing; integration needed. Core PRs 1, 3–4.** | **Direct observation:** existing reservation preserves a live grant’s capabilities; current documentation states there is no per-link Manage toggle.[^authority][^management] `AgentMonitorPill` entry details are a **discovery summary**, not supplied UI source. | Existing explicit Add remains available. Converting an automatically observed target to a normal direct link requires an explicit, accurately labeled user action. Either endpoint can unlink. | Manual directed intent remains in its current store. A restricted direct grant is not silently upgraded. Conversion creates a new grant generation. | Old leases fail after conversion; another observer’s relationship is unchanged; manual links survive workspace Disable. |
| **Owned lanes versus pre-existing sessions — Existing distinction; enrollment integration needed. Core PR 1, optional later lane UX.** | **Direct observation:** host APIs expose lane creation/provenance/retirement; metadata separately records `parentSessionID` and `createdByOverseerSessionID`.[^lanes][^inventory] | Existing `create_lane`/`retire_lane` remain the agent drive paths. Automatic observation is not ownership and is insufficient to acquire creation authority. | Enrollment changes no provenance. Closing a pre-existing session never becomes an inferred retirement request. | A pre-existing thread cannot be retired merely because it was enrolled. Automatic-only relationships do not manufacture managed descendants. |
| **Restart, lazy tabs, duplicate bindings, and multiple windows — Existing primitives; workspace coordination missing. Core PRs 1–4.** | **Direct observation:** exact endpoint identities, discovery inputs, passive restoration hydration, and topology uncertainty are represented.[^authority][^restoration][^bridge] | No automatic window opening, workspace switching, observer creation, or focus change. Existing chosen observer must resolve exactly. | Missing/ambiguous observer waits or blocks. Uncertain topology preserves policy. Workspace reactivation can reconstruct eligible derived links. | Two windows for one workspace produce one process-wide scope; duplicate observer incarnations fail closed; stale hydration cannot activate the wrong binding. |

### Observation, wake behavior, and delivery

| Feature / present status / milestone | Owner and source evidence | User entry / agent drive / consent | States and persistence | Observable proof / prerequisites and traps |
|---|---|---|---|---|
| **Responsive supervision UI — Existing lightweight projection; workspace aggregation missing. Core PRs 3–4.** | **Direct observation:** `agentSessionLinkStatusProjection` is explicitly separate from transcript-redacting observation snapshots; index replacement coalesces delegate notification.[^bridge][^inventory] | Toolbar/dashboard displays supervision state and enrollment counts. MCP sees only authorized link inventory and observations. | Published UI is derived from current policy, inventory readiness, and authority results; it stores no grant truth. | Streaming updates do not trigger workspace-wide transcript scans, repeated hydration, or per-session disk-index rebuilds. |
| **Auto-wake, quiet controls, attention, periodic wake — Existing. Reuse in core.** | **Direct observation:** current wake controls, purposeful-attention exceptions, and periodic-idle semantics are documented.[^wake] | Existing controls remain the entry point. Enrollment consent explains possible model usage under those controls. | Do not reset user preferences. Seed initial observation without fabricating a status/attention occurrence. No new timer or catch-up turn. | Enabling supervision itself does not dispatch a turn through the enroller. Later genuine updates obey existing wake rules; master-off is not falsely labeled a complete attention mute. |
| **Run failures and lane health — Existing. Reuse in core.** | **Direct observation:** `DomainAgentSessionLaneBoard` separates run outcome, failure reason, blockers, and child counts.[^capabilities] | Dashboard and existing `poll`/`wait` expose current observations. | Board remains derived and potentially lagging; no new failure database. | Process crash, timeout, agent error, cancellation, and “not sendable” are not collapsed into one “stuck” condition. |
| **Safe actionable tool diagnostics — Partial. Optional PR 5.** | **Direct observation:** sanitizer emits tool name/status without arguments/results; explicit error rows are separately redacted and bounded.[^sanitizer] | Existing `read`; optional additional diagnostic field on sanitized tool rows. No new permission. | Unknown/unavailable diagnostic data stays absent. No raw-result fallback, including after restore. | Known app-generated refusal codes produce bounded safe recovery guidance; secrets, arguments, interaction IDs, and third-session identities remain absent. |
| **Immediate send, admission, and truthful receipt — Existing. Reuse in core; optional image extension in PR 6.** | **Direct observation:** `executeSend`, `agentSessionLinkPerformSend`, and receipt rendering separate authorization, target persistence, and execution.[^mcp-send][^delivery][^receipts] | Existing `send` under a direct send capability. Automatic observation does not enable it. | Refusal before durable acceptance leaves no accepted row; persisted-only and indeterminate outcomes retain their distinct semantics. | Same-key retry returns the original outcome, not a second row. `run_start_failed` is not reported as successful execution. |
| **Queued delivery and cancellation — Existing text-only queue. Optional image extension in PR 7.** | **Direct observation:** `AgentSessionLinkPendingSend` owns one slot per exact link generation, revision-qualified replacement, commit cutoff, and reason-specific missed triggers.[^queue] | `send(delivery: "when_sendable")`, replacement, and `cancel_pending_send`. | Ephemeral; no queue restoration. Revocation/rebind/closing ends the entry. `committing` is too late to claim cancellation. | A readiness/ledger event racing a drain is not lost. Replacement and cancellation affect only the exact entry and observer lane. |
| **Tool reachability and trusted guidance — Existing. Reuse, with new-origin audit in PR 1.** | **Direct observation:** server-derived caller identity and exact-operation authorization are distinct from tool visibility; incoming content is not permission.[^mcp][^wake] | Existing Agent-origin MCP routing. A raw administrative CLI call is not automatically an authorized observer call. | No turn-origin gate is reintroduced. Guidance revisions continue to use existing context/receipt ownership. | A visible tool cannot act beyond its exact grant; target content and workspace membership cannot mint authority. |

### Optional extensions and verification

| Feature / present status / milestone | Owner and source evidence | User entry / agent drive / consent | States and persistence | Observable proof / prerequisites and traps |
|---|---|---|---|---|
| **Immediate linked-session images — Missing at link boundary; ordinary attachment substrate exists. Optional PR 6.** | **Direct observation:** attachment models/rows/run inputs exist; linked sends parse text only.[^attachments][^mcp-send] | Optional `send.images` local-image references. Requires both the direct send grant and ordinary source-file authorization. | Validated immutable image batch → target-owned files → attributed row → actual provider image input. No URL/base64 interface in the first version. | A provider correctly describes a neutral-filename pattern unavailable from the text; a stored path, thumbnail, or successful RPC is insufficient proof. |
| **Queued image ownership and cleanup — Missing. Optional PR 7.** | **Inference:** adding attachment references alone to the current queue would leave source-mutation and lifetime races unresolved.[^queue][^attachments] | Same queued-send operations; no new queue. | Freeze validated bytes once at admission. Release exact batches on replacement/cancel/revocation; transfer ownership at durable row acceptance. Pending batches do not replay after restart. | Deleting/editing the original file does not alter the queued payload. No stale drain deletes its replacement’s files. |
| **Workstream context — Partial context primitives; product extension. Optional follow-up.** | **Direct observation:** `waitingOn` is attributed, mutable target context and not observer instruction or authority.[^attention] | Core uses the observer’s own ordinary user instructions/workflows plus existing target waiting context. | No inferred task ledger, dependency graph, or automatic completion database. | Target statements remain distinguishable from the observer user’s actual assignment. |
| **Independent model configuration and Autostart — Product decisions, not core requirements. Optional follow-ups.** | **Direct observation:** ordinary startup uses the session’s selected provider/model/configuration; metadata persists corresponding configuration.[^attachments][^inventory] The draft’s extra proposals are a **discovery summary**. | Core uses the chosen observer session’s ordinary configuration. Autostart needs a separate opt-in with cost and startup-instruction semantics. | Core does not create a replacement observer or issue a startup prompt. | Restart does not unexpectedly select a different model, create an agent, or incur a new check solely because scope policy loaded. |
| **Shared QA/resource coordination — Existing per-job coordination; full-session coordination missing. Core documentation; optional tooling follow-up.** | **Direct observation:** conductor has current job lanes and provenance reporting; the shown provenance includes a dirty Boolean, not dirty-patch identity.[^qa] | Existing conductor commands and approved live CE MCP/UI procedures. | Core adds no lease service or sealed-source QA runtime. | Evidence identifies the actual build, scenario, approvals, and results. A multi-command QA session is not falsely claimed to be exclusively reserved by per-job locks. |
| **Truthful reporting and completion evidence — Existing pieces; feature-wide map missing. Core PR 4 documentation.** | **Direct observation:** receipt distinctions and Oracle image testing already separate transport success from meaningful proof.[^receipts][^testing] | Dashboard status, MCP result, test record, and review checklist. | Record observed facts; do not persist inferred success as authority. | “Enrolled,” “delivered,” “provider started,” “vision received,” and “task completed” each require their own evidence. |

# 3. Design

## 3.1 Product decisions: recommended branch and approval gates

These choices are resolved for the recommended implementation branch, but their approval is not established by the supplied evidence.

| Choice | Recommended core behavior | Tradeoff / approval boundary |
|---|---|---|
| Enrollment authority | Explicit workspace opt-in authorizes automatic **observation only** for the defined scope. | Requires real capability enforcement, provenance, and safe reconstruction. Do not ship a UI-only approximation. |
| Workspace scope | One configured observer session per workspace. Eligible targets are open compose-bound, top-level sessions in that same workspace across non-closing windows. “Open” does not mean `runState.isActive`. | Closed/stashed history is excluded. Broader historical supervision is a separate feature. |
| Existing and future targets | Enroll eligible existing sessions and subsequently opened/created eligible sessions. Passively hydrate eligible open background tabs where needed. | Consent must explicitly mention future sessions and reading their available transcript content. |
| Exclusion meaning | A workspace/target exclusion suppresses automatic enrollment until the user explicitly removes it. | It does not prohibit an independently authorized manual link. Keep exclusions through closing, reopening, and restart. |
| Existing direct grants | Preserve their actual capabilities and persistence. | The UI must not claim the entire workspace relationship set is read-only when manual managed links coexist. |
| Model selection | Reuse the selected observer’s existing Agent configuration. | No new role, router policy, or duplicate model setting in core. |
| Autostart | Excluded from core; scope reconstruction starts no provider run. | Existing later wake admission remains applicable and must be disclosed separately. |
| Shared QA | Core means coordinated existing validation jobs plus an explicit scenario/evidence checklist. | Exclusive ownership across an entire interactive QA session is optional tooling work, not an assumed current guarantee. |

**Fallback if observation-only authority is not approved:** keep the workspace UI observational as a selection/preview surface and require normal explicit Add for each actual relationship. Do not automatically create managed links as an undocumented substitute.

## 3.2 Authority extension: narrow capabilities and automatic provenance

### Capability set

Add a static `DomainAgentSessionLinkCapability.observationOnly` set containing exactly:

> `.poll`, `.wait`, `.read`

Do not change `.version1`, `.managed`, or the default arguments of existing manual reservation behavior.

`monitorSnoozeAutoWake` remains allowed because it maps to `.poll` and changes observer-local admission policy, not target state. `send`, `compact`, `respond`, `steer`, `stop`, and `retire_lane` remain denied without their existing capabilities. This follows the existing operation mapping rather than adding a second authorization table.[^capabilities]

### Process-local scope permit

**Proposal.** Add a small authority-owned workspace-observation permit to fence automatic reservation and activation.

A permit is needed because checking a MainActor configuration revision before awaiting the domain actor does not prove that the policy is still valid at activation.

New immutable package value:

- **Name:** `DomainAgentWorkspaceObservationPermit`.
- **Kind:** `Hashable`, `Sendable` struct; not `Codable`.
- **Fields:** opaque `id: UUID`, `workspaceID: UUID`, exact `observer: DomainAgentSessionLinkEndpointIdentity`.
- **Owner:** minted and validated only by `DomainAgentSessionLinkAuthority`.
- **Lifetime:** one enabled scope bound to one exact observer incarnation. Disable, observer drift, workspace teardown, or shutdown invalidates it.

The authority keeps one internal scope record per workspace with the current permit and excluded target UUIDs. This is execution-time fencing of the stored user policy, not another durable policy store.

Add internal actor operations with these interface shapes:

| New operation | Inputs and result contract |
|---|---|
| `installWorkspaceObservationScope` | Workspace UUID, exact observer, exclusion set → current/new permit or existing typed authority failure. Idempotent for an unchanged current scope. |
| `updateWorkspaceObservationExclusions` | Expected permit and replacement exclusion set → mutation result plus exact revocation notices. Stale permits do nothing. |
| `reserveWorkspaceObservationLink` | Expected permit and exact target → existing reservation disposition. Capability choice is not caller-selectable. |
| `revokeWorkspaceObservationScope` | Expected permit and lifecycle reason → exact notices for derived grants that were actually revoked. |

`reserveWorkspaceObservationLink` delegates to the same reservation machinery as ordinary links. It additionally verifies current permit, same workspace, exclusion absence, and the exact observer. It always requests `observationOnly`.

Add optional process-local automatic provenance to pending reservations and internal active-link records. `activateLink` keeps its external signature but rechecks the associated permit and exclusion before installing an automatic grant.

Expose automatic provenance through the **host-only** endpoint projection as a set of exact link references touching that endpoint. Do not serialize scope permits or provenance identifiers in model-facing responses.

### Existing direct relationships win

If the exact pair already has a direct live grant, automatic enrollment reports “covered by existing direct link” and leaves that grant untouched. It does not relabel the grant as automatic or take responsibility for revoking it.

If the manual intent store already contains the pair, automatic enrollment waits for or defers to the ordinary direct-link path—even when that direct link is not yet active. If that store cannot be read safely, pause automatic enrollment rather than treating its contents as empty.

This prevents a launch race in which automatic observation occupies a pair before its saved managed relationship restores.[^restoration][^authority]

### Prevent authority amplification

Two existing paths require an explicit audit and regression coverage:

1. **Lane creation.** The current lane-creation contract checks for an existing direct relationship, including an activation-time check. Automatically derived observation links must not satisfy that prerequisite. Preserve the behavior of all existing non-automatic links, including currently supported inbound/direct cases; do not globally redefine tool reachability.[^lanes][^authority]
2. **Fork/Handoff inheritance.** The bridge describes inheritance through ordinary durable Add. Exclude automatic-origin relationships from that inheritance input; otherwise copying them through managed-default Add could widen permissions and make them durable.[^bridge][^management]

Automatic observation is not a sandbox for the observer’s unrelated tools. Existing spawn-provenance permissions and independently granted direct links remain what they were. The guarantee is that **workspace enrollment itself confers no target-writing or authority-expansion capability**.

## 3.3 Durable policy and settings ownership

### New policy value

Create `AgentWorkspaceOverseerPolicy` as a `Codable`, `Equatable`, `Sendable` struct under Agent Mode models.

Its stored fields are:

| Field | Type | Meaning/default |
|---|---|---|
| `observerSessionID` | `UUID` | Required selected existing observer. Never silently replaced. |
| `enabled` | `Bool` | Missing field resolves to `false`; enabling requires explicit user action. |
| `excludedSessionIDs` | `Set<UUID>` | Missing field resolves to an empty set. Encode deterministically as sorted UUIDs. |

The workspace UUID is the dictionary key, not a duplicated field inside the policy.

Add optional `workspaceOverseerPoliciesByWorkspaceID` to `GlobalSettingsDocument`, keyed by UUID string. Absence means no configured workspace supervision.

Do **not** store:

- Derived link IDs, generations, endpoints, or permits.
- Copies of manual links.
- Runtime enrollment status or hydration attempts.
- Wake preferences already owned by sessions.
- Model selections already owned by the observer.
- Pending messages or provider outcomes.

### Settings interfaces

Extend the existing settings owner rather than creating a new settings singleton or persistence actor.

Add:

- A read accessor for a workspace’s policy.
- A MainActor mutation entry accepting workspace UUID, replacement policy, and expected process-local policy revision.
- A mutation receipt distinguishing `applied`, `unchanged`, `staleRevision`, `blocked`, and `writeFailed`.
- A policy-change observation using the settings owner’s established publication mechanism, emitted after the durable state is committed.

Update both `GlobalSettingsDocument.init` and `replacing` to carry the dictionary. Omitted replacement input preserves existing policies; an explicitly supplied empty dictionary clears them.

**Important validation gate:** the supplied settings call sites invoke `save()` but do not expose its write-result contract. Do not implement the new receipt by calling that method and assuming success. Locate the authoritative raw-preserving write boundary and propagate its actual result.[^settings]

### Compatibility boundary

Add a fixed feature-version constant for workspace Overseer policy, using the next unallocated schema boundary established against the implementation checkout. Do not hard-code a guessed version from the frozen baseline.

`requiredSchemaVersion` must include that boundary whenever any policy is retained, including a disabled policy containing exclusions. Unlike a display preference, silently dropping this group can destroy user consent or exclusions. The existing notification group’s schema-neutral treatment is not sufficient justification for this feature.[^settings]

New code reading old documents obtains no policies and performs no automatic enrollment. Malformed or unsupported policy data disables automatic action while preserving the source document through the existing settings safety behavior; it must not be silently rewritten as an empty policy set.

### Ordering of user actions and durable writes

Use asymmetric ordering because granting and withdrawing access have different safe failures:

| Action | Required ordering |
|---|---|
| Enable supervision / remove an exclusion | Commit policy successfully → publish new policy revision → install/update authority scope → reconcile eligible links. A failed save grants nothing new. |
| Disable / exclude / unlink an automatically enrolled pair | Install immediate MainActor suppression → invalidate the applicable authority scope or target admission → revoke derived grants → persist policy. A failed save leaves current-process suppression in place and shows that restart persistence is not confirmed. |
| Retry saving a withdrawal | Retry only the exact current requested policy revision. Do not replay an older failed withdrawal over a later explicit user action. |
| Change selected observer | Suppress and retire the old derived scope; persist the explicit replacement; establish the new scope only after durable success and exact readiness. Manual links are unaffected. |

For a failed withdrawal save, use accurate UI wording such as “Stopped for this launch; the saved setting could not be updated.” Do not quietly re-enable the scope by restoring the previous in-memory setting.

## 3.4 Event-driven workspace coordinator

### Ownership and state

Create `@MainActor final class AgentWorkspaceOverseerCoordinator`, owned once by the process-wide composition root alongside the link runtime bridge.

It owns only enrollment orchestration:

- Current settings policy/revision per workspace.
- Current domain permit, if any.
- Per-target in-flight attempt identity and observed endpoint.
- One retained drain task and dirty state.
- Process-local suppression for unsaved withdrawals.
- Hydration-request bookkeeping qualified by the current scope and binding.
- Derived presentation counts and row outcomes.

It does not own capabilities, transcript queues, wake admission, provider tasks, or authoritative session inventory.

Use a closed presentation phase set:

- `disabled`
- `waitingForWorkspace`
- `waitingForObserver`
- `reconciling`
- `active`
- `blocked(reason)`
- `suppressed`

Scope-level block reasons are `settingsUnavailable`, `directIntentStoreUnavailable`, `ambiguousObserver`, and `observerIneligible`. Individual unavailable targets remain row outcomes, not whole-scope failures.

### Inputs

Reconciliation is triggered by:

- A committed policy change or an immediate withdrawal suppression.
- Workspace activation/deactivation and discovery readiness.
- Compose binding creation, removal, rebind, and hydration completion.
- Session deletion and observer eligibility changes.
- Relevant direct-intent mutation receipts.
- Authority activation/revocation results affecting the scope.

Use the existing host/index notification paths. Do not drive enrollment from token streaming, transcript text changes, or a timer.

### Reconciliation algorithm

1. Read the latest effective policy plus unsaved withdrawal suppression.
2. Require a current workspace owner/discovery state. An unready empty projection means **wait**, not “remove everything.”
3. Resolve the configured observer to one exact eligible top-level endpoint. Ambiguity fails closed.
4. Capture current compose descriptors and live candidates once. Build lookup maps for workspace/session/binding identity.
5. Select eligible open same-workspace targets, excluding semantic self, children, closing/deleted endpoints, and durable/process-local exclusions. Reuse the existing endpoint resolver’s readiness and eligibility checks.
6. Remove pairs covered by direct durable intent or existing direct live grants from automatic creation.
7. For eligible described-but-unhydrated open tabs, request the existing passive hydration path. Never create/open a tab or connect a provider.
8. Reserve and activate missing automatic links serially through the bridge’s shared endpoint/seed/activation machinery.
9. After every await, compare scope revision, attempt identity, exact endpoint, and permit currency before using results.
10. Publish one coalesced presentation update. If an input changed while suspended, drain another pass from current state.

The normal pass should be linear in the captured descriptor/candidate/link population, apart from deterministic ordering. Do not perform a registry scan or metadata refresh separately for each target.

**Direct observation basis:** the existing lightweight host projection and coalesced index publication deliberately avoid repeated transcript/redaction work.[^bridge][^inventory]

### Out-of-order and dropped events

Events are invalidation signals, not authority-bearing deltas. Duplicate signals coalesce; stale asynchronous results compare out. A signal arriving during a pass leaves the dirty state set so the pass cannot lose the change.

Authority mutation returns and direct-intent receipts must update local bookkeeping directly rather than relying exclusively on a potentially coalesced change feed. The domain permit closes the reservation/activation race even when a UI projection is temporarily stale.

Do not retry a terminal hydration failure on every unrelated event. Retry requires a meaningful changed binding/readiness fact or an explicit user action; no retry timer is added.

### Startup and lifecycle

Keep `AgentSessionOversightLaunchCoordinator` bounded and unchanged in purpose. Do not add workspace policies to its pair worklist.

The new coordinator may activate only scopes whose already-open workspace and configured observer are ready. With automatic window restoration disabled, the feature opens nothing; it can become effective when the user subsequently opens the configured workspace/observer. Persistence-suppressed launch modes must not load or write production policy.

Closing/rebinding an automatic target revokes its exact grant but does not create a durable exclusion. Reopening it can enroll it again because that is the explicitly chosen workspace policy. This is distinct from the launch coordinator’s never-requeue rule for ordinary restored pairs.[^restoration]

A missing or deleted observer does not trigger observer recreation or model fallback. Preserve configuration and show an actionable unavailable state.

## 3.5 Bridge, explicit linking, and UI integration

### Shared establishment seam

Add an internal bridge entry for workspace observation. It receives the domain permit and exact endpoint candidates and returns the existing establishment result shape.

Factor or reuse only the common:

> endpoint proof → snapshot seed → reservation → activation → observation installation → projection publication

Keep durable directed-intent insertion **outside** the automatic path. An automatic lifecycle revocation must not call pair removal as though it owned a manual intent token.

Before extracting code, inspect the complete bridge implementation: the supplied excerpt contains host interfaces but not the establishment body. The required separation is specified here; an implementer should not duplicate the transaction because its private helper name is absent from the excerpt.

### Explicit conversion to a direct link

When a user explicitly chooses the normal managed/direct Add action for an automatically observed pair:

1. Record an automatic-enrollment exclusion for that target and apply its scope fence.
2. Revoke the exact automatic generation through the authority.
3. Execute the ordinary durable Add transaction.
4. Report the actual resulting capabilities and persistence outcome.

If exclusion succeeds but Add fails, leave the target excluded and show the failure. Recovery is explicit Retry Add or Include Automatically. Do not silently reinstall observation behind the failed managed action.

Use the bridge’s existing pair retirement/serialization discipline so a suspended cleanup cannot delete the newly asserted direct intent.[^restoration]

For existing non-automatic restricted grants, preserve idempotent Add behavior. Do not reinterpret their capability set as evidence that they are automatically derived.

### User controls and presentation

Extend the current toolbar/dashboard, after locating `AgentMonitorPill` and its binding owner:

- Enable/disable workspace supervision for the selected session.
- Display the configured observer and exact workspace.
- Show automatic observation separately from direct links.
- Show counts for observed, direct-linked, excluded, waiting, and unavailable targets.
- Provide Exclude/Include for automatic enrollment.
- Preserve existing explicit Add, Unlink, persistence warnings, and wake controls.

Do not introduce a generic “Manage” toggle that pretends to mutate immutable grant capabilities. The conversion action creates a different grant generation.

The opt-in explanation must state:

- Which workspace and observer are selected.
- That existing and future eligible open sessions can be read.
- That automatic links cannot write to those targets.
- That existing direct permissions remain unchanged.
- That genuine updates/attention can invoke existing wake behavior and consume model usage.
- That disabling workspace supervision removes automatic links, not independent manual links.

## 3.6 Wake, instructions, and completion semantics

Do not add a workspace wake scheduler or broaden periodic waking. Preserve current master/per-lane selection, snooze, routine interval, exact purposeful-attention exception, and physical-dispatch limitations.[^wake]

Initial enrollment establishes a baseline. It does not fabricate attention, a target state transition, a user instruction, or a first-run prompt. Later legitimate observations enter the existing pipeline.

Workspace consent grants the structural ability to observe. It does **not** invent the observer’s task. The observer’s own user still supplies the current or standing instruction; target text, prompts, and `waitingOn` remain untrusted task data.[^mcp][^attention]

Use the following reporting distinctions throughout the UI, MCP documentation, and QA record:

| Claim | Required evidence |
|---|---|
| Enrolled | An activated exact grant, not merely desired membership or a saved policy. |
| Managed | The current exact grant contains `.manage`, not a role label or historical relationship. |
| Delivered | The returned delivery outcome and its target item identity. |
| Provider started | A delivery/start outcome that actually establishes provider startup—not persisted-only acceptance. |
| Image received | Actual provider image-input evidence plus content-dependent response evidence. |
| Task completed | The requested deliverable/check was observed; a successful send or an idle lane does not establish it. |

Do not add a new durable “complete” flag inferred from assistant prose or run idleness.

## 3.7 Optional extension: safe actionable tool diagnostics

Keep this independent of workspace enrollment.

Add an optional structured diagnostic to `AgentSessionLinkTranscriptItem`, emitted as a separate `tool_diagnostic` field rather than reopening raw tool `text`, arguments, or results.

Recommended first implementation:

- Accept only recognized **app-generated structured outcome codes**, initially from the linked-session operations whose outcomes are already typed.
- Render recovery text from the existing outcome definitions or a shared typed mapping.
- Do not copy arbitrary `error.message` text from provider/tool JSON.
- Unknown tools, malformed payloads, unsupported codes, and unavailable restored metadata produce no diagnostic.
- Preserve the distinction between an operational refusal and a failed tool invocation; a completed tool call returning `target_busy` must not become a failed target run.
- Redact and cap the diagnostic using the existing diagnostic text budget.
- Include diagnostic bytes in page accounting and first-item truncation behavior.

This intentionally does not promise universal diagnostics or guaranteed reconstruction after restart. If a later requirement demands durable diagnostic metadata, extend the existing canonical tool-event/persistence owner after inspecting it; do not persist a parallel oversight log.

**Basis:** the current sanitizer’s structural stripping is stronger than general runtime tool-result retention and must remain so.[^sanitizer]

## 3.8 Optional extensions: immediate and queued images

### API boundary

First add images only to `send`, not `steer`, `create_lane`, `respond`, or `compact`.

The additive request shape is:

> `images`: ordered local-image references, each with `path` and optional `title`.

Keep `message` required. Absence or an empty image list preserves current text-only behavior. Reject URLs, inline base64, and unsupported descriptor keys.

Update:

- `executeSend` allowed keys and syntax parsing.
- Canonical tool definitions and guidance.
- `bridge.send` and later `bridge.queueSend`.
- `AgentSessionLinkSendRequest`.
- The existing send digest construction.
- Source-tool argument persistence redaction.

No new MCP tool is required.

### Safe preparation and idempotency

The sequence is:

> Syntax validation → exact grant/endpoint authorization → idempotency replay/conflict handling → source-file authorization → bounded image validation/read → app-owned immutable copy → endpoint/readiness revalidation → existing target delivery transaction.

Reuse the verified Oracle/local-image authorization and validation machinery **after locating its actual owner**. The supplied `AgentAttachmentStore` is a copying primitive, not a sufficient MCP ingestion boundary.[^attachments]

Do not invent new arbitrary image limits. Adopt the existing applicable image-input limits after verifying their definitions and enforce aggregate request work, not just individual files.

Request identity includes the ordered canonical image descriptors, message, and canonical workflow selector. Text-only digests remain byte-compatible. Under a reused key, a changed file at the same path does not request a new delivery: the existing frozen request/outcome wins. A genuinely new image version needs a new key. Record content hashes internally for immutable-batch integrity; they are not a reason to reread files on duplicate retries.

### Provider admission

Before staging a target row, establish support using the ordinary provider/model capability source. Unknown or unsupported image transport fails closed; never silently send text only.

Recheck the exact relevant provider/model binding after preparation suspensions. Do not infer support merely because `startRun` accepts `[AgentImageAttachment]`.

For PR 6, enable only provider routes whose actual input transport has been inspected and covered. Retain the active-ACP text-only restriction; image steering is not part of these PRs.[^attachments]

### File ownership and restart

Use a typed prepared-image batch with immutable batch identity and attachment metadata. The transaction or queue owns the batch until durable row acceptance; the target row then owns the durable files.

Recommended storage distinction:

- A dedicated app-owned staging namespace for unaccepted linked-send batches.
- A durable namespace keyed by target session and row identity for accepted attachments.

A durable transcript row must never reference the staging namespace. Ordinary `clearConsumedLocalFiles` must not delete durable linked-row assets merely because one provider submission consumed them.

Cleanup rules:

- Preparation failure/refusal: remove only that unaccepted batch.
- Confirmed persistence rollback: release its files.
- Indeterminate persistence: retain potentially referenced files and spend the key.
- Persisted-only or run-start failure: retain row-owned files.
- Queue replacement/cancel/revocation: release only the exact old batch after suspended users relinquish it.
- Session/row deletion: use the existing deletion/persistence lifecycle, after pending provider references have settled.
- Restart: discard previous-process staging only when it is structurally impossible for durable rows to reference it. Reconcile orphan durable batches only against a fully loaded authoritative session or committed deletion—not an incomplete metadata index.

This chooses durable target-owned attachment files for Agent history; it does not incorrectly assume Agent attachments already have Oracle’s thumbnail-only history contract.[^attachments][^testing]

### Queue extension

PR 7 extends the existing `AgentSessionLinkPendingSend`; it creates no second queue.

Freeze image bytes at queue admission. Do not reread the caller’s original files at drain time. Preserve slot arbitration, revision comparison, commit cutoff, park reasons, and missed-trigger handling.

While pending, a batch is bound to the exact original grant and endpoints. Restart does not restore it. Disk usage grows with accepted pending batches; keep reads/preparation bounded and serial, and make retained-resource counts observable without adding an arbitrary link-count cap.

### Privacy and proof

Extend `AgentToolArgumentPersistencePolicy` to remove image descriptors from linked-send tool arguments, including supported canonical/prefixed tool names and malformed-payload fail-closed handling.

Keep provider framing unchanged: images are a separate input channel, not paths interpolated into a message that pretends to be the target’s own user.

Real acceptance requires the existing image-testing discipline: an approved supported route, a neutral fixture with content not disclosed by prompt/name/title, an actual content-dependent answer, durable history inspection, and rejected unauthorized-source input with no new target row.[^testing]

## 3.9 Optional workstream, model, Autostart, and QA scope

**Workstream context:** core reuses ordinary user instructions, workflows, target `waitingOn`, and authorized transcript reads. Defer a structured task/dependency store. A later context editor must identify user-authored instructions separately from target-derived context; it must not infer tasks or approvals from observations.

**Independent model selection:** use ordinary configuration of the designated observer session. Do not add a second workspace model setting that can diverge from the session’s selected provider/model. A dedicated Overseer role is a separate product choice requiring catalog/settings inspection.

**Autostart:** remain off and absent from core. A later approved definition should mean one ordinary, user-instructed check per eligible launch, after readiness, without recreating the observer, interrupting a run, or answering a prompt. It needs its own explicit cost consent and existing provider-acquisition fences; it is not an extension of passive hydration.

**Shared QA:** extend current documentation first. If an exclusive whole-scenario reservation is later required, prefer one bounded opt-in conductor smoke scenario owning the existing relevant resources. Do not create a parallel QA daemon. Inspect the actual smoke/lock implementation before promising cross-worktree exclusivity, and avoid nested child jobs that deadlock by reacquiring their parent’s held lanes.[^qa]

Improved dirty-patch provenance can be an independent tooling change. The current dirty Boolean cannot establish that the tested artifact matches the reviewed dirty source. No sealed-source QA subsystem is required for basic supervision.

## 3.10 Maintainer-guidance check

| Check | Assessment |
|---|---|
| User impact and invariant | Observe eligible workspace sessions automatically only after scope consent; never silently confer target-write authority or lose an exclusion. |
| Root-cause confidence | **Confirmed architectural gap**, not a reproduced runtime defect: current persistent intent is pair-only and normal reconstruction is managed-default. |
| Authority | Domain actor owns grants/fences; settings own workspace policy; existing index/host own inventory and bindings; existing wake/delivery owners remain separate. |
| State safety | Highest risks are managed restoration of automatic pairs, stale exclusion writes, conversion races, and cleanup deleting newer grants or image batches. |
| Scale and observability | Coalesced event-driven enrollment, shared inventory capture, lightweight status rendering, explicit waiting/save-failure states. |
| Recommended scope | Core PRs 1–4 after policy approval; diagnostics/images/workstream/model/Autostart/expanded QA remain independent. |
| Validation boundary | Deterministic authority/settings/coordinator tests first, followed by approved real-app multiwindow and Agent-origin MCP acceptance. |

This follows the supplied guidance on one authority, bounded work, visible asynchronous state, safe persistence, and staged scope.[^guidance]

## 3.11 Evidence confidence and unresolved source locations

| Evidence class | What may be relied on | What remains to validate |
|---|---|---|
| Direct frozen source | Capability defaults and immutability, pair-only persistence, launch coordinator boundaries, target-send ordering, queue state, attachment shapes, index epochs, current conductor lane assignment. | Complete call sites and integration bodies outside the excerpts. |
| Architecture document | Current intended trust, management, attention, wake, and periodic behavior. | Any implementation/document disagreement found during PR 0; executable source and tests settle it. |
| Discovery summaries | Current UI entry summary; issue draft’s model/Autostart proposals; reported dirty checkout baseline. | Actual UI path and bindings, exact draft purpose/content, current repository status. |
| Oracle suggestions | Research leads only. | No omitted Oracle claim is treated as source proof; the completed lane was coverage-limited and the other timed out. |
| Upstream/fork issue leads | Candidate comparison targets supplied by the user. | Their contents, current states, applicability, and landed code are unverified here. They do not determine this plan. |
| Product choices | The recommended branch in §3.1. | Approval for automatic observation consent/scope, exclusion behavior, and any optional extension. |

PR 0 must locate the exact implementations of:

- `AgentMonitorPill` and its current actions/bindings.
- `AgentSessionLinkEndpointHost` conformance and process-wide composition owner.
- Complete bridge Add/restore/revoke and fork-inheritance paths.
- `AgentSessionLinkEndpointResolver` and restoration-proof production.
- Settings authoritative write acknowledgement and raw-preserving compatibility handling.
- Canonical MCP definitions, tool policy, and prompt-guidance owners.
- Oracle/local-image loader, provider capability source, physical image codecs, and attachment deletion/replay lifetimes.

These are source-validation tasks for the implementer, not questions to send back to the user.

# 4. File-by-file impact

## 4.1 Supplied and new production files

New paths below are proposed placements. Existing cited paths are from the frozen selection.

| File | Change and reason | Dependencies |
|---|---|---|
| `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkModels.swift` | Add `observationOnly`, the process-local workspace permit value, optional automatic reservation provenance, and host-projection provenance fields. Keep existing capability cases and wire names unchanged. | First core authority PR. |
| `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift` | Own scope permits/exclusions; add restricted automatic reservation; recheck permit at activation; atomically invalidate pending/active derived grants; make lane-creation qualification exclude automatic-only authority. Reuse reservation, revocation, and publication machinery. | Models above. |
| `Sources/RepoPrompt/Features/AgentMode/Models/AgentWorkspaceOverseerPolicy.swift` **(new)** | Policy value, checked mutation outcome, and minimal presentation value types. No runtime grants or provider state. | Independent model addition. |
| `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift` | Add workspace policy dictionary, deterministic conversion, init/replacement plumbing, and fixed feature compatibility boundary. | Policy value. |
| `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsManager.swift` | Add policy access/CAS mutation and post-commit publication through the existing settings owner. Propagate real persistence failure. | Document plus validated writer seam. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentWorkspaceOverseerCoordinator.swift` **(new)** | Event-driven scope reconciliation, exact attempt ownership, hydration requests, withdrawal suppression, and coalesced presentation. | Authority, policy persistence, host integration. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkRuntimeBridge.swift` | Add automatic establishment entry; share endpoint/seed/activation work without durable pair insertion; route automatic provenance and revocations; integrate exclusion-aware manual actions; filter automatic fork inheritance. Extend host seam only where the current implementation lacks the required signal/projection. | Authority and coordinator contracts. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/WorkspaceLifetime/AgentWorkspaceSessionIndexStore.swift` | Add only the minimum committed-state/readiness notification needed by enrollment, if the current delegate publication cannot already supply it. Preserve ownership and coalescing. Do not move refresh flow into the coordinator. | Host/coordinator integration. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkTranscriptSanitizer.swift` | **Optional PR 5:** add structured safe diagnostics, byte accounting, and paging/truncation integration. | Validated typed diagnostic source. |
| `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift` | Core: inspect lane-creation preflight integration; no new workspace-management op. **Optional PRs 5–7:** diagnostic serialization and `send.images` syntax/dispatch plumbing. | Corresponding runtime changes and canonical definitions. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkSendTransaction.swift` | **Optional PR 6:** additive image references/prepared attachment metadata and digest input. Preserve text-only digest and framing behavior. | Validated image preparation type. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentModeViewModel+SessionLinkSend.swift` | **Optional PR 6:** attach the prepared batch to the durable attributed row and ordinary run input; preserve all pre/post-await fences and rollback outcomes. | Prepared-image storage and provider admission. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkImagePreparation.swift` **(new, optional)** | Link-specific orchestration/value types over the verified existing loader and attachment store. No independent general image decoder or source authorization implementation. | Loader/capability/lifetime source validation. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentAttachmentStore.swift` | **Optional PR 6:** support validated batch import and explicit staging/durable ownership; prevent consumed-file cleanup from removing row-owned assets. | Existing cleanup callers must be identified before changing semantics. |
| `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift` | **Optional PR 6:** redact linked-send image arguments. Reuse existing `attachments` and attribution fields; add no row schema merely to carry existing attachments. | MCP image request contract. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkPendingSend.swift` | **Optional PR 7:** retain immutable image batch identity/metadata and exact cleanup ownership. Preserve phase, slot arbitration, and missed-trigger behavior. | Immediate-image lifetime contract. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift` | **Optional image audit:** reuse attachment forwarding. Modify only if a verified capability/refusal or ownership handoff is missing. Do not remove the active-ACP attachment restriction in these PRs. | Actual provider transport inspection. |

### Deliberately unchanged core owners

`AgentSessionOversightIntentStore.swift` retains its pair-only schema and normal manual semantics. `AgentSessionOversightLaunchCoordinator.swift` retains its fixed launch worklist. `AgentSessionMetadataIndex.swift` remains a projection and needs no workspace-policy schema. `DomainAgentSessionOperationAuthorizer.swift` retains existing operation/capability mapping unless inspection identifies a concrete lane-preflight call-site adjustment.

The passive reducer, prompt claim/receipt machinery, target interaction responder, and send queue need no core supervision redesign.

## 4.2 Required integration files outside the selection

The exact paths cannot be established from the supplied tree. PR 0 must record them before implementation:

| Existing owner/symbol | Required integration |
|---|---|
| Process composition root / host conformance | Own one coordinator; forward workspace/binding/deletion/shutdown signals; publish derived presentation; reuse passive hydration without focus/provider side effects. |
| `AgentMonitorPill` and action owner | Consent UI, automatic/direct labels, scope controls, durable exclusion handling, and existing Add/Unlink conversion behavior. |
| Complete `createLane` and inheritance implementations | Ensure automatic-only relationships cannot satisfy management-expanding prerequisites. |
| `MCPDomainCanonicalToolDefinitions`, `AgentSessionLinkPrompts`, catalog/policy owners | Optional image schema and safe diagnostic documentation; core guidance must truthfully describe actual narrow grants. |
| Settings writer/backend | Authoritative commit receipt and future-schema/raw-data preservation. |
| Physical provider input and attachment lifecycle owners | Optional image capability proof, consumption lifetime, replay, and deletion cleanup. |

Do not create replacement files with guessed names to avoid inspecting these existing owners.

## 4.3 Tests and documentation

Add or extend focused suites at these **proposed** paths, consolidating with equivalent existing tests when PR 0 finds them:

- `Tests/RepoPromptDomainRuntimeTests/DomainAgentWorkspaceObservationTests.swift`
- `Tests/RepoPromptTests/Settings/WorkspaceOverseerPolicyPersistenceTests.swift`
- `Tests/RepoPromptTests/AgentMode/SessionLinks/AgentWorkspaceOverseerCoordinatorTests.swift`
- `Tests/RepoPromptTests/AgentMode/SessionLinks/AgentWorkspaceOverseerIntegrationTests.swift`
- Optional `AgentSessionLinkToolDiagnosticTests.swift` and `AgentSessionLinkImageDeliveryTests.swift` in the same SessionLinks test directory.

Update:

- `docs/architecture/agent-session-oversight-auto-wake.md`: scope-derived authority, exclusions, provenance, and unchanged wake/delivery boundaries.
- `docs/testing.md`: workspace-supervision feature map, real-app acceptance, and optional image route evidence.
- A local plan under `docs/plans/` only after reading any existing candidate document and establishing its purpose. Do not overwrite the issue draft.
- `Scripts/conductor.py` only for an independently approved bounded QA/provenance extension, not as a dependency of supervision.

# 5. Risks and migration

## Permission and restoration risks

The highest-risk failure is an automatic pair entering ordinary directed-intent persistence and returning as managed. Protect the boundary structurally: automatic establishment accepts a scope permit, cannot insert direct intent, and is tested across restart.

A second risk is authority amplification through lane creation or inheritance. Capability denial on `send` alone is insufficient; both paths require explicit automatic-origin tests.

A third risk is an idempotent manual Add returning an existing automatic grant without actually granting the user’s requested management. The explicit conversion transaction must report its real outcome and mint a fresh generation.

## Settings and rollback

Consent-bearing policies need a compatibility boundary that older unsafe writers will not silently erase. A rollback build may therefore be unable to edit the newer settings document. Preserve the document and explain that limitation; do not automatically strip the new group to make rollback appear successful.

Because derived links never enter `agentSessionOversightLinks.json`, an older build cannot reconstruct those automatic relationships as managed links through that file.

A failed Disable/Exclude write is a partial result: authority can already be withdrawn for this launch while durable policy remains unchanged. Keep that distinction visible and retain retryable current intent.

## Lifecycle and concurrency

Scope invalidation and activation must be ordered in the authority actor. A MainActor check alone cannot close the suspension gap.

Never revoke by session UUID when an exact reference is available. Stale cleanup, multiwindow duplicate bindings, and explicit re-add all require generation-qualified comparisons.

Cancellation stops new enrollment work and abandons only owned pending reservations. Already committed direct deliveries retain the existing transaction semantics; scope controls must not claim to cancel a physical provider call already in flight.

## Image rollback and resource risks

Optional image support introduces durable resource ownership. Persistence-indeterminate rows must retain potentially referenced files. Queue replacement must not release another revision’s resources. Older builds should remain able to read the existing attachment representation, but correct file retention must be proven against their lifecycle expectations rather than assumed from `Codable` compatibility.

# 6. Implementation order

## PR 0 — Freeze the implementation surface and approval record

1. Establish actual branch, commit, dirty changes, existing plan/draft contents, and exact omitted owner paths.
2. Record the approved policy branch from §3.1; do not treat historical Oracle output or issue leads as approval.
3. Locate existing direct/outcome tests and settings/provider/host seams.
4. Preserve unrelated dirty work and leave public issue `dsebban/repoprompt-ce#10` unchanged.

**Evidence:** a source/call-site matrix and documented acceptance scenarios. No experiments, live-app changes, or provider calls are needed for this planning stage.

## PR 1 — Enforce observation-only authority and provenance

**Owner/seam:** domain models/authority, lane-creation prerequisites, and inheritance input.

**Deliverable:** narrow capability set, process-local scope permits, automatic provenance, and exact invalidation. Keep the feature unreachable from user UI until the remaining core PRs land.

**State safety:** no persisted format changes; existing direct/default behavior remains unchanged.

**Concurrency:** pause reservation/activation using deterministic gates and invalidate the permit or exclude the target while suspended.

**Focused evidence:**

- Automatic grants allow the intended reads and deny every target-writing operation.
- `.version1` and `.managed` retain their existing behavior.
- Stale permits/reservations cannot activate.
- Automatic-only relationships cannot create managed lanes or become managed through inheritance.
- Revoking one scope does not revoke direct links or another observer’s grants.

**Real-app acceptance:** existing manual Add/read/send/respond behavior remains unchanged under approved Agent-origin MCP smoke. Do not add paid traffic merely to test pure capability decisions.

## PR 2 — Persist workspace policies without losing consent or exclusions

**Owner/seam:** policy model, settings document, authoritative settings write path.

**Deliverable:** deterministic policy storage, checked mutation receipts, revisions, and compatibility fencing; still no automatic enrollment UI.

**Migration/rollback:** old data yields no policy; new meaningful policy requires the fixed feature boundary; failed/unsupported reads preserve data.

**Concurrency:** competing window edits use expected revisions. Failed withdrawal writes preserve process-local suppression once the coordinator is integrated.

**Focused evidence:**

- Old-document decode produces disabled/unconfigured supervision.
- Disabled policies retain exclusions.
- Init/replacement/save round-trips preserve unrelated settings and unknown data according to the existing backend contract.
- Write failure cannot be reported as applied.
- A stale settings write cannot overwrite a newer user action.

**Real-app acceptance:** approved settings persistence/relaunch inspection; no provider startup.

## PR 3 — Add the event-driven runtime, initially without enablement UI

**Owner/seam:** new coordinator, bridge establishment, host/index signals, exact hydration.

**Deliverable:** scope reconciliation against injected or test-controlled policies; no production opt-in surface yet.

**State safety:** automatic paths never insert direct intent. Manual intent takes precedence. Shutdown/observer drift invalidates permits and cancels owned work.

**Concurrency/scale:** one process-wide drain, captured inventory maps, coalesced publication, and exact attempt comparisons. No periodic scans.

**Focused evidence:**

- Existing/new eligible targets enroll; children, exclusions, self, and closed history do not.
- Unready empty index does not cause deletion or a false empty success.
- Duplicate bindings fail closed.
- Hydration and activation results from an old workspace epoch are ignored.
- Disable/exclusion racing activation leaves no surviving derived grant after the authority fence.
- Repeated events do not duplicate reservation or hydration work.

**Real-app acceptance:** approved non-provider inspection of two-window topology, passive background hydration, and no focus changes.

## PR 4 — Expose consent-aware supervision and complete core acceptance

**Owner/seam:** existing toolbar/dashboard, user-action routing, launch composition, documentation.

**Atomic requirement:** user enablement must land together with exclusion-aware Unlink/Disable and explicit direct-link conversion. Do not expose automatic enrollment while ordinary Unlink can silently be undone by reconciliation.

**Deliverable:** useful basic supervision, visible partial states, accurate permission labels, and the feature-wide verification map.

**Focused evidence:**

- Enable/save failure creates no new access.
- Exclude/disable save failure stops current-process access and displays unsaved state.
- Explicit conversion creates a fresh direct generation without touching another observer.
- Direct links survive scope Disable.
- No startup prompt or fabricated attention is generated by enrollment.

**Real-app/MCP acceptance:** with approved lifecycle/provider actions, exercise existing target enrollment, a newly opened target, exclusion, close/reopen, two windows, observer rebind, restart, explicit management conversion, and scope Disable. Drive observer operations through a real server-resolved Agent context; an administrative CLI request is not a substitute for that authority path.

At this point the feature is complete enough to ship without the optional PRs below.

## PR 5 — Add bounded safe tool diagnostics

**Dependency:** independent of core enrollment.

**Owner/seam:** sanitizer, typed outcome mapping, MCP transcript renderer.

**State safety:** optional projection field; no raw-result or log fallback and no new persistence store.

**Focused evidence:** known operational refusal → correct bounded recovery; malformed/untrusted payload → no detail; secret-rich inputs remain absent; paging budgets and cursor progress remain correct.

**Real acceptance:** a known safe tool refusal is inspectable through authorized `read`; no target-run failure is fabricated.

## PR 6 — Add immediate linked-session images

**Dependency:** source-file authorization, actual provider capability/transport, and lifetime owners must be source-closed first.

**Owner/seam:** MCP send parsing, bridge preparation, attachment storage, existing target transaction.

**State safety:** existing row attachment schema; source descriptor redaction; explicit staged/durable ownership and indeterminate retention.

**Focused evidence:** unauthorized input and duplicate retries perform no source read; unsupported transport stages no row; successful delivery passes the exact immutable image input; persistence and endpoint races preserve existing delivery truth.

**Real acceptance:** reuse the approved Oracle-image proof discipline for each supported Agent route, including visual-content proof, target-history inspection, and unauthorized-source rejection.

## PR 7 — Extend the existing queued send to images

**Dependency:** PR 6’s immutable batch and cleanup contract.

**Owner/seam:** `AgentSessionLinkPendingSend` and its existing bridge drain/settlement paths.

**State safety:** pending image batches remain nonpersistent; durable row ownership begins at the existing acceptance boundary.

**Focused evidence:** replacement, cancellation, revocation, source mutation, commit cutoff, missed readiness/ledger triggers, and stale-batch cleanup.

**Real acceptance:** queue while busy, remove the original source, then verify exact later image delivery. Verify canceled/replaced images never reach the provider.

## Subsequent independently approved PRs

Treat each as a separate scope, not one combined “advanced Overseer” change:

1. Workstream context UI using explicit user-authored context, without a speculative task engine.
2. Model UX reusing the designated observer’s existing configuration.
3. Default-off Autostart with explicit startup instruction and cost consent.
4. Bounded conductor QA-scenario coordination and/or stronger build provenance.

Each requires its own source-bound owner list and acceptance condition before implementation; none blocks core supervision.

## Validation and handoff discipline

Use the repository’s coordinated focused tests, relevant broader target tests, style checks, and real CE MCP/UI acceptance. Prefer deterministic gates over sleeps. Follow `AGENTS.md` for formatting, contribution preflight, and explicit approval immediately before visible lifecycle changes or paid/uploading provider work.[^testing][^qa]

For every acceptance scenario, record one of **PASS**, **FAIL**, **NOT RUN**, or **INCONCLUSIVE**, with the exact observation supporting it. A green helper test, successful RPC, persisted row, or provider acknowledgement must not be substituted for a different feature’s completion proof.

---

[^authority]: `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift:1-40`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift:275-465`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkModels.swift:1-570`.

[^capabilities]: `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkModels.swift:1-570`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionOperationAuthorizer.swift:1-180`.

[^restoration]: `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionOversightIntentStore.swift:1-320`; `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionOversightLaunchCoordinator.swift:1-420`.

[^management]: `docs/architecture/agent-session-oversight-auto-wake.md:202-300`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift:275-465`.

[^mcp]: `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:1-185`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionOperationAuthorizer.swift:1-180`.

[^mcp-send]: `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:1080-1185`.

[^delivery]: `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentModeViewModel+SessionLinkSend.swift:1-300`; `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkSendTransaction.swift:1-320`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift:1350-1570`.

[^receipts]: `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:2040-2090`; `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkSendTransaction.swift:1-320`.

[^wake]: `docs/architecture/agent-session-oversight-auto-wake.md:1-132`; `docs/architecture/agent-session-oversight-auto-wake.md:606-632`.

[^attention]: `docs/architecture/agent-session-oversight-auto-wake.md:382-435`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkModels.swift:1-570`.

[^inventory]: `Sources/RepoPrompt/Features/AgentMode/Runtime/WorkspaceLifetime/AgentWorkspaceSessionIndexStore.swift:1-320`; `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionMetadataIndex.swift:1-220`; `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionMetadataIndex.swift:400-455`.

[^bridge]: `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkRuntimeBridge.swift:1-220`; `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkRuntimeBridge.swift:350-620`.

[^lanes]: `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift:510-625`; `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkRuntimeBridge.swift:1-220`; `Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift:275-465`.

[^queue]: `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkPendingSend.swift:1-280`.

[^sanitizer]: `Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkTranscriptSanitizer.swift:1-530`.

[^attachments]: `Sources/RepoPrompt/Features/AgentMode/Models/AgentAttachments.swift:1-44`; `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentAttachmentStore.swift:1-102`; `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift:110-355`; `Sources/RepoPrompt/Features/AgentMode/Models/AgentChatModels.swift:553-617`; `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift:140-430`; `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentModeRunService.swift:560-640`.

[^settings]: `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift:1-170`; `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift:640-820`; `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsManager.swift:620-780`.

[^qa]: `Scripts/conductor.py:1-80`; `Scripts/conductor.py:3520-3610`; `Scripts/conductor.py:7540-7630`; `AGENTS.md:1-305`.

[^testing]: `docs/testing.md:1-40`; `docs/testing.md:54-100`; `AGENTS.md:1-305`.

[^guidance]: `.agents/skills/rpce-maintainer-guidance/SKILL.md:1-102`; `.agents/skills/rpce-maintainer-guidance/references/guidance-sources.md:1-43`.

:::

For a shorter review surface, this can be condensed to the four core PRs, their dependencies, and their acceptance gates.

### Oracle 2
- Status: Failed
- Provider: `Custom`
- Model: `claude-opus-5-5-xhigh`
- Effective effort: Provider default / not specified
- Chat: `workspace-overseer-plan--CB3EBA`

Error [context_builder_inactivity_timeout]: Context Builder Oracle exceeded its 600s inactivity budget during streaming.

Warning [lane_failures]: One lane did not complete

End of Oracle group: 2 lanes above.



> 💡 The 2 Oracle lanes above are independent answers; reconcile them using the guidance at the top of the group. Lane order is not a ranking.

Optional later follow-up: Continue this plan conversation with ask_oracle(chat_id: "workspace-overseer-plan-9A92A7", new_chat: false)