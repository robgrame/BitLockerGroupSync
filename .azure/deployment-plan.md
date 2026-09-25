# Azure Deployment Plan

> **Status:** Validated

Generated: 2026-09-18T12:05:00+02:00

---

## 1. Project Overview

**Goal:** Deploy version 1.5.4 of Nimbus.BitLockerGroupSync from the renamed
`robgrame/BitLockerGroupSync` repository in delta mode, updating only
`Sync-BitLockerExtensionAttribute` while preserving the production GroupSync
runbook, schedule, webhooks, identities, network access and Graph roles.

**Path:** Add Components

---

## 2. Requirements

| Attribute | Value |
|-----------|-------|
| Classification | Production |
| Scale | Existing tenant device inventory |
| Budget | Cost-Optimized; reuse existing Automation Account and monitoring |
| Subscription | `ME-MngEnvMCAP181054-robgrame-1` (`b45c5b53-d8f3-4a4c-9fe5-5537818a9886`) |
| Location | `italynorth` |
| Resource group | `ENCRYPTION-MONITORING-RG` (existing production deployment) |
| Runbook selection | `ExtensionAttribute` |
| Authentication | User-assigned Managed Identity |

---

## 3. Components Detected

| Component | Type | Technology | Path |
|-----------|------|------------|------|
| Group membership sync | Worker | Azure Automation PowerShell 7.2 | `runbook/Sync-BitLockerComplianceGroups.ps1` |
| Extension attribute sync | Worker | Azure Automation PowerShell 7.2 | `runbook/Sync-BitLockerExtensionAttribute.ps1` |
| Infrastructure | IaC | Bicep | `bicep/main.bicep` |
| Deployment orchestrator | Deployment | PowerShell / Az modules | `deploy.ps1` |
| Monitoring | Operations | Log Analytics, Azure Monitor, Workbook, Logic App | `bicep/monitoring.bicep`, `bicep/teams-logicapp.bicep` |

---

## 4. Recipe Selection

**Selected:** Bicep

**Rationale:** The repository already uses a standalone, tested Bicep deployment
with a PowerShell orchestrator and no AZD environment.

---

## 5. Architecture

**Stack:** Serverless Azure Automation

### Service Mapping

| Component | Azure Service | SKU |
|-----------|---------------|-----|
| Both runbooks | Azure Automation Account | Basic |
| Runtime identity | User-assigned Managed Identity | New |
| Centralized logs | Log Analytics Workspace | PerGB2018 |
| Alerts | Azure Monitor scheduled query rules + Workbook | New |

### Supporting Services

| Service | Purpose |
|---------|---------|
| Microsoft Graph | Read Intune state and update Entra device extension attributes |
| Log Analytics | JobLogs and JobStreams |
| Managed Identity | App-only Graph authentication |

---

## 6. Provisioning Limit Checklist

### Phase 1: Prepare Resource Inventory

| Resource Type | Number to Deploy | Total After Deployment | Limit/Quota | Notes |
|---------------|------------------|------------------------|-------------|-------|
| Microsoft.Automation/automationAccounts | 1 | 2 in `italynorth` | 2 minimum paid-subscription limit; higher for Enterprise/CSP | Within documented minimum limit |
| Microsoft.ManagedIdentity/userAssignedIdentities | 1 | 26 in `italynorth` | Subscription resource limits apply | Within limit |
| Microsoft.Automation/automationAccounts/runbooks | 2 | 2 in the new account | 800 per Automation Account | Within limit |
| Microsoft.Automation/automationAccounts/schedules | 2 | 2 in the new account | No separate published count quota | Job submission remains far below 100 per 30 seconds |
| Microsoft.Automation/automationAccounts/variables | 5 | 5 in the new account | 1,048,576 characters per value | Two runtime configurations plus three operator-controlled extension mapping variables; recovery state is created only after an interrupted webhook transition |
| Microsoft.OperationalInsights/workspaces | 1 | 8 in `italynorth` | No limit for PerGB2018 | Within limit |
| Microsoft.Insights/scheduledQueryRules | 4 | 4 in `italynorth` | 5,000 active log alert rules per subscription | Within limit |

**Status:** All planned resources are within documented limits. Microsoft.Quota
does not expose usable quota records for these providers; verification used live
Azure Resource Manager inventory and official Microsoft service-limit documentation.

---

## 7. Execution Checklist

### Phase 1: Planning

