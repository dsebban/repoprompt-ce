# Workspace Overseer: automatic monitoring, Autostart, and durable coordination

## Problem
Manual session linking makes workspace supervision fragile as threads appear, become inactive, or overlap. An overseer needs continuity across restarts, actionable failure information, and truthful delivery/verification status without granting itself broader authority.

Related: #1078 covers persistent lane presentation and routine-wake compaction. This proposal adds workspace enrollment and lifecycle, not a replacement presentation system.

## User-facing design
Add an Overseer settings tab beside Agent Models:
- Independent provider/model/effort selection using the existing catalog.
- **Oversee this workspace**, off by default.
- **Autostart**, off by default; resumes the approved supervision when the workspace opens and restoration is ready.
- Status and Open Overseer action.

Keep watched sessions, exclusions, and exact per-link permissions in the existing eye-pill dashboard. Avoid another collection of scheduling knobs.

## First milestone
1. One app-owned overseer per approved workspace, with durable ownership identity. Concurrent windows/restarts must reuse it rather than create duplicates.
2. Enabling explicitly authorizes workspace-scoped observation and explains provider usage/privacy. Automatic observation does not grant management, prompt approval, publication, worker creation, or access outside that workspace.
3. Enroll existing and newly active eligible top-level sessions through existing link authority. Exclude overseers, children, and explicitly excluded threads.
4. Coalesce meaningful lifecycle/activity events. Quiet inactive routine monitoring periodically and reactivate on activity. Idle is not completion; waiting prompts/blockers remain visible. Do not delete history or retire user-owned sessions.
5. Persist exclusions so manual unlink is not immediately undone by auto-enrollment. Disable revokes only automatically owned links, preserving unrelated manual relationships.
6. Maintain a small workspace-local coordination record: explicit user brief, priorities, workstream owners, decisions, blockers, and last-verified evidence. Separate model-generated memory from authoritative user instructions; verify current inventory after restart.
7. Surface delivery and provider-start outcomes separately. A saved message whose run failed to start must not appear as successful execution or trigger blind duplicate sends.

## Existing seams and implementation gates
- Reuse `DomainAgentSessionLinkAuthority` for directional capability checks, endpoint generations, and revocation.
- Reuse `AgentSessionOversightIntentStore` and the bounded launch restore path; do not persist live authority or turn launch restoration into a second perpetual authority.
- Add one workspace lifecycle coordinator over authoritative live/session indexes, with generation-fenced asynchronous work and atomic ownership reservation.
- Extend settings through the existing settings document/manager, preserving unknown fields and future-version safety. Verify the current schema before assigning a migration version.
- Existing source dispatches `create_lane`, `retire_lane`, and `stop`. Verify installed exposure and ownership contracts before proposing new APIs.
- Characterize existing manual-link and restored-link capability defaults. Ensure automatic observation-only enrollment remains observation-only after restoration; do not rely on prompt wording for enforcement.
- Reuse current wake/reducer/receipt machinery rather than creating a parallel queue or busy-poll scheduler.

## Follow-up capabilities, independently reviewable
### Sanitized error observability
Expose bounded actionable diagnostics for failed tools/providers without exposing raw arguments/results, interaction payloads, secrets, paths, or attachments. Prefer structured failure categories plus explicitly safe diagnostic fields. Generic categories alone may not explain worktree-selection failures, so usefulness and privacy need joint validation. Keep target data untrusted. Integrate permission/disclosure in existing oversight UI rather than a global privacy-off switch.

### Image messages
Extend immediate and queued attributed sends using existing attachment/provider infrastructure. Prefer references to attachments already owned by the sender; freeze content at acceptance, retain safely for queues, and validate target vision support and size limits. Never silently downgrade to text-only delivery. Revocation/cancellation must clear queued retention where appropriate. Verify actual model input, not just thumbnails in history.

### Authorized link/lane management
Workspace enrollment handles routine links under explicit user consent. Reuse existing owned-lane creation/retirement for approved work; never retire user-owned lanes or self-grant arbitrary access. Determine whether any additional link/unlink tool surface is still necessary after automatic enrollment/exclusion integration.

### Whole-session QA coordination
Conductor serializes individual lifecycle jobs, not an entire multi-step QA loop. Add a separate artifact-bound QA lease using existing coordination seams so another worktree cannot replace the shared debug app during QA. Validate actual executable/bundle, worktree, commit, dirty-input identity, and helper provenance. Do not hold the existing live-app lock across owner commands or falsely claim ordinary pre/post checkout hashes prove immutable build inputs. This is a separate tooling deliverable, not required to ship basic workspace observation.

## Acceptance and validation
- Two-window activation/restart creates one overseer; unavailable models or persistence failures show a blocked state rather than silent fallback.
- Existing/new eligible threads enroll; exclusions survive restart; disable preserves manual links.
- Automatic links lack management and remain restricted after restoration; stale/revoked endpoints cannot act.
- Fake-clock inactivity checks quiet/reactivate without completion inference, history deletion, or automatic stop.
- Suppressed/test launches perform no production oversight persistence or provider startup.
- Delivery UI truthfully distinguishes saved, started, failed-to-start, and unconfirmed outcomes, including duplicate/restart cases.
- Focused settings, authority, lifecycle, persistence, sanitizer, and delivery tests; coordinated build/lint plus real CE MCP verification with recorded artifact provenance.
- Update the existing project verification entry point/feature map, locating the canonical owners first.
- Follow-up image tests prove frozen images reach the target model; diagnostics tests cover secrets and forbidden payloads; QA-lease tests cover competing daemons, cancellation, expiry, and artifact drift.

## Non-goals and open decisions
No cloud fleet, Slack integration, general scheduler, automatic publication, blanket approvals, or semantic duplicate detection across every chat. Workstream consolidation is a small ledger, not a new orchestration framework.
Confirm inactivity threshold and whether diagnostics/images are included in workspace consent or separately enabled. Do not freeze arbitrary Oracle-proposed caps, timeout values, schema versions, or model defaults without checking current owners and product policy.

## Planning evidence
One Oracle planning lane completed; a second timed out. The completed lane supplied a broad cross-subsystem plan with explicit source-verification gates. This draft deliberately stages it rather than treating all proposed mechanisms as verified or as a single minimal change. No implementation or live validation has been performed for this proposal.
