# .tekton — Complete Tekton CI/CD + GitHub Trigger README
This directory will contain all the Tekton workflows i created in this CI/CD Tools Practices project.

**Goal:** provide a single, exhaustive reference describing every file in this folder and every step to install, test, and expose the Tekton pipeline + triggers (EventListener, TriggerBinding, TriggerTemplate) so GitHub webhooks automatically start pipeline runs on push/pull request triggers.

> **Namespace used in examples:** `sn-labs-ayoubchaieb7`
> Replace with your namespace when running commands.

---

## Files in this folder

```
.tekton/
├── clustertasks.yaml
├── tasks.yml
├── pipeline-output.yaml
├── pipelinerun.yaml
├── triggerbinding.yaml
├── triggertemplate.yaml
├── eventlistener.yaml
├── pvc.yaml
├── storageclass-skills-class-learner.yaml
├── namespace-sn-labs-ayoubchaieb7.yaml
├── README.md   <-- (this file)
```

---

## High-level architecture & flow

1. GitHub webhook → HTTP POST → **EventListener**
2. EventListener uses **TriggerBinding** to extract values from the webhook JSON (e.g. `repository.url`, `ref`)
3. EventListener invokes **TriggerTemplate** which creates a **PipelineRun** resource (populated with params from the binding)
4. Tekton executes `PipelineRun` → runs `Pipeline` tasks: clone, lint (flake8), tests (nose), build (buildah), deploy
5. Final `deploy` action uses `oc` (openshift-client) to create/update Kubernetes/Openshift Deployment

---

## Quick apply (one-shot)

Run `apply-all.sh`to get everything installed in your namespace

(equivalent to) running these commands in order:

```bash
OC_NS=sn-labs-ayoubchaieb7   # change to your namespace if different
oc project $OC_NS

# 1. Apply cluster tasks (buildah, git-clone, openshift-client, etc).
kubectl apply -f .tekton/clustertasks.yaml

# 2. Apply namespaced Tasks (cleanup, flake8, nose, etc)
kubectl apply -f .tekton/tasks.yml

# 3. Create storage (optional, required for PVC)
kubectl apply -f .tekton/storageclass-skills-class-learner.yaml   # only if needed in cluster
kubectl apply -f .tekton/pvc.yaml

# 4. Create Pipeline and resources
kubectl apply -f .tekton/pipeline-output.yaml
kubectl apply -f .tekton/pipelinerun.yaml   # optional: manual run manifest
kubectl apply -f .tekton/triggerbinding.yaml
kubectl apply -f .tekton/triggertemplate.yaml
kubectl apply -f .tekton/eventlistener.yaml

# 5. Verify
tkn pipeline ls
tkn pipelinerun ls
tkn task ls
tkn eventlistener ls
oc get svc -n $OC_NS
oc get route -n $OC_NS
```

---

## Files explained (dive-in)

### `clustertasks.yaml`

* Cluster-scoped reusable tasks (buildah, git-clone, openshift-client).
* Keep this file in repo — ephemeral clusters may not include these tasks by default; reapply when necessary.

### `tasks.yml`

* Namespace-scoped `Task` definitions used by the `Pipeline` (examples: `cleanup`, `flake8`, `nose`).
* Each `Task` uses `workspaces` so the pipeline steps share a PVC-backed directory.

### `pipeline-output.yaml`

* Tekton `Pipeline` (name: `output`)
* `params`:

  * `build-image` — target registry image (default points to OpenShift internal registry).
  * `app-name` — name for deployment.
* Task sequence typically: `cleanup` → `git-clone` → `flake8` → `nose` → `buildah` → `finally: deploy (openshift-client)`.
* Uses `workspaces` (bound to a PVC) so cloned sources are visible to subsequent tasks.

> Note: `finally` is used here to run a deploy step after the main tasks (if you want deploy only on success, move deploy to normal task order with `runAfter` logic).

### `pipelinerun.yaml`

* Example static `PipelineRun` pointing to `output` pipeline and binding the workspace to `pipelinerun-pvc`. Useful for manual runs and debugging.

### `triggerbinding.yaml`

This file maps incoming webhook JSON fields into Trigger params. Example (this file is already present in your folder):

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: cd-binding
spec:
  params:
    - name: repository
      value: $(body.repository.url)
    - name: branch
      value: $(body.ref)
