# Horizontal Pod Autoscaler (HPA) — IBM Sterling B2Bi

## Overview

The file `hpa-b2bi-dev01.yaml` defines **Kubernetes Horizontal Pod Autoscalers** for the three main IBM Sterling B2Bi (SFG) components running in the `ibm-b2bi-dev01-app` namespace:

| HPA Name | Component | Description |
|---|---|---|
| `b2bi-dev01-asi-hpa` | ASI | Application Server Infrastructure — core B2Bi engine |
| `b2bi-dev01-ac-hpa` | AC | Application Container — perimeter server / adapters |
| `b2bi-dev01-api-hpa` | API | REST API Server |

Each HPA scales its target Deployment between **1 and 4 replicas** based on CPU (≥ 70%) and Memory (≥ 75%) utilisation thresholds.

---

## Prerequisites

1. **Metrics Server** must be installed and healthy on the OpenShift/Kubernetes cluster:
   ```bash
   oc get apiservice v1beta1.metrics.k8s.io
   # STATUS should be: True
   ```

2. The target **Deployments must have resource requests defined** in their pod specs. Without `resources.requests.cpu` and `resources.requests.memory`, the HPA cannot calculate utilisation percentages.

3. You must be logged in to the cluster with sufficient RBAC permissions to create HPA objects in the `ibm-b2bi-dev01-app` namespace.

---

## Step 1 — Verify Deployment Names

The HPA `scaleTargetRef.name` must exactly match the Deployment name in the cluster. Run the following command to list the actual Deployment names:

```bash
oc get deployments -n ibm-b2bi-dev01-app
```

Expected output (names may vary by Helm release name):

```
NAME                              READY   UP-TO-DATE   AVAILABLE   AGE
b2bi-dev01-ibm-sfg-b2bi-asi      1/1     1            1           10d
b2bi-dev01-ibm-sfg-b2bi-ac       1/1     1            1           10d
b2bi-dev01-ibm-sfg-b2bi-api      1/1     1            1           10d
```

If the names differ, update the three `name:` fields in `hpa-b2bi-dev01.yaml` before applying.

---

## Step 2 — Apply the HPA

```bash
oc apply -f sterling-deployer/sfg/hpa-b2bi-dev01.yaml -n ibm-b2bi-dev01-app
```

Expected output:
```
horizontalpodautoscaler.autoscaling/b2bi-dev01-asi-hpa created
horizontalpodautoscaler.autoscaling/b2bi-dev01-ac-hpa created
horizontalpodautoscaler.autoscaling/b2bi-dev01-api-hpa created
```

---

## Step 3 — Verify the HPAs

```bash
# List all HPAs in the namespace
oc get hpa -n ibm-b2bi-dev01-app

# Describe a specific HPA for detailed status and events
oc describe hpa b2bi-dev01-asi-hpa -n ibm-b2bi-dev01-app
oc describe hpa b2bi-dev01-ac-hpa  -n ibm-b2bi-dev01-app
oc describe hpa b2bi-dev01-api-hpa -n ibm-b2bi-dev01-app
```

A healthy HPA shows `TARGETS` with real metric values (not `<unknown>`):

```
NAME                  REFERENCE                              TARGETS              MINPODS   MAXPODS   REPLICAS
b2bi-dev01-asi-hpa    Deployment/b2bi-dev01-ibm-sfg-b2bi-asi  45%/70%, 60%/75%    1         4         1
b2bi-dev01-ac-hpa     Deployment/b2bi-dev01-ibm-sfg-b2bi-ac   30%/70%, 50%/75%    1         4         1
b2bi-dev01-api-hpa    Deployment/b2bi-dev01-ibm-sfg-b2bi-api  20%/70%, 40%/75%    1         4         1
```

> **Note:** If `TARGETS` shows `<unknown>`, the Metrics Server may not be running or the Deployment is missing resource requests. See the Troubleshooting section below.

---

## HPA Configuration Reference

| Parameter | Value | Notes |
|---|---|---|
| `minReplicas` | 1 | Minimum pods kept running at all times |
| `maxReplicas` | 4 | Maximum pods the HPA will scale up to |
| CPU threshold | 70% | Scale out when average CPU exceeds this |
| Memory threshold | 75% | Scale out when average Memory exceeds this |
| Scale-up stabilisation | 60 s | Prevents rapid repeated scale-up events |
| Scale-down stabilisation | 300 s | Prevents premature scale-down (5 min cool-down) |
| Scale-up policy | +1 pod / 60 s | Conservative step-up to avoid overprovisioning |
| Scale-down policy | -1 pod / 120 s | Gradual step-down to maintain stability |

Adjust `minReplicas`, `maxReplicas`, and the utilisation thresholds to match your workload profile and cluster capacity.

---

## Removing the HPAs

```bash
oc delete hpa b2bi-dev01-asi-hpa b2bi-dev01-ac-hpa b2bi-dev01-api-hpa \
  -n ibm-b2bi-dev01-app
```

---

## Troubleshooting

### TARGETS shows `<unknown>`

1. Check that the Metrics Server is running:
   ```bash
   oc get pods -n openshift-monitoring | grep metrics
   # or for standalone metrics-server:
   oc get pods -n kube-system | grep metrics-server
   ```

2. Verify the Deployment has resource requests:
   ```bash
   oc get deployment b2bi-dev01-ibm-sfg-b2bi-asi -n ibm-b2bi-dev01-app \
     -o jsonpath='{.spec.template.spec.containers[*].resources}'
   ```
   The output must include a `requests` block with `cpu` and `memory` values.

3. Check HPA events for error messages:
   ```bash
   oc describe hpa b2bi-dev01-asi-hpa -n ibm-b2bi-dev01-app | grep -A 10 Events
   ```

### HPA not scaling when expected

- Confirm the pod metrics are being collected:
  ```bash
  oc top pods -n ibm-b2bi-dev01-app
  ```
- Review the stabilisation window settings — scale-up requires sustained load for at least `stabilizationWindowSeconds` (60 s by default).

### Deployment name mismatch

If the HPA reports `unable to get metrics for resource ... deployments`, the `scaleTargetRef.name` does not match. Re-check with:
```bash
oc get deployments -n ibm-b2bi-dev01-app
```
Then update `hpa-b2bi-dev01.yaml` and re-apply.