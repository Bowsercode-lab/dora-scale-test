# DORA and CI/CD queries (DataPrime)

All queries read the records that `report-deploy` and `approval-watch` send (application `cicd`) and, for CI/CD, the GitHub V2 events. Use them as dashboard widgets (Custom Dashboards, DataPrime query widget) or in Explore. Add `| filter $d.dora.team == '<team>'` (or `service`, `project_path`) for a team, service or monorepo-folder view; on a dashboard, make those dashboard variables.

Checked on 2026-11-16 against live lab records in Bowserlab (GitHub V2 events, `report-deploy`, `approval-watch` and a replayed Datadog incident). With the `cx` CLI, run these with `--tier archive`: right after a new integration starts, the default tier can return zero rows for filters and groupbys on the new fields while the UI and archive return them. Ready-made dashboards: `dashboards/dora-cardlytics.json` and `dashboards/cicd-cardlytics.json`.

## Deployment records (one per deploy)

Base filter used below as `<DEPLOYS>`:

```
source logs
| filter $l.applicationname == 'cicd' && $l.subsystemname == 'deployments'
| filter $d.dora.event_type == 'deployment' && $d.dora.env == 'prod'
```

**Deployment frequency (G1):** successful prod deploys per week, by team.

```
<DEPLOYS>
| filter $d.dora.outcome == 'success'
| groupby $d.dora.finished_at:timestamp.roundTime(7d) as week, $d.dora.team as team aggregate count() as deploys
```

**Change failure rate (G1, G8):** percent of deploys that needed remediation (a rollback, a `Revert` PR or a `hotfix` PR marks the deploy before it as failed).

```
<DEPLOYS>
| filter $d.dora.outcome == 'success'
| groupby $d.dora.team as team aggregate
    count() as deploys,
    sum(if($d.dora.remediation == true, 1, 0)) as remediations,
    sum(if($d.dora.remediation == true, 1, 0)) / count() * 100 as change_failure_rate_pct
```

**Failed deployment recovery time (G1):** median hours from the failed deploy to the remediating deploy.

```
<DEPLOYS>
| filter $d.dora.remediation == true && $d.dora.recovery_seconds != null
| groupby $d.dora.team as team aggregate percentile(0.5, $d.dora.recovery_seconds:num) / 3600 as median_recovery_hours
```

**Batch size and AI-assisted share (G10):**

```
<DEPLOYS>
| filter $d.dora.outcome == 'success'
| groupby $d.dora.team as team aggregate
    percentile(0.5, $d.dora.batch_size:num) as median_batch_size,
    sum($d.dora.ai_assisted_commits:num) / sum($d.dora.batch_size:num) * 100 as ai_assisted_commit_pct
```

**Failed deploy jobs (CI health of the deploy step itself, not DORA):**

```
<DEPLOYS>
| groupby $d.dora.service as service aggregate count() as runs, sum(if($d.dora.outcome == 'failure', 1, 0)) as failed_runs
```

## Change records (one per pull request in a deploy)

**Change lead time (G1, G3):** median days from first commit to production, by team.

```
source logs
| filter $l.applicationname == 'cicd' && $d.dora.event_type == 'change' && $d.dora.env == 'prod'
| groupby $d.dora.team as team aggregate percentile(0.5, $d.dora.lead_time_seconds:num) / 86400 as median_lead_time_days
```

**Stage breakdown (G3):** where the lead time goes, same five stages as Datadog.

```
source logs
| filter $l.applicationname == 'cicd' && $d.dora.event_type == 'change' && $d.dora.env == 'prod'
| groupby $d.dora.team as team aggregate
    percentile(0.5, $d.dora.stages_seconds.time_to_pr_ready:num) / 3600 as time_to_pr_ready_h,
    percentile(0.5, $d.dora.stages_seconds.review_time:num) / 3600 as review_time_h,
    percentile(0.5, $d.dora.stages_seconds.merge_time:num) / 3600 as merge_time_h,
    percentile(0.5, $d.dora.stages_seconds.time_to_deploy:num) / 3600 as time_to_deploy_h,
    percentile(0.5, $d.dora.stages_seconds.deploy_time:num) / 3600 as deploy_time_h
```

**Before and after a date (G10, for example a new AI tool or the monorepo move):** set the dashboard time range to each period, or:

