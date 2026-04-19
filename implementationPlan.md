# Implementation Plan: CI/CD Pipeline & Helm Label Fixes

## 1. Overview
The current CI/CD pipeline and Helm deployments for the AM-Portfolio microservices are failing. The root cause is a Kubernetes metadata validation error stemming from incorrectly generated Helm labels. Additionally, logical flaws in the GitHub Actions pipeline have tightly coupled the environments, causing the failure in Dev to permanently block Preprod and Prod deployments.

## 2. Root Causes
* **Dev Failure**: In an attempt to automatically name the Helm release, the `app.kubernetes.io/name` label is defaulting to the image repository (`ghcr.io/am-portfolio/am-portfolio`). Kubernetes explicitly forbids the forward slash (`/`) character in label values, causing the deployment to be rejected.
* **Preprod Blocking**: Inside `central-build-publish.yml`, the `deploy-preprod` job is configured to only run if `deploy-dev` succeeds (`needs.deploy-dev.result == 'success'`). Because Dev consistently fails due to the label error, Preprod is unconditionally blocked.
* **Invalid Helm Labels**: The `_helpers.tpl` file inside `am-pipelines/helm/universal-chart` does not correctly check for or apply `.Values.nameOverride`, automatically falling back to `.Values.image.repository`.

## 3. Pipeline Issues
* **Dev Dependency Problem**: `deploy-preprod` expects the dev environment rollout to complete successfully before giving approval for staging.
* **Missing Feature Toggle**: There is no boolean flag to gracefully disable Dev deployments without modifying the workflow structure. It blindly attempts to deploy to dev if an image name is provided.

## 4. Helm Issues
* **`_helpers.tpl` using image.repository incorrectly**: In `am-pipelines/helm/universal-chart/templates/_helpers.tpl`, the templates for `.name` and `.fullname` evaluate to `.Values.image.repository`.

## 5. Proposed Fixes

### Pipeline Fixes (in `am-pipelines`)
* **Add `enable_dev` flag**: Add a boolean input (`enable_dev` defaulting to `false`) to `central-build-publish.yml`.
* **Remove dependency on Dev**: Update the `if:` condition in `deploy-preprod` to decouple it from `deploy-dev`'s status, ensuring Preprod relies only on the completion of the security and build steps.
* **Enforce Flow**: The new sequence will natively be Build & Security Scans → Preprod → Prod. Dev can run parallelly if toggled on, but will not block the main promotion pathway.
* **Runner Assignment**: Enforce the runner definition for all deployment blocks to be: `runs-on: docker-runner-github-runner-6d445b6f69-xz6jb`.

### Helm Fixes (in `am-portfolio` and `am-pipelines`)
* **Add Overrides**: Add `nameOverride: am-portfolio` and `fullnameOverride: am-portfolio` to `values.yaml`, `values.dev.yaml`, `values.preprod.yaml`, and `values.prod.yaml` in the am-portfolio repository.
* **Fix Helper Template**: Refactor the `.name` and `.fullname` helpers within `am-pipelines/helm/universal-chart/templates/_helpers.tpl` to correctly utilize standard Helm defaulting logic, averting falling back to the docker registry URI.

### Workflow Fix (in `am-portfolio`)
* **Update am-portfolio workflow**: Modify `am-portfolio-publish.yml` to inject the new variables into the central pipeline:
```yaml
    with:
      image_name: 'am-portfolio'
      enable_dev: false
      deploy_prod: false
```

## 6. Expected Outcome
* **Dev Optional**: The workflow executes cleanly without Dev running unless explicitly requested.
* **Preprod Working**: Bypassing the faulty Dev gate immediately unlocks the Preprod deployments.
* **No Label Errors**: Explicitly declaring names resolves the Kubernetes label violations (`ghcr.io/...`).