- [x] Analyze workspace
- [x] Gather requirements
- [x] Confirm subscription and location from the explicit user deployment request
- [x] Prepare resource inventory
- [x] Fetch limits and validate capacity
- [x] Scan codebase
- [x] Select recipe
- [x] Plan architecture
- [x] User approved target resource group, subscription and deployment of all runbooks

### Phase 2: Execution

- [x] Research components
- [x] Generate and secure infrastructure changes
- [x] Add functional and structural verification
- [x] Update plan status to `Ready for Validation`

### Phase 3: Validation

- [x] Invoke azure-validate skill
- [x] All validation checks pass
  - [x] Core Validation (CLI, auth, build, validate, what-if)
  - [x] Linting
  - [x] Azure Policy Validation
- [x] Update plan status to `Validated`
- [x] Record validation proof

### Phase 4: Deployment

- [x] Invoke azure-deploy skill
- [x] Deployment successful
- [x] Verify Automation resources after the v1.5.4 delta update
- [x] Update plan status to `Deployed`

---

## 7. Validation Proof

| Check | Command Run | Result | Timestamp |
|-------|-------------|--------|-----------|
| CI build and tests | `gh run view 35401371897` | ✅ Pass: Bicep build, PSScriptAnalyzer and Pester | 2026-09-19T00:24:02+02:00 |
| Local tests | `Invoke-Pester -Path .\tests` | ✅ Pass: 202/202 | 2026-09-19T00:18:00+02:00 |
| ARM validation | `validate-deployment.ps1 -Scope group ...` | ✅ Pass | 2026-09-19T00:25:00+02:00 |
| ARM what-if | `az deployment group what-if ... --no-pretty-print --result-format ResourceIdOnly` | ✅ Pass: 8 Create, 11 Deploy, 0 Delete | 2026-09-19T00:27:00+02:00 |
| Bicep lint | `az bicep lint --file .\bicep\main.bicep` | ✅ Pass, no warnings | 2026-09-19T00:25:00+02:00 |
| Policy assignments | `az policy assignment list --scope <target-rg>` | ✅ Pass: no RG-scoped assignments; ARM validation accepted template | 2026-09-19T00:25:00+02:00 |
| Static role verification | Review UAMI attachment and Graph role reconciliation in `main.bicep` / `deploy.ps1` | ✅ Pass: target principal derived from deployment output; Graph roles selection-specific; no privileged deploymentScript | 2026-09-19T00:28:46+02:00 |
| Workbook v2 tests | `Invoke-Pester -Path .\tests` | ✅ Pass: 210/210 | 2026-09-19T18:45:00+02:00 |
| Workbook v2 KQL | `Invoke-AzOperationalInsightsQuery` for all eight queries | ✅ Pass against `law-encryption-monitoring` | 2026-09-19T18:42:00+02:00 |
| Workbook v2 ARM validation | `az deployment group validate ...` | ✅ Pass | 2026-09-19T18:47:00+02:00 |
| Workbook v2 what-if | `az deployment group what-if ... --no-pretty-print --result-format ResourceIdOnly` | ✅ Pass: 3 Create, 17 Deploy, 0 Delete | 2026-09-19T18:47:00+02:00 |
| Workbook v2 CI | `gh run view 35456706278` | ✅ Pass | 2026-09-19T18:47:00+02:00 |
| Delta mode tests | `Invoke-Pester -Path .\tests` | ✅ Pass: 216/216 | 2026-09-19T19:50:00+02:00 |
| Delta Bicep build | `az bicep build` / `az bicep build-params` | ✅ Pass; generated KQL has no unresolved placeholders | 2026-09-19T19:50:00+02:00 |
| Delta ARM validation | `validate-deployment.ps1 -Scope group ...` | ✅ Pass | 2026-09-19T19:54:00+02:00 |
| Delta ARM what-if | `az deployment group what-if ... --no-pretty-print --result-format ResourceIdOnly` | ✅ Pass: 1 Create, 14 Deploy, 0 Delete; GroupSync runbook `Ignore` | 2026-09-19T19:55:00+02:00 |
| Delta security review | Focused review of identity, network, Graph roles and destructive cleanup | ✅ Pass: no remaining vulnerabilities | 2026-09-19T19:50:00+02:00 |
| Delta v1.5.2 tests | `Invoke-Pester -Path .\tests` | ✅ Pass: 216/216 | 2026-09-19T20:12:00+02:00 |
| Delta v1.5.2 CI | `gh run view 35460331483` | ✅ Pass | 2026-09-19T20:10:00+02:00 |
| Responsive email validation | MIME/HTML parser and 600 px Edge rendering | ✅ Pass: text and table cells wrap; command blocks adapt below 760 px | 2026-09-19T20:59:00+02:00 |
| Delta v1.5.3 validation | ARM validate plus encoding-safe what-if with effective delta parameters | ✅ Pass: 1 Create, 14 Deploy, 0 Delete; GroupSync `Ignore`; Graph module omitted | 2026-09-19T21:02:00+02:00 |
| Delta v1.5.3 CI | `gh run view 35463026020` | ✅ Pass | 2026-09-19T21:03:00+02:00 |
| Repository rename v1.5.4 tests | `Invoke-Pester -Path .\tests\Solution.Tests.ps1 -CI` | ✅ Pass: 118/118 | 2026-09-20T19:40:00+02:00 |
| Repository rename v1.5.4 CI | `gh run view 35527209784` | ✅ Pass for commit `94b386af09d4dc175e2847b6aaca3d96440a66f2` | 2026-09-20T19:52:00+02:00 |
| Delta v1.5.4 ARM validation | `validate-deployment.ps1` plus encoding-safe what-if using `.azure\v1.5.4-effective.parameters.json` | ✅ Pass: template validation succeeded; 1 Create, 14 Deploy, 0 Delete; GroupSync `Ignore`; ExtensionAttribute `Deploy`; Graph module omitted | 2026-09-20T19:55:00+02:00 |
| Delta v1.5.4 Bicep lint | `az bicep lint --file .\bicep\main.bicep` | ✅ Pass, no warnings | 2026-09-20T19:55:00+02:00 |
| Delta v1.5.4 policy validation | `az policy assignment list --scope <target-rg>` | ✅ Pass: no resource-group-scoped assignments; ARM validation accepted the template | 2026-09-20T19:55:00+02:00 |
| Delta v1.5.4 static role verification | Review Bicep identity attachment and `Get-RequiredGraphAppRole` selection | ✅ Pass: extension-only requires `DeviceManagementManagedDevices.Read.All` and `Device.ReadWrite.All`; no Azure RBAC role is required | 2026-09-20T19:57:00+02:00 |
| Tomorrow preflight tests | `Invoke-Pester -Path .\tests -CI` | ✅ Pass: 219/219 | 2026-09-24T22:40:00+02:00 |
| Tomorrow preflight ARM validation | `validate-deployment.ps1` using `.azure\v1.5.4-effective.parameters.json` | ✅ Pass: CLI, authentication, Bicep build and ARM validation; wrapper console rendering failed only on a Unicode emoji | 2026-09-24T22:39:00+02:00 |
| Tomorrow preflight ARM what-if | UTF-8 `az deployment group what-if --no-pretty-print --result-format ResourceIdOnly` | ✅ Pass: 1 Create, 14 Deploy, 1 Ignore, 0 Delete; GroupSync runbook ignored | 2026-09-24T22:40:00+02:00 |
| Tomorrow preflight Bicep lint | `az bicep lint --file .\bicep\main.bicep` | ✅ Pass, no warnings | 2026-09-24T22:40:00+02:00 |
| Tomorrow preflight policy validation | `az policy assignment list --scope <target-rg>` | ✅ Pass: no resource-group-scoped assignments | 2026-09-24T22:40:00+02:00 |
| Tomorrow preflight deployment tooling | Verify required PowerShell module minimum versions | ✅ Pass: Az.Accounts 5.5.3, Az.Resources 10.2.0, Az.Automation 1.12.1, Microsoft.Graph modules 2.40.0 | 2026-09-24T22:40:00+02:00 |
| Tomorrow preflight source and CI | Compare `HEAD` with `origin/main`; inspect latest GitHub Actions run | ✅ Pass: both at `94b386af09d4dc175e2847b6aaca3d96440a66f2`; CI run 35527209784 succeeded | 2026-09-24T22:40:00+02:00 |