```
source logs
| filter $l.applicationname == 'cicd' && $d.dora.event_type == 'change' && $d.dora.env == 'prod'
| create period from if($d.dora.merged_at:timestamp < '2026-09-01T00:00:00Z':timestamp, 'before', 'after')
| groupby period aggregate percentile(0.5, $d.dora.lead_time_seconds:num) / 86400 as median_lead_time_days, count() as changes
```

## Approval waits (G7)

**Deployments waiting on approval right now** (from `approval-watch`, every 30 minutes):

```
source logs
| filter $l.applicationname == 'cicd' && $l.subsystemname == 'approvals' && $d.dora.event_type == 'approval_pending'
| groupby $d.dora.run_url as run, $d.dora.workflow as workflow aggregate max($d.dora.wait_hours:num) as waiting_hours
```

Alert: a logs threshold alert on application `cicd`, subsystem `approvals`, Lucene `dora.event_type:"approval_pending" AND dora.wait_hours:[24 TO *]` (set N from Q8), more than 0 matches in 1 hour, grouped by `$d.dora.workflow`. It fires while the job is still waiting.

## CI/CD from GitHub V2 (G4)


**Pipelines by workflow file.** Run names can change on every run (for example "CI: PR #123 by @user"), so group pipelines by the workflow file path, not the name:

```
source logs
| filter $l.applicationname == 'github' && $d.github_event == 'workflow_run' && $d['github-app-v2'].action == 'completed'
| create duration_seconds from ($d['github-app-v2'].workflow_run.updated_at:timestamp - $d['github-app-v2'].workflow_run.run_started_at:timestamp):num / 1000000000
| groupby $d['github-app-v2'].repository.full_name as repository, $d['github-app-v2'].workflow_run.path as workflow_file aggregate count() as runs, sum(if($d['github-app-v2'].workflow_run.conclusion == 'failure', 1, 0)) as failures, sum(if($d['github-app-v2'].workflow_run.run_attempt:num > 1, 1, 0)) as reruns, percentile(0.5, duration_seconds) as median_seconds, percentile(0.95, duration_seconds) as p95_seconds
| create failure_pct from if(runs > 0, failures / runs * 100, 0)
| orderby failure_pct desc
| choose workflow_file, repository, runs, failures, failure_pct, reruns, median_seconds, p95_seconds
```

**CI runs by team.** Takes the team from the run title (deploy folder, release service, or `service@v<version>`), else the repository, and looks it up in the `cdlx_ownership` table at query time (WB13 Step 3):

```
source logs
| filter $l.applicationname == 'github' && $d.github_event == 'workflow_run' && $d['github-app-v2'].action == 'completed'
| create duration_seconds from ($d['github-app-v2'].workflow_run.updated_at:timestamp - $d['github-app-v2'].workflow_run.run_started_at:timestamp):num / 1000000000
| create run_title from $d['github-app-v2'].workflow_run.display_title
| extract run_title into parsed using regexp(e=/^(?:Deploy (?<folder>\S+)|Release (?<service>\S+)|(?<helm>[A-Za-z0-9_.-]+)@v\d)/)
| create owner_key from firstNonNull(parsed.folder, parsed.service, parsed.helm, $d['github-app-v2'].repository.name)
| enrich owner_key into owner using cdlx_ownership
| groupby owner.team as team, $d['github-app-v2'].workflow_run.path as workflow_file aggregate count() as runs, sum(if($d['github-app-v2'].workflow_run.conclusion == 'failure', 1, 0)) as failures, sum(if($d['github-app-v2'].workflow_run.run_attempt:num > 1, 1, 0)) as reruns, percentile(0.5, duration_seconds) as median_seconds, percentile(0.95, duration_seconds) as p95_seconds
| create failure_pct from if(runs > 0, failures / runs * 100, 0)
| orderby runs desc
| choose team, workflow_file, runs, failures, failure_pct, median_seconds
```

GitHub V2 events arrive with application `github`, subsystem = the GitHub org name (case kept, for example `Bowsercode-lab`), `$d.github_event` = the event type and `$d['github-app-v2']` = the unmodified webhook payload (docs: coralogix.com/docs/integrations/pull/github/). The key has a hyphen, so always use the bracket form `$d['github-app-v2'].workflow_run.name`; `$d.github...` does not exist. Workflow metrics come from the **Workflow metrics** toggle on the same integration and count completed runs and jobs only.