```

### `triggertemplate.yaml`

This file creates a PipelineRun from the incoming params. Example (your version):

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: cd-template
spec:
  params:
    - name: repository
      description: The git repo
      default: " "
    - name: branch
      description: the branch for the git repo
      default: master
  resourcetemplates:
    - apiVersion: tekton.dev/v1beta1
      kind: PipelineRun
      metadata:
        generateName: triggered-cd-pipeline-run-
      spec:
        serviceAccountName: pipeline
        pipelineRef:
          name: output
        params:
          - name: repo-url
            value: $(tt.params.repository)
          - name: branch
            value: $(tt.params.branch)
        workspaces:
          - name: output
            persistentVolumeClaim:
              claimName: pipelinerun-pvc
```

**Important:** TriggerTemplate params do not have to match Pipeline param names — this template maps `repository` → `repo-url` for the pipeline.

### `eventlistener.yaml`

Defines the EventListener (`cd-listener`) that listens on HTTP and ties a TriggerBinding + TriggerTemplate to an incoming event:

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: cd-listener
spec:
  serviceAccountName: pipeline
  triggers:
    - bindings:
        - kind: TriggerBinding
          ref: cd-binding
      template:
        ref: cd-template
```

---

## Adding GitHub triggers — step-by-step (from the extra lab)

Follow these exact steps to add triggers and test them locally:

### 1) Ensure prerequisite tasks & pipeline are installed

If you haven't already, apply the `tasks.yaml` and your `pipeline-output.yaml`:

```bash
kubectl apply -f .tekton/tasks.yml
kubectl apply -f .tekton/pipeline-output.yaml
```

Confirm:

```bash
tkn task ls
tkn pipeline ls
```

### 2) Create `TriggerBinding` (cd-binding)

Apply `triggerbinding.yaml`:

```bash
kubectl apply -f .tekton/triggerbinding.yaml
```

This binds `body.repository.url` → `repository` and `body.ref` → `branch`.

### 3) Create `TriggerTemplate` (cd-template)

Apply `triggertemplate.yaml`:

```bash
kubectl apply -f .tekton/triggertemplate.yaml
```

This template will generate a `PipelineRun` for pipeline `output`, passing the `repo-url` param in.

### 4) Create `EventListener` (cd-listener)

Apply `eventlistener.yaml`:

```bash
kubectl apply -f .tekton/eventlistener.yaml
```

Confirm the EventListener exists:

```bash
tkn eventlistener ls
# expected output: cd-listener  ...  URL http://el-cd-listener.<namespace>.svc.cluster.local:8080
```

---

## Local test via `kubectl port-forward` + `curl` (recommended before setting GitHub webhook)

1. Port-forward EventListener to localhost:

```bash
# open terminal 1:
kubectl port-forward service/el-cd-listener 8090:8080 -n sn-labs-ayoubchaieb7
# or if service is named cd-listener:
# kubectl port-forward service/cd-listener 8090:8080 -n sn-labs-ayoubchaieb7
```

> Leave this running (it blocks). It maps `localhost:8090` → EventListener.

2. In a second terminal, POST a test payload (example from the lab):

```bash
curl -X POST http://localhost:8090 \
  -H 'Content-Type: application/json' \
  -d '{"ref":"main","repository":{"url":"https://github.com/ibm-developer-skills-network/wtecc-CICD_PracticeCode"}}'
```

3. Confirm a PipelineRun was created:

```bash
tkn pipelinerun ls -n sn-labs-ayoubchaieb7
# or get the last run:
tkn pipelinerun logs --last -n sn-labs-ayoubchaieb7 -f
```

Expected logs (trimmed) should show `git clone`, `flake8`, `tests`, `build`, `deploy` messages just like the lab.

---

## Expose EventListener & configure GitHub webhook (for real external trigger)

If you want GitHub to call your EventListener directly (instead of port-forward) you must expose it externally via an OpenShift Route (or Ingress):

```bash
# find EventListener service name:
oc get svc -n sn-labs-ayoubchaieb7

# expose the correct service (example names found in your history: el-cd-listener or cd-listener)
oc expose svc/el-cd-listener -n sn-labs-ayoubchaieb7
# or
oc expose svc/cd-listener -n sn-labs-ayoubchaieb7

