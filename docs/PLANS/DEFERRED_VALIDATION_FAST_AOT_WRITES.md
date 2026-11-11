# Fast AOT authoring with deferred X++ validation — implementation plan

Status: PROPOSED / NOT IMPLEMENTED  
Owner repository: AXTRACK/d365fo-cli-clean  
Workstream branch: `chatgpt/ninja-add-method` (existing, divergent from main; reconcile before implementation or integration)  
Motivation: Dedalus CR 64120, `DEDCoreConsolidationRequestRefresh`, where valid forward references to not-yet-authored class methods currently block `modify_method(create=true)`.

## Decision and outcome

Optimize the physical Implement phase for **write first, compile/diagnose later**. Persist all authorized AOT objects/methods promptly, including references to methods that will be authored later in the same WorkItem. Do not invoke reference resolution, offline X++ Best Practice checks, X++ compiler, or full-model index synchronization per method in the fast authoring path. Compile and address errors once after the complete object set has been written, as a separately requested workflow step. Do not misrepresent successful metadata persistence as compiled/working code.

Retain metadata safety: explicit authorized model, live provider read/write, exact object/member identity, duplicate protection, no accidental overwrite, preservation of unrelated members, structural input sanity, Bridge serialization, journaling/undo and read-back. Never bypass model authorization or replace the provider with raw Ax*.xml writes.

## Confirmed baseline (main, 2026-11-11)

1. `src/D365FO.Core/Bridge/MethodModifyEngine.cs`: `ModifyRequest` has `Create`, `NewSource`, `GroundingToken`. `CheckGrounding` invokes `ReferenceResolver.Resolve` and `XppValidator.Validate` and unconditionally returns `VALIDATION_FAILED` when reference/BP errors exist, even when `D365FO_GROUNDING_ENFORCE` is false. Its token/provenance enforcement is a separate contract and must not be silently disabled.
2. `src/D365FO.Cli/Commands/Modify/ModifyMethodCommand.cs`: CLI `modify method --create --source` routes to `MethodModifyEngine.Modify`. No fast/deferred validation flag currently exposed.
3. `src/D365FO.Mcp/ToolHandlers.cs` and `src/D365FO.Mcp/ToolCatalog.cs`: MCP `modify_method` routes to the same engine; the exposed schema has `create`, but no validation-mode argument.
4. `src/D365FO.Mcp/ToolCatalog.cs`: `InvokeWithIndexRefresh` wraps tool invocation and calls `IndexAutoRefresh.Scope.Flush()` after every tool call, including write failures. `D365FO_AUTO_REFRESH=0` already disables auto-refresh globally; do not invent a second indexer or persistent queue.
5. `src/D365FO.Core/Index/IndexAutoRefresh.cs`: existing opt-out `D365FO_AUTO_REFRESH` and index sync mechanism can be reused. Live CR 64120 method creation reported an individual index refresh of ~71 s (other write ~13 s); actual cost must be measured on the target VM.
6. CR 64120: `refreshFromPreparedInputs` rejected 28 unresolved references and 1 BP error, and `refreshRequest` rejected 5 unresolved references, even though the methods are specified in the approved implementation source. These are authoring-order failures, not proof that the source can compile.

## Proposed smallest change

### A. Explicit fast authoring mode

- Add a narrowly named per-call `validationMode` (e.g. `strict|deferred`) to `MethodModifyEngine.ModifyRequest`; preserve current `strict` default for backward compatibility. Expose the same enum in CLI `modify method` and MCP `modify_method` schema/handler. Document that `deferred` means **skip** reference and offline BP computation entirely, not merely ignore their results.
- Keep `CheckInput`, exact one-method source parsing, duplicate/missing-member distinction, custom-model/Bridge gate, source and sibling preservation, provider write and undo, and existing provenance-token enforcement. Split the expensive reference/BP phase from token checking so `deferred` cannot accidentally skip authorization/provenance checks.
- Record `validationMode=deferred` and `validationStatus=NOT_RUN` in the write receipt. Do not return fake `referenceErrors=0`, `bpErrors=0` or a validation PASS.
- Scope this option first to `modify_method` (create and replace). Inventory other physical writers (`generate_object`, `modify_object`, batch actions, label writes) and extend only where an actual equivalent X++ validation gate exists. Never add a generic validation bypass to unrelated operations.

### B. Defer index synchronization without sacrificing correctness

- Reuse `D365FO_AUTO_REFRESH=0` for a controlled bulk authoring session, **or** expose a per-call `refreshIndex=false` option at the MCP/CLI dispatch boundary if the existing global setting is impractical. Prefer existing configuration if it can be applied to the shared MCP service safely without affecting unrelated callers; otherwise choose an explicit per-call setting, not a new service.
- Ensure a disabled refresh is visible in the write receipt as `indexStatus=STALE_PENDING_SYNC`; successful Bridge/provider read-back remains authoritative. Never use the stale SQLite index to decide whether a just-written method exists or to declare absence.
- At the end of the authoring batch, invoke the existing scoped model index sync/refresh once; verify that `get_method` / `get_object_info` returns the final method inventory. Handle a failed or interrupted batch with explicit resync, not a persistent background queue.
- Consider a single bounded bulk-method operation only if measurements show Bridge startup/serialization per method is still the dominant cost after removing reference/BP and index refresh. Do **not** introduce batching in the first implementation.

