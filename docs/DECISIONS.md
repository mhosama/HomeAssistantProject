# Architecture Decision Records (ADRs)

Log of key decisions made during the project with context and rationale.

---

## ADR-001: Use HAOS on Hyper-V (not Docker or HA Core)

**Date**: 2026-03-10
**Status**: Accepted

**Context**: Multiple installation methods exist for Home Assistant: HAOS (full OS), Docker container, HA Core (Python venv), or HA Supervised.

**Decision**: Deploy HAOS as a Hyper-V Gen2 VM on the existing Windows 10 server.

**Rationale**:
- HAOS provides the Supervisor, which enables add-ons (SSH, Samba, file editor, etc.)
- Hyper-V is already available on Windows 10 Enterprise - no additional software needed
- HAOS is the officially supported and recommended installation method
- Full backup/restore capability via HA snapshots
- VM snapshots provide an additional safety net before major changes
- Keeps the Windows host available for other purposes

**Consequences**:
- Cannot run other services directly in HA (would need separate VMs/Docker)
- VM has overhead compared to bare-metal, but negligible for HA workloads
- Need to manage Hyper-V VM lifecycle (auto-start, snapshots)

---

## ADR-002: Cloud integrations first, local control later

**Date**: 2026-03-10
**Status**: Accepted

**Context**: Many Sonoff/eWeLink devices support both cloud and local (LAN) control. Sunsynk currently only offers cloud API.

**Decision**: Start with cloud-based integrations for all devices, then migrate to local control where possible in a later phase.

**Rationale**:
- Cloud setup is simpler and gets everything connected faster
- Cloud works regardless of network topology or VLAN configuration
- Sunsynk only has cloud API anyway, so cloud is required there
- Can migrate individual devices to LAN mode incrementally
- The AlexxIT `sonoff` integration supports both modes, making future migration easy

**Consequences**:
- Dependency on internet connectivity for device control
- Slightly higher latency for cloud-controlled devices
- Need eWeLink/Sunsynk accounts as infrastructure dependencies
- Should plan for local fallback in the future

---

## ADR-003: HACS for Sunsynk and Sonoff integrations

**Date**: 2026-03-10
**Status**: Accepted

**Context**: Built-in HA integrations don't include Sunsynk. Sonoff/eWeLink has limited built-in support.

**Decision**: Use HACS (Home Assistant Community Store) custom integrations for Sunsynk and eWeLink/Sonoff.

**Rationale**:
- No built-in Sunsynk integration exists; HACS is the only option
- HACS Sonoff integration (AlexxIT) has better device support than built-in alternatives
- HACS is well-maintained and widely used in the HA community
- Easy to install and update custom integrations

**Consequences**:
- HACS requires GitHub account for initial setup
- Custom integrations may lag behind HA core updates
- Need to monitor for breaking changes during HA upgrades
- Should take VM snapshots before updating HACS integrations

---

## ADR-004: LLM Vision Analysis via PowerShell Scheduled Task

**Date**: 2026-03-11
**Status**: Accepted

**Context**: 8 security cameras are configured in HA but provide only video streams — no intelligent analysis, alerting, or metrics extraction. Options considered: Frigate (local ML, requires Coral TPU or GPU), HA built-in AI (doesn't exist for vision), or external LLM API.

**Decision**: Use Google Gemini 2.0 Flash via a PowerShell script running as a Windows Scheduled Task every 60 seconds. The script captures snapshots from all 8 cameras via the HA REST API, sends each to Gemini for structured JSON analysis, and updates HA sensors / fires alerts based on the results.

**Rationale**:
- Follows existing project patterns (PowerShell scripts + scheduled tasks, same as `06a-Refresh-News.ps1`)
- Gemini Flash free tier allows 15 RPM — 8 cameras/min fits within limits
- Structured JSON output (`responseMimeType: "application/json"`) ensures reliable parsing
- No new infrastructure needed (no GPU, no Frigate, no MQTT)
- Camera-specific prompts allow tailored analysis (chickens, security, food, gates)
- Runspace pool enables parallel execution (all 8 cameras in ~5-10 seconds)
- State file enables alert throttling and meal-based food tracking

**Consequences**:
- Depends on Google Gemini API availability and free tier limits
- 60-second polling means up to 60s delay for security alerts (acceptable for home use)
- LLM analysis is probabilistic — may have false positives/negatives
- Requires internet connectivity for Gemini API calls
- API key stored in `deploy/config.ps1` (same pattern as HA token)

---

## Template for New ADRs

```markdown
## ADR-XXX: Title

**Date**: YYYY-MM-DD
**Status**: Proposed / Accepted / Deprecated / Superseded

**Context**: What is the situation that requires a decision?

**Decision**: What was decided?

**Rationale**: Why was this decision made?

**Consequences**: What are the implications?
```