# get the host:
oc get route -n sn-labs-ayoubchaieb7
# or:
oc get route cd-listener -n sn-labs-ayoubchaieb7 -o jsonpath='{.spec.host}'
```

**GitHub webhook configuration:**

* Repository → Settings → Webhooks → Add webhook

  * Payload URL: `http://<route-host>/`  (or `https://` if using TLS)
  * Content Type: `application/json`
  * Events: choose `Push` (and PR if you want)
* Save and test by pushing to repository or using GitHub's "Test webhook" button.

---

## How Trigger data maps to Pipeline params (summary)

* GitHub JSON `body.repository.url` → TriggerBinding `repository`
* TriggerTemplate has params `repository` and `branch`
* TriggerTemplate creates a PipelineRun and maps `$(tt.params.repository)` → pipeline param `repo-url` (your pipeline will expect `repo-url` or equivalent)
* Branch is passed as `branch` param (if pipeline needs it)

---

## Useful monitoring & debug commands

```bash
# list tekton resources
tkn pipeline ls -n sn-labs-ayoubchaieb7
tkn pipelinerun ls -n sn-labs-ayoubchaieb7
tkn task ls -n sn-labs-ayoubchaieb7
tkn clustertask ls

# eventlisteners
tkn eventlistener ls -n sn-labs-ayoubchaieb7

# inspect last pipelinerun logs
tkn pipelinerun logs --last -n sn-labs-ayoubchaieb7 -f

# show all pipelineruns
kubectl get pipelinerun -n sn-labs-ayoubchaieb7 -o wide

# describe failed taskrun
kubectl describe taskrun <taskrun-name> -n sn-labs-ayoubchaieb7

# view eventlistener logs (pod label might vary)
kubectl logs -l eventlistener=cd-listener -n sn-labs-ayoubchaieb7

# reapply cluster tasks if missing
kubectl apply -f .tekton/clustertasks.yaml
```

---

## Common failures & fixes

* **No PipelineRun created after webhook:** check EventListener URL and logs; ensure TriggerBinding & TriggerTemplate names match those referenced in EventListener.
* **`git-clone` failing:** confirm repo URL and network access; if private repo, attach credentials (SSH key or token) as Secret and configure ClusterTask or Task to use it.
* **`buildah` can't push:** verify target image registry and auth (use OpenShift internal registry to avoid extra secrets).
* **PVC problems:** run `kubectl get pvc` — if your PVC not bound, examine `storageclass` or use a pre-existing claim.
* **EventListener Route not accessible externally:** ensure route was created and cluster allows external routes; some sandbox clusters block external access.

---

## Security & best practices reminders

* Use Secrets for any tokens/credentials and mount them into tasks that require them.
* Limit service account RBAC to least privilege: `pipeline` SA should only have rights needed.
* Prefer explicit, immutable image tags for deployment.
* Separate CI (lint/tests) from CD (deploy) — run unit tests in CI and Tekton focus on CD if desired.

---

## Resume-ready bullets (what you implemented)

* Implemented Tekton `Pipeline` with modular `Task`s and ClusterTasks for `git-clone`, `buildah`, and `oc` deploy.
* Created `TriggerBinding`, `TriggerTemplate`, and `EventListener` to enable GitHub → Tekton event-driven CI/CD.
* Wired PVC-backed workspace for shared source between tasks.
* Exposed EventListener with OpenShift Route and validated GitHub webhook triggering `PipelineRun`.
* Documented a reproducible apply sequence, troubleshooting steps, and monitoring commands.

---

## Quick checklist to reproduce EVERYTHING

1. `oc project sn-labs-ayoubchaieb7`
2. `kubectl apply -f .tekton/clustertasks.yaml`
3. `kubectl apply -f .tekton/tasks.yml`
4. `kubectl apply -f .tekton/storageclass-skills-class-learner.yaml` (if needed)
5. `kubectl apply -f .tekton/pvc.yaml`
6. `kubectl apply -f .tekton/pipeline-output.yaml`
7. `kubectl apply -f .tekton/pipelinerun.yaml` (optional manual run)
8. `kubectl apply -f .tekton/triggerbinding.yaml`
9. `kubectl apply -f .tekton/triggertemplate.yaml`
10. `kubectl apply -f .tekton/eventlistener.yaml`
11. Expose EventListener route and add GitHub webhook or use `kubectl port-forward` + `curl` to test