### C. Workflow separation

- Physical Implement: enumerate approved targets, verify ownership/current preimage, create/update them with deferred X++ validation and deferred index refresh, provider read-back (at least per object and on ambiguous writes), final one-time index refresh and inventory reconciliation. Do not compile each object.
- Separate compilation/validation step after the object set is present: full model/project X++ build (prefer full when incremental symbols are stale), optional BP and DB sync/tests when applicable. Diagnose and repair errors then. This step must have its own explicit execution/reporting status and must not be reported PASS during authoring.
- Update only the canonical Implement/tooling guidance that actually instructs per-object X++ validation; keep lifecycle stage boundaries and no automatic Review/Finish advancement. Avoid introducing a new lifecycle stage merely to house compilation.

## Implementation sequence

1. Reconcile existing `chatgpt/ninja-add-method` branch's three unique commits with current `main` (branch is ahead 3, behind 1 as observed 2026-11-11). Retain useful changes; do not force-push or overwrite unrelated work. Check existing PR/worktree and branch ownership before code mutation.
2. Write focused regression tests for strict-mode rejection and deferred-mode success with missing forward method references, duplicate rejection, wrong-model rejection, malformed multi-method source rejection, token-enforcement preservation, sibling preservation, journaling/undo, and correct `NOT_RUN` receipt.
3. Refactor `MethodModifyEngine.CheckGrounding` into independent authorization/provenance and optional expensive X++ diagnostics. Wire `validationMode` from CLI settings and MCP JSON schema/handler to the engine.
4. Exercise existing index-auto-refresh opt-out and one-time explicit sync; test no per-write flush when disabled, correct stale-index disclosure, post-sync search/read consistency, and failure/interruption recovery. Add per-call opt-out only if needed for safe shared-service operation.
5. Inventory other AOT writers and selectively apply the same mode to those that run equivalent pre-write X++ reference/BP gates; retain structural serializer validation. Avoid expanding beyond evidenced needs.
6. Update CLI help, MCP tool descriptions/schema, `docs/CAPABILITIES.md`, focused operational documentation and canonical workflow/Skill instructions in their owning repository if required. Changes to AXTRACK/Codex must be separate authorized Git changes with current workflow and branch reconciliation.
7. Run focused unit/integration tests, then applicable deterministic tests through public `AXTRACK/build-tests` bound to the exact candidate SHA. Do not use private hosted CI. Perform Windows Bridge/provider acceptance last.
8. On disposable custom-model test class: create two methods with forward references using deferred mode; verify immediate live read-back, duplicate/malformed/wrong-model refusal, undo, and final single index sync. Then apply the approved CR 64120 Refresh source in its authorized Implement continuation, verifying five methods and sibling preservation. Perform a single model compilation as the separate validation step and report actual compiler errors.
9. Deploy pinned CLI/MCP using the existing canonical updater, verify active binary SHA/revision and exposed MCP schema after refresh, and confirm runtime receipts. Do not treat Git CI PASS as deployed runtime acceptance.

## Acceptance criteria

- `modify_method(create=true,validationMode=deferred)` can persist a syntactically single-method source that references not-yet-created methods, without invoking reference/BP validation.
- Strict mode remains unchanged by default. Deferred mode does not relax custom-model authorization, duplicate handling, input structure, provenance token requirements, Bridge/IMetadataProvider use, journal/undo or read-back.
- A series of writes incurs no automatic X++ build and no full index refresh per method; exactly one explicit index refresh at batch end restores index consistency.
- Receipts distinguish `WRITE_VERIFIED` from `XPP_VALIDATION_NOT_RUN` and `INDEX_STALE`; no false PASS.
- End-to-end Windows acceptance demonstrates the full CR 64120 Refresh class can be authored before dependent methods, followed by a separate compiler step. Record elapsed time per method and batch versus the current baseline.
- No automatic merge to main, TFVC check-in, Review/Finish transition, new persistent infrastructure or raw XML fallback.

## Stop conditions and risks

- Stop on wrong model, changed preimage/conflict, duplicate, malformed source, unauthorized operation, failed Bridge serialization or unexpected postimage.
- If a shared MCP service cannot safely isolate global `D365FO_AUTO_REFRESH=0`, implement an explicit per-call opt-out rather than mutating shared process settings.
- Deferred mode deliberately permits X++ source that may not compile until later; the user accepts this temporary state, but successful metadata writes are not production-ready.
- If an existing branch contains unresolved competing changes, reconcile them before implementation; this plan-only commit does not authorize overwriting them.

## Out of scope

No removal of permission checks, no disabling structural metadata validation, no per-object compile, no automatic project-specific business code generation, no new broker/index store, no implicit lifecycle stage activation, no branch merge.