**Validated by:** azure-validate workflow
**Validation timestamp:** 2026-09-24T22:40:00+02:00

## Role Assignment Verification

- **Status:** Verified
- **Identity:** `id-encryption-monitoring`, attached directly to the Automation Account
- **Graph app roles:** `DeviceManagementManagedDevices.Read.All`,
  `Device.ReadWrite.All`, `Group.Create`, `GroupMember.ReadWrite.All`
- **Recovery key role:** `BitlockerKey.Read.All` intentionally omitted because
  `enableKeyEscrowCheck=false`
- **Grant path:** interactive administrative reconciliation; target principal is
  read from the successful Bicep deployment output

## Deployment Verification

- **Workbook v2:** `BitLocker Extension Attribute - Operations Overview v2`,
  resource `57286cb1-7a1a-5f59-90f9-e641185671cf`
- **Workbook content:** 14 items, 8 KQL queries, 6 graph/KPI views; all placeholders resolved
- **Deployment:** version 1.5.2 delta deployment completed in `ENCRYPTION-MONITORING-RG`
- **Automation Account:** `aa-encryption-monitoring` state `Ok`
- **Runbooks:** both `Published` as `PowerShell72`
- **Schedules:** both hourly schedules enabled and linked
- **GroupSync preservation:** runbook last-modified time and jobSchedule ID unchanged by the v1.5.2 delta deployment
- **Graph module:** `Microsoft.Graph.Authentication` 2.40.0 restored to `Succeeded`; v1.5.2 delta lookup skipped subsequent module PUT
- **Automation security state:** existing User Assigned Managed Identity and `publicNetworkAccess` preserved
- **Graph roles:** exactly `DeviceManagementManagedDevices.Read.All`,
  `Device.ReadWrite.All`, `Group.Create`, `GroupMember.ReadWrite.All`