**CI Health parity from metrics (PromQL):**

```
# Runs per workflow, last 7 days, split by conclusion
sum by (repository, workflow, conclusion) (increase(github_workflow_run_total[7d]))

# Failure rate per workflow, last 7 days (percent)
100 * sum by (repository, workflow) (increase(github_workflow_run_total{conclusion="failure"}[7d]))
    / sum by (repository, workflow) (increase(github_workflow_run_total[7d]))

# Median and p95 time to finish per workflow, last 7 days (seconds)
histogram_quantile(0.5,  sum by (workflow, le) (increase(github_workflow_run_duration_seconds_bucket[7d])))
histogram_quantile(0.95, sum by (workflow, le) (increase(github_workflow_run_duration_seconds_bucket[7d])))

# Runner queue time (job created to job started), p95 by runner label, last 24 hours
histogram_quantile(0.95, sum by (runner, le) (increase(github_workflow_job_queue_duration_seconds_bucket[24h])))
```

**Restarts to pass (from events):** a re-run is a `workflow_run` completion with `run_attempt` above 1.

```
source logs
| filter $l.applicationname == 'github' && $d.github_event == 'workflow_run' && $d['github-app-v2'].action == 'completed'
| groupby $d['github-app-v2'].repository.full_name as repo, $d['github-app-v2'].workflow_run.name as workflow aggregate
    count() as completions,
    sum(if($d['github-app-v2'].workflow_run.run_attempt:num > 1, 1, 0)) as reruns,
    sum(if($d['github-app-v2'].workflow_run.conclusion == 'failure', 1, 0)) as failures
```

**Jobs waiting for approval (event view, complements `approval-watch`):**

```
source logs
| filter $l.applicationname == 'github' && $d.github_event == 'workflow_job' && $d['github-app-v2'].action == 'waiting'
| choose $m.timestamp, $d['github-app-v2'].repository.full_name, $d['github-app-v2'].workflow_job.workflow_name, $d['github-app-v2'].workflow_job.name, $d['github-app-v2'].workflow_job.html_url
```

**Monorepo folder (G9):** the deployment and change records carry `project_path`. For CI runs, name workflows per project (as `cdlx` already does: "Deploy FileManager on Change") and map workflow name to project and team with the ownership enrichment table (WB13 Step 5).

## ARC runners (G4, G12)

After the collector scrapes the ARC listener and controller metrics (Workbook 14). Checked live on 2026-11-16 (ARC 0.15.1). Counters arrive with a doubled `_total` suffix; gauges and histograms keep their names. Dashboard: `dashboards/arc-cardlytics.json`.

```
sum by (name) (gha_desired_runners) - sum by (name) (gha_assigned_jobs)     # the "phase shift" Matt watches
sum by (name) (gha_busy_runners)
sum by (name) (gha_idle_runners)
sum by (repository) (increase(gha_started_jobs_total_total[1h]))            # jobs started (job metrics carry repository and job_name, not name)
histogram_quantile(0.95, sum by (repository, le) (rate(gha_job_startup_duration_seconds_bucket[1h])))   # per job_name series; fills from a job's second run
```

## Incidents from Datadog (G8)

Records from the Datadog webhook (application `cicd`, subsystem `incidents`; setup in `../datadog/incident-webhook.md`). `fields.services` is an array, so explode it before grouping by service. Check the services and teams keys inside `fields` against the first real Datadog payload.

**Incidents per service (counts toward change failure when the service deployed in the 24 hours before):**

```
source logs
| filter $l.applicationname == 'cicd' && $l.subsystemname == 'incidents' && $d.incident.status == 'active'
| explode $d.incident.fields.services into service original preserve
| groupby service aggregate distinct_count($d.incident.public_id) as incidents
```

**Incident recovery time (declared to resolved), median hours:**

```
source logs
| filter $l.applicationname == 'cicd' && $l.subsystemname == 'incidents'
| groupby $d.incident.public_id as incident aggregate
    min(if($d.incident.status == 'active', $d.event_date:timestamp, null)) as declared,
    max(if($d.incident.status == 'resolved', $d.event_date:timestamp, null)) as resolved
| filter resolved != null && declared != null
| create recovery_h from (resolved - declared):num / 3600000000000
| aggregate percentile(0.5, recovery_h) as median_recovery_hours
```