## Helpful command snippets you can copy/paste
```bash
# Start a manual run using your pipelinerun manifest
kubectl apply -f .tekton/pipelinerun.yaml

# Tail logs
tkn pipelinerun logs pipelinerun-output -f

# Reapply ClusterTasks if they disappear
kubectl apply -f .tekton/clustertasks.yaml

# Expose EventListener (example name)
oc expose svc/el-cd-listener -n sn-labs-ayoubchaieb7
oc get route -n sn-labs-ayoubchaieb7 -o wide
```

---

## 🔁 Automated Deployment with `apply-all.sh` (Completed)

To streamline deployment and ensure **repeatable, error-free CI/CD setup**, an automation script named **`apply-all.sh`** was created and successfully used.
This script applies **all Tekton and OpenShift resources in the correct dependency order**, eliminating manual errors and accelerating environment setup.

---

### 🎯 Purpose of the Script

The `apply-all.sh` script was designed to:

* Enforce **correct resource application order**
* Reduce manual CLI work and human error
* Enable **rapid re-deployment** after sandbox resets
* Support both **manual PipelineRuns** and **GitHub webhook triggers**
* Provide a **single command bootstrap** for the entire CI/CD stack

This approach reflects real-world DevOps practices where infrastructure and pipelines are applied **as code**.

---

### 🧩 Resources Applied by the Script

The script applies the following components sequentially:

1. **ClusterTasks**

   * Reusable cluster-wide tasks (`git-clone`, `buildah`, `openshift-client`)
   * Enables standardized build and deployment logic

2. **Tekton Tasks**

   * Custom tasks such as `cleanup`, `flake8`, and `nose`
   * Enforces code quality, linting, and unit testing

3. **Storage Configuration**

   * `StorageClass`
   * `PersistentVolumeClaim (PVC)`
   * Ensures shared workspace persistence across pipeline tasks

4. **Pipeline Definition**

   * Complete CI/CD pipeline from source clone → test → build → deploy
   * Uses `finally` task to deploy application regardless of pipeline outcome

5. **Triggers & Event Handling**

   * `TriggerBinding`
   * `TriggerTemplate`
   * `EventListener`
   * Enables GitHub webhook-based automation

6. **Optional PipelineRun**

   * Allows manual pipeline execution for testing and validation

---

### ▶️ Script Usage

Make the script executable:

```bash
chmod +x apply-all.sh
```

Apply all Tekton resources to the target namespace:

```bash
./apply-all.sh --namespace sn-labs-ayoubchaieb7
```

Apply resources **and expose the EventListener** via OpenShift Route:

```bash
./apply-all.sh --namespace sn-labs-ayoubchaieb7 --expose-eventlistener
```

Run a **manual PipelineRun** after setup:

```bash
./apply-all.sh --namespace sn-labs-ayoubchaieb7 --run-pipelinerun
```

---

### 🌐 GitHub Webhook Enablement

When the `--expose-eventlistener` flag is used:

* The script exposes the EventListener service using:

  ```bash
  oc expose svc/<eventlistener-service>
  ```
* The generated **Route URL** is printed
* This URL is used as the **GitHub webhook Payload URL**
* Any `push` event automatically triggers a new `PipelineRun`

This confirms **end-to-end CI/CD automation** from GitHub commit to OpenShift deployment.

---

### 🧪 Local Trigger Testing (Port Forward)

The script can also prepare the environment for **local webhook testing**:

```bash
./apply-all.sh --port-forward-test
```

This enables:

* Port-forwarding the EventListener to `localhost:8090`
* Manual `curl` POST testing with a simulated GitHub payload

---

### 🏆 Outcome & Skills Demonstrated

By implementing and using `apply-all.sh`, this project demonstrates:

* Infrastructure as Code (IaC) mindset
* Advanced Tekton resource orchestration
* CI/CD automation best practices
* GitHub-to-OpenShift event-driven pipelines
* Production-grade DevOps scripting and tooling

This script transforms the project from a **manual lab exercise** into a **reproducible, enterprise-style CI/CD system**.