- **First GroupSync job:** `Completed`; 4 devices evaluated, 3 encrypted,
  0 reconciliation errors
- **First extension job:** `Completed`; 4 updates, 0 conflicts, 0 errors
- **Entra verification:** 4 devices mapped (`enc`=3, `notenc`=1), 0 foreign values
- **CI:** build 1.3.2 passed in
  `https://github.com/robgrame/BitLockerGroupSync/actions/runs/35403350569`
- **Live Azure RBAC:** no Azure control/data-plane role assignment is required
  for this Graph-only managed identity; UAMI attachment and Graph app roles were
  verified live

### Version 1.5.4 repository rename deployment

- **Deployment:** `nimbus-bitlocker-20260920200224642`, state `Succeeded`
- **Source commit:** `94b386af09d4dc175e2847b6aaca3d96440a66f2`
- **Repository:** `https://github.com/robgrame/BitLockerGroupSync`
- **Mode:** targeted delta, `RunbookSelection=ExtensionAttribute`, no `FullReconcile`
- **GroupSync preservation:** runbook last-modified time unchanged and jobSchedule
  `2e22b3b8-f992-56fd-a030-c71592dc7973` unchanged
- **Extension runbook:** `Published` as `PowerShell72`; deployed content SHA-256
  matches the runbook at the source commit
- **Extension schedule:** enabled hourly; jobSchedule
  `e2795d3c-3561-5b1d-b6b5-d7d1f8d30d10`
- **Graph module:** `Microsoft.Graph.Authentication` 2.40.0 remains `Succeeded`;
  last-modified time unchanged
- **Automation security state:** User Assigned Managed Identity and public network
  access preserved
- **Graph roles:** `DeviceManagementManagedDevices.Read.All`,
  `Device.ReadWrite.All`, `Group.Create`, `GroupMember.ReadWrite.All`
- **Azure RBAC:** zero assignments, as expected for this Graph-only identity
- **Monitoring:** shared failure/error alerts include both runbooks; both workbook
  resources remain deployed and tagged version 1.5.4
- **Automation Variables:** `extensionAttribute10`, `enc`, `notenc` preserved and
  unencrypted

---

## 8. Files to Generate

| File | Purpose | Status |
|------|---------|--------|
| `.azure/deployment-plan.md` | Deployment source of truth | Validated |
| `bicep/main.bicep` | Infrastructure for selective runbook deployment | Complete |
| `bicep/encryption-monitoring.local.bicepparam` | Secret-free target parameters pinned to commit `94b386a` | Complete |
| `runbook/Sync-BitLockerExtensionAttribute.ps1` | New runtime component | Complete |

---

## 9. Next Steps

> Current: Version 1.5.4 deployed and verified in targeted delta mode

1. Continue using `RunbookSelection=ExtensionAttribute` without
   `FullReconcile` for future delta updates.
2. Use `FullReconcile` only when exclusive desired-state cleanup is explicitly
   approved.
