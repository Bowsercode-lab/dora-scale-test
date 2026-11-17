# dora-lab: scaffold for WB13 (DORA and CI/CD)

A miniature of `cardlytics/cdlx` to push to a sandbox GitHub org and run WB13 against Bowserlab. Test plan: `../../test-plans/dora-lab-test-plan.md`.

| Path | What it is |
|---|---|
| `apps/ads-manager-ui`, `services/aura-api`, `data/jobs` | Three monorepo projects (stand-ins). `FLAKY` / `FAIL_DEPLOY` files toggle CI flakiness and deploy failure |
| `.github/actions/report-deploy/` | The deploy step: 1 deployment record + 1 change record per PR to Coralogix logs, plus an APM deploy marker. `DRY_RUN=1` prints the records |
| `.github/actions/approval-watch/` | Reports deployments waiting on approval, with wait time |
| `.github/workflows/_deploy.yml` | Reusable deploy workflow; the only place `report-deploy` is called |
| `.github/workflows/deploy-*.yml`, `ci-*.yml` | Path-filtered deploy and CI per project |
| `.github/workflows/approval-watch.yml` | Cron every 30 minutes |
| `coralogix/dora-queries.md` | DataPrime and PromQL for the dashboards and alert |
| `datadog/` | Datadog incident webhook setup + sample payload |
| `k8s/` | ARC metrics scrape (chart values + PodMonitors) |

Dry run against any public repo:

```bash
SERVICE=frontend TEAM=dd-demo PROJECT_PATH=src/frontend DEPLOY_ENV=prod DEPLOY_STATUS=success \
GITHUB_REPOSITORY=open-telemetry/opentelemetry-demo GITHUB_SHA=<sha> PREVIOUS_SHA=<older sha> DRY_RUN=1 \
  .github/actions/report-deploy/report-deploy.sh
```
