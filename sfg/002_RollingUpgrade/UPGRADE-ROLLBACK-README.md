# 🚀 IBM Sterling B2Bi — Upgrade & Rollback Automation

> **Automate Helm-based rolling upgrades and rollbacks for IBM Sterling B2Bi (SFG) running on OpenShift / Kubernetes.**

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Prerequisites](#-prerequisites)
- [Scripts at a Glance](#-scripts-at-a-glance)
- [Demo: Upgrade Script](#-demo-upgrade-script)
- [Demo: Rollback Script](#-demo-rollback-script)
- [Upgrade Type Reference](#-upgrade-type-reference)
- [File Inventory](#-file-inventory)
- [Troubleshooting](#-troubleshooting)

---

## 🔍 Overview

These scripts automate the lifecycle management of IBM Sterling B2Bi deployed via Helm on OpenShift. They handle:

| Capability | `upgrade-b2bi.sh` | `rollback-b2bi.sh` |
|---|:---:|:---:|
| Interactive prompts | ✅ | ✅ |
| Auto-detect chart version | ✅ | — |
| Upgrade type classification | ✅ | ✅ |
| DB schema migration warning | ✅ | ✅ |
| Values backup / restore | ✅ | ✅ |
| Dry-run before apply | ✅ | — |
| Pod health monitoring | ✅ | ✅ |
| Rollback instructions | ✅ | — |

---

## ✅ Prerequisites

Before running either script, ensure the following are in place:

```
✔  oc  or  kubectl  installed and logged in to the cluster
✔  helm  v3.x installed and ibm-helm repo configured
✔  Sufficient RBAC permissions in the target namespace
✔  IBM Entitled Registry pull secret present in the namespace
✔  Database backup taken (required for MAJOR / MINOR upgrades)
```

**Verify Helm repo:**
```bash
helm repo list | grep ibm-helm
# ibm-helm    https://raw.githubusercontent.com/IBM/charts/master/repo/ibm-helm

helm repo update ibm-helm
```

---

## 📦 Scripts at a Glance

```
sterling-deployer/sfg/
├── upgrade-b2bi.sh          # Rolling upgrade script
├── rollback-b2bi.sh         # Rollback script
├── UPGRADE-ROLLBACK-README.md  # This document
├── s0-values-backup-*.yaml  # Auto-generated pre-upgrade backups
└── s0-values-upgrade-*.yaml # Auto-generated upgrade override files
```

---

## 🎬 Demo: Upgrade Script

### Step 1 — Run the script

```bash
cd sterling-deployer/sfg
./upgrade-b2bi.sh
```

### Step 2 — Interactive session walkthrough

```
============================================================
  IBM Sterling B2Bi — Rolling Upgrade Script
============================================================

[INFO]  Using Kubernetes CLI: oc
[INFO]  Using Helm: v3.18.3

Namespace [default: ibm-b2bi-dev01-app]: ↵
[OK]    Namespace 'ibm-b2bi-dev01-app' found.

Helm releases in namespace 'ibm-b2bi-dev01-app':
NAME  NAMESPACE           REVISION  CHART               APP VERSION
s0    ibm-b2bi-dev01-app  1         ibm-b2bi-prod-3.1.1  6.2.1.1

Helm release name [default: s0]: ↵
[OK]    Current release: chart=ibm-b2bi-prod-3.1.1  app_version=6.2.1.1

[INFO]  Updating ibm-helm repository...
Update Complete. ⎈Happy Helming!⎈

[INFO]  Available ibm-b2bi-prod chart versions:
NAME                   CHART VERSION  APP VERSION
ibm-helm/ibm-b2bi-prod  3.2.1         6.2.2.0_1
ibm-helm/ibm-b2bi-prod  3.2.0         6.2.2.0
ibm-helm/ibm-b2bi-prod  3.1.3         6.2.1.1_2
ibm-helm/ibm-b2bi-prod  3.1.1         6.2.1.1
...

Target app version (e.g. 6.2.2.0): 6.2.2.0
```

### Step 3 — Upgrade type is automatically classified

```
------------------------------------------------------------
  Upgrade Type Analysis
------------------------------------------------------------
  Type   : ⚠  MINOR UPGRADE (patch-level)
  Reason : Patch version change (6.2.1.1 → 6.2.2.0)
  ⚠  DATABASE SCHEMA MIGRATION MAY BE REQUIRED
     Review the release notes for 6.2.2.0 before proceeding.
------------------------------------------------------------

[INFO]  Looking up chart version for app version 6.2.2.0...
[OK]    Found chart version: ibm-b2bi-prod-3.2.0 (app 6.2.2.0)
[INFO]  Backing up current Helm values to s0-values-backup-6.2.1.1-20260228-061026.yaml...
[OK]    Backup saved: s0-values-backup-6.2.1.1-20260228-061026.yaml
[INFO]  Generating upgrade values override file: s0-values-upgrade-6.2.2.0-20260228-061026.yaml...
[OK]    Upgrade values file saved: s0-values-upgrade-6.2.2.0-20260228-061026.yaml
```

### Step 4 — Review summary and confirm

```
------------------------------------------------------------
  Upgrade Summary
------------------------------------------------------------
  Release          : s0
  Namespace        : ibm-b2bi-dev01-app
  Current version  : 6.2.1.1 (chart ibm-b2bi-prod-3.1.1)
  Target version   : 6.2.2.0 (chart ibm-b2bi-prod-3.2.0)
  Upgrade type     : MINOR
  DB schema change : true
  Values backup    : s0-values-backup-6.2.1.1-20260228-061026.yaml
  Upgrade values   : s0-values-upgrade-6.2.2.0-20260228-061026.yaml
------------------------------------------------------------

  ⚠  DATABASE SCHEMA MIGRATION WILL RUN
     Ensure a database backup exists before proceeding.
     The upgrade job may take 15-60 minutes depending on data volume.

Run dry-run first? [Y/n]: Y
```

### Step 5 — Dry-run validates the upgrade

```
[INFO]  Running helm upgrade dry-run...

NOTES:
Please wait while the application is getting deployed.
1. Run the below command to check the status of application server replica sets...
...
[OK]    Dry-run passed.

Proceed with the actual upgrade? [y/N]: y
```

### Step 6 — Upgrade executes and pods are monitored

```
[INFO]  Executing helm upgrade...
Release "s0" has been upgraded. Happy Helming!
NAME: s0
LAST DEPLOYED: Sat Feb 28 06:10:26 2026
STATUS: deployed
REVISION: 2

[OK]    Helm upgrade completed. Release revision: 2

[INFO]  Waiting 30 seconds for pods to start rolling...
[INFO]  Pod status (checking every 60 s for up to 20 min)...

--- Check 1/20 ---
  s0-b2bi-ac-server-0     Running      0          5h
  s0-b2bi-ac-server-1     Running      0          5h
  s0-b2bi-api-server-0    Running      0          38d
  s0-b2bi-api-server-1    Running      0          5h
  s0-b2bi-asi-server-0    Running      0          5h
  s0-b2bi-asi-server-1    Running      0          2m

--- Check 3/20 ---
  s0-b2bi-ac-server-0     Running      0          5h
  s0-b2bi-ac-server-1     Running      0          5h
  s0-b2bi-api-server-0    Running      0          38d
  s0-b2bi-api-server-1    Running      0          5h
  s0-b2bi-asi-server-0    Running      0          5h
  s0-b2bi-asi-server-1    Running      0          12m

[OK]    All pods are Ready! Upgrade complete.

------------------------------------------------------------
  Final Status
------------------------------------------------------------
NAME  NAMESPACE           REVISION  CHART               APP VERSION  STATUS
s0    ibm-b2bi-dev01-app  2         ibm-b2bi-prod-3.2.0  6.2.2.0     deployed

  To rollback if needed:
  helm rollback s0 -n ibm-b2bi-dev01-app
------------------------------------------------------------
```

---

## 🎬 Demo: Rollback Script

### Step 1 — Run the script

```bash
cd sterling-deployer/sfg
./rollback-b2bi.sh
```

### Step 2 — Interactive session walkthrough

```
============================================================
  IBM Sterling B2Bi — Rollback Script
============================================================

  ⚠  READ BEFORE PROCEEDING
  Helm rollback restores Kubernetes resources only.
  It does NOT roll back database schema changes.
  If the upgrade included a DB schema migration, restore
  the database from a pre-upgrade backup FIRST.

Namespace [default: ibm-b2bi-dev01-app]: ↵
[OK]    Namespace 'ibm-b2bi-dev01-app' found.

Helm releases in namespace 'ibm-b2bi-dev01-app':
NAME  NAMESPACE           REVISION  CHART               APP VERSION
s0    ibm-b2bi-dev01-app  2         ibm-b2bi-prod-3.2.0  6.2.2.0

Helm release name [default: s0]: ↵
[OK]    Current release: revision=2  chart=ibm-b2bi-prod-3.2.0  app=6.2.2.0
```

### Step 3 — Revision history is displayed

```
[INFO]  Revision history for release 's0':

  REVISION  UPDATED                   STATUS      CHART                APP VERSION  DESCRIPTION
  1         Tue Jan 20 23:53:24 2026  superseded  ibm-b2bi-prod-3.1.1  6.2.1.1      Install complete
  2         Sat Feb 28 06:10:26 2026  deployed    ibm-b2bi-prod-3.2.0  6.2.2.0      Upgrade complete

Rollback to revision [default: 1]: ↵
[INFO]  Target revision 1: chart=ibm-b2bi-prod-3.1.1  app=6.2.1.1
```

### Step 4 — Rollback type is classified with DB schema warning

```
------------------------------------------------------------
  Rollback Type Analysis
------------------------------------------------------------
  Type   : ⚠  MINOR ROLLBACK (patch-level)
  Reason : Patch version change (6.2.2.0 → 6.2.1.1)

  ⚠  DATABASE SCHEMA ROLLBACK RISK DETECTED
     The forward upgrade likely ran a DB schema migration.
     Helm rollback will NOT revert the database schema.
     You MUST restore the database from a pre-upgrade backup
     before proceeding, or the application will fail to start.

  Have you restored the database from a pre-upgrade backup? [y/N]: y
[OK]    Database restore confirmed by operator.
------------------------------------------------------------
```

### Step 5 — Optionally restore values from backup

```
Values Backup Restore (optional)
If you have a values backup file from upgrade-b2bi.sh, you can
restore it alongside the Helm rollback for a cleaner state.

Path to values backup file (press Enter to skip):
s0-values-backup-6.2.1.1-20260228-061026.yaml
[OK]    Backup file found: s0-values-backup-6.2.1.1-20260228-061026.yaml
```

### Step 6 — Review summary and confirm

```
------------------------------------------------------------
  Rollback Summary
------------------------------------------------------------
  Release          : s0
  Namespace        : ibm-b2bi-dev01-app
  Current revision : 2 (ibm-b2bi-prod-3.2.0 / app 6.2.2.0)
  Target revision  : 1 (ibm-b2bi-prod-3.1.1 / app 6.2.1.1)
  Rollback type    : MINOR
  DB schema risk   : true
  Values backup    : s0-values-backup-6.2.1.1-20260228-061026.yaml
------------------------------------------------------------

Proceed with rollback? [y/N]: y
```

### Step 7 — Rollback executes and pods are monitored

```
[INFO]  Executing helm rollback to revision 1...
[INFO]  Restoring chart ibm-b2bi-prod-3.1.1 with values from backup file...
Release "s0" has been upgraded. Happy Helming!
STATUS: deployed
REVISION: 3

[OK]    Rollback completed. Release is now at revision 3.

[INFO]  Waiting 30 seconds for pods to start rolling...
[INFO]  Pod status (checking every 60 s for up to 20 min)...

--- Check 1/20 ---
  s0-b2bi-ac-server-0     Running      0          5h
  s0-b2bi-ac-server-1     Running      0          5h
  s0-b2bi-api-server-0    Running      0          38d
  s0-b2bi-api-server-1    Running      0          5h
  s0-b2bi-asi-server-0    Running      0          5h
  s0-b2bi-asi-server-1    Running      0          2m

[OK]    All pods are Ready! Rollback complete.

------------------------------------------------------------
  Final Status
------------------------------------------------------------
NAME  NAMESPACE           REVISION  CHART               APP VERSION  STATUS
s0    ibm-b2bi-dev01-app  3         ibm-b2bi-prod-3.1.1  6.2.1.1     deployed

  REVISION  STATUS      CHART                APP VERSION
  1         superseded  ibm-b2bi-prod-3.1.1  6.2.1.1
  2         superseded  ibm-b2bi-prod-3.2.0  6.2.2.0
  3         deployed    ibm-b2bi-prod-3.1.1  6.2.1.1

  To re-apply the upgrade if needed:
  ./upgrade-b2bi.sh
------------------------------------------------------------
```

---

## 📊 Upgrade Type Reference

| From → To | Type | DB Schema | Action Required |
|---|---|---|---|
| `6.1.x` → `6.2.x` | 🔴 **MAJOR** | ✅ Required | DB backup + restore on rollback |
| `6.2.1.x` → `6.2.2.x` | 🟡 **MINOR** | ⚠️ Likely | DB backup + restore on rollback |
| `6.2.1.1` → `6.2.1.1_2` | 🟢 **PATCH/iFIX** | ❌ None | No DB action needed |

> **Rule of thumb:** Any change in the first three version segments (`X.Y.Z`) carries a DB schema migration risk. Always take a DB backup before upgrading.

---

## 📁 File Inventory

| File | Description |
|---|---|
| `upgrade-b2bi.sh` | Interactive upgrade script |
| `rollback-b2bi.sh` | Interactive rollback script |
| `hpa-b2bi-dev01.yaml` | HPA manifest for `ibm-b2bi-dev01-app` |
| `add-b2bi-hpa.sh` | Interactive HPA creation script |
| `HPA-README.md` | HPA operational guide |
| `s0-values-backup-<ver>-<ts>.yaml` | Auto-generated pre-upgrade values backup |
| `s0-values-upgrade-<ver>-<ts>.yaml` | Auto-generated upgrade override values |
| `customer_overrides.properties` | B2Bi application property overrides |
| `TXExportConfig.xml` | Transaction export configuration |

---

## 🔧 Troubleshooting

### Pods stuck in `CrashLoopBackOff` after upgrade

```bash
# Check pod logs
oc logs <pod-name> -n ibm-b2bi-dev01-app --previous

# Common causes:
# 1. DB connection timeout → check DB pod and network policies
# 2. Node networking issue → test from node:
oc debug node/<node-name> -- chroot /host bash -c \
  "curl -sv --connect-timeout 5 telnet://<db-clusterip>:<port>"

# If a specific node is faulty, cordon it and reschedule:
oc adm cordon <node-name>
oc delete pod <pod-name> -n ibm-b2bi-dev01-app
```

### Dry-run fails with `identityService` validation errors

```bash
# The new chart (3.2.0+) requires identityService sub-chart fields.
# The upgrade script handles this automatically. If running helm manually,
# ensure your values file includes the full identityService.application block.
```

### `helm rollback` fails or pods won't start after rollback

```bash
# Verify the DB has been restored to the pre-upgrade state.
# Check DB connections from the pod:
oc logs <asi-pod> -n ibm-b2bi-dev01-app | grep -i "database\|connection\|error"

# Force a clean restart after DB restore:
oc delete pod -l release=s0 -n ibm-b2bi-dev01-app
```

### Check current Helm release status

```bash
helm list -n ibm-b2bi-dev01-app
helm history s0 -n ibm-b2bi-dev01-app
helm get values s0 -n ibm-b2bi-dev01-app
```

---

> 💡 **Tip:** Always run `upgrade-b2bi.sh` with the dry-run option enabled (default `Y`) before applying changes to production environments.