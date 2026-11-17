#!/usr/bin/env bash
# report-deploy.sh: send one DORA deployment record (plus one change record per pull request)
# to Coralogix after a production deploy. This is the ONLY deploy source per service.
#
# Required env:
#   SERVICE, TEAM, PROJECT_PATH, DEPLOY_ENV, DEPLOY_STATUS (success|failure)
#   GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_RUN_ID, GITHUB_SERVER_URL, GH_TOKEN (contents:write)
#   CX_LOGS_URL      e.g. https://ingress.us2.coralogix.com/logs/v1/singles
#   CX_API_KEY       Coralogix Send-Your-Data API key
# Optional env:
#   VERSION (default: short SHA), DEPLOY_STARTED_AT (ISO 8601, default: run start), DEPLOY_FINISHED_AT (default: now),
#   ROLLBACK (true|false, default false), PREVIOUS_SHA (override the deploy-tag lookup),
#   CX_APPLICATION (default cicd),
#   CX_OPS_EVENTS_URL + CX_OPS_EVENTS_KEY (OpsEvents preset) to also send an APM deployment marker,
#   CX_SUBSYSTEM (default deployments), DRY_RUN=1 (print records, send nothing, move no tag)
set -euo pipefail

: "${SERVICE:?}" "${TEAM:?}" "${PROJECT_PATH:?}" "${DEPLOY_ENV:?}" "${DEPLOY_STATUS:?}"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}"
API="${GITHUB_API_URL:-https://api.github.com}"
REPO="$GITHUB_REPOSITORY"
SHA="$GITHUB_SHA"
VERSION="${VERSION:-${SHA:0:12}}"
APP="${CX_APPLICATION:-cicd}"
SUB="${CX_SUBSYSTEM:-deployments}"
ROLLBACK="${ROLLBACK:-false}"
NOW="${DEPLOY_FINISHED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"   # deploy end; the deploy job passes it when the report runs as a later job
TAG="deploy/${DEPLOY_ENV}/${SERVICE}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-0}"

gh_api() {  # gh_api PATH [extra curl args]
  local path="$1"; shift
  curl -fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} "$@" "${API}${path}"
}
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s; }
secs_between() { if [[ -n "$1" && -n "$2" && "$1" != null && "$2" != null ]]; then echo $(( $(epoch "$2") - $(epoch "$1") )); else echo null; fi; }

# Deploy start: the workflow run's start time unless the caller passes one.
if [[ -z "${DEPLOY_STARTED_AT:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  DEPLOY_STARTED_AT="$(gh_api "/repos/${REPO}/actions/runs/${GITHUB_RUN_ID}" | jq -r '.run_started_at // empty' || true)"
fi
DEPLOY_STARTED_AT="${DEPLOY_STARTED_AT:-$NOW}"

# 1. Previous successful deploy of this service to this env = the annotated tag deploy/<env>/<service>.
PREV_SHA=""; PREV_FINISHED_AT=""
if ref_json="$(gh_api "/repos/${REPO}/git/ref/tags/${TAG}" 2>/dev/null)"; then
  obj_type="$(jq -r '.object.type' <<<"$ref_json")"; obj_sha="$(jq -r '.object.sha' <<<"$ref_json")"
  if [[ "$obj_type" == "tag" ]]; then
    tag_json="$(gh_api "/repos/${REPO}/git/tags/${obj_sha}")"
    PREV_SHA="$(jq -r '.object.sha' <<<"$tag_json")"
    PREV_FINISHED_AT="$(jq -r '.message | fromjson? | .finished_at // empty' <<<"$tag_json")"
  else
    PREV_SHA="$obj_sha"
  fi
fi
# Seeding or testing: PREVIOUS_SHA overrides the tag lookup (for example, the commit Datadog last saw deployed).
PREV_SHA="${PREVIOUS_SHA:-$PREV_SHA}"

# 2. Commits in this deploy (previous deploy..this SHA). First deploy of a service = head commit only.
# GitHub returns at most 250 commits per comparison unless it is paged, so both lists below are paged.
MAX_COMMITS="${MAX_COMMITS:-3000}"; TRUNCATED=false
COMMIT_FIELDS='{sha, date: .commit.author.date, cdate: .commit.committer.date, message: (.commit.message | split("\n")[0]),
                ai_trailer: (.commit.message | test("(?i)co-authored-by:.*(claude|copilot|cursor|codex|devin|openai)"))}'
COMPARE_STATUS="first_deploy"
if [[ -n "$PREV_SHA" && "$PREV_SHA" != "$SHA" ]]; then
  cmp="$(gh_api "/repos/${REPO}/compare/${PREV_SHA}...${SHA}?per_page=100&page=1")"
  COMPARE_STATUS="$(jq -r '.status' <<<"$cmp")"            # ahead | behind | diverged | identical
  TOTAL="$(jq -r '.total_commits // 0' <<<"$cmp")"
  COMMITS="$(jq -c "[.commits[] | ${COMMIT_FIELDS}]" <<<"$cmp")"
  page=2
  while (( $(jq 'length' <<<"$COMMITS") < TOTAL && $(jq 'length' <<<"$COMMITS") < MAX_COMMITS )); do
    more="$(gh_api "/repos/${REPO}/compare/${PREV_SHA}...${SHA}?per_page=100&page=${page}" | jq -c "[.commits[] | ${COMMIT_FIELDS}]")"
    [[ "$(jq 'length' <<<"$more")" == 0 ]] && break
    COMMITS="$(jq -c --argjson more "$more" '. + $more'   # pages do not overlap; keep oldest-first order <<<"$COMMITS")"
    page=$((page + 1))
  done
  if (( $(jq 'length' <<<"$COMMITS") < TOTAL )); then
    TRUNCATED=true
    echo "::warning::Deploy has ${TOTAL} commits; only $(jq 'length' <<<"$COMMITS") were read. Batch size and lead time may be low."
  fi
elif [[ "$PREV_SHA" == "$SHA" ]]; then
  COMPARE_STATUS="identical"; COMMITS="[]"
else
  COMMITS="$(gh_api "/repos/${REPO}/commits/${SHA}" | jq -c "[${COMMIT_FIELDS}]")"
fi
# Monorepo: keep only commits that touch this project's folder, so another project's PRs (and repo-wide
# commits such as workflow edits) never count toward this service's batch size or change records.
# The folder's history is paged back to the oldest commit date in the deploy, so nothing in the deploy is missed.
if [[ -n "${PROJECT_PATH:-}" && "$COMPARE_STATUS" =~ ^(ahead|diverged)$ && "$(jq 'length' <<<"$COMMITS")" != 0 ]]; then
  SINCE="$(jq -r '[.[].cdate] | min' <<<"$COMMITS")"
  PATH_SHAS="[]"; page=1
  while (( $(jq 'length' <<<"$PATH_SHAS") < MAX_COMMITS )); do
    batch="$(gh_api "/repos/${REPO}/commits?sha=${SHA}&path=${PROJECT_PATH}&since=${SINCE}&per_page=100&page=${page}")"
    [[ "$(jq 'length' <<<"$batch")" == 0 ]] && break
    PATH_SHAS="$(jq -c --argjson b "$batch" '. + [$b[] | select((.parents | length) == 1) | .sha]' <<<"$PATH_SHAS")"   # authored commits, not merge commits
    [[ "$(jq 'length' <<<"$batch")" -lt 100 ]] && break
    page=$((page + 1))
  done
  COMMITS="$(jq -c --argjson keep "$PATH_SHAS" '[.[] | select(.sha as $s | $keep | index($s))]' <<<"$COMMITS")"
fi
COMMITS="$(jq -c 'map(del(.cdate))' <<<"$COMMITS")"
# A deploy of an older commit than the last one is a rollback even if nobody said so.
[[ "$COMPARE_STATUS" == "behind" ]] && ROLLBACK=true

# A re-run of a deploy that already reported (same commit, later attempt) is not a new deployment.
if [[ "${GITHUB_RUN_ATTEMPT:-1}" -gt 1 && "$COMPARE_STATUS" == "identical" && "$ROLLBACK" != true ]]; then
  echo "Re-run of an already reported deploy of ${SERVICE} ${VERSION}: nothing sent."
  exit 0
fi

# 3. Pull requests behind those commits, with Datadog-style lead-time stages.
CHANGES="[]"; HOTFIX=false; REVERT=false
MAX_PR_COMMITS=50
if (( $(jq 'length' <<<"$COMMITS") > MAX_PR_COMMITS )); then
  TRUNCATED=true
  echo "::warning::Deploy has $(jq 'length' <<<"$COMMITS") commits in ${PROJECT_PATH}; pull requests are read for the newest ${MAX_PR_COMMITS} only."
fi
for csha in $(jq -r '.[].sha' <<<"$COMMITS" | tail -n "$MAX_PR_COMMITS"); do
  for pr in $(gh_api "/repos/${REPO}/commits/${csha}/pulls" | jq -r '.[] | select(.merged_at != null) | .number'); do
    jq -e --argjson n "$pr" 'any(.[]; .pr == $n)' <<<"$CHANGES" >/dev/null && continue
    p="$(gh_api "/repos/${REPO}/pulls/${pr}")"
    first_commit_at="$(gh_api "/repos/${REPO}/pulls/${pr}/commits?per_page=100" | jq -r '[.[].commit.author.date] | min')"
    ready_at="$(gh_api "/repos/${REPO}/issues/${pr}/timeline?per_page=100" \
                | jq -r '[.[] | select(.event == "ready_for_review") | .created_at] | first // empty')"
    [[ -z "$ready_at" ]] && ready_at="$(jq -r '.created_at' <<<"$p")"
    first_review_at="$(gh_api "/repos/${REPO}/pulls/${pr}/reviews?per_page=100" | jq -r '[.[].submitted_at | select(. != null)] | min // empty')"
    merged_at="$(jq -r '.merged_at' <<<"$p")"
    title="$(jq -r '.title' <<<"$p")"
    labels="$(jq -c '[.labels[].name]' <<<"$p")"
    jq -e 'index("hotfix")' <<<"$labels" >/dev/null && HOTFIX=true
    [[ "$title" == Revert* ]] && REVERT=true
    review_from="${first_review_at:-$merged_at}"
    CHANGES="$(jq -c --argjson pr "$pr" --arg title "$title" --argjson labels "$labels" \
      --arg author "$(jq -r '.user.login' <<<"$p")" --arg author_type "$(jq -r '.user.type' <<<"$p")" \
      --arg first_commit_at "$first_commit_at" --arg ready_at "$ready_at" --arg first_review_at "$first_review_at" --arg merged_at "$merged_at" \
      --argjson time_to_pr_ready "$(secs_between "$first_commit_at" "$ready_at")" \
      --argjson review_time "$(secs_between "$ready_at" "$review_from")" \
      --argjson merge_time "$(secs_between "$review_from" "$merged_at")" \
      --argjson time_to_deploy "$(secs_between "$merged_at" "$DEPLOY_STARTED_AT")" \
      --argjson deploy_time "$(secs_between "$DEPLOY_STARTED_AT" "$NOW")" \
      --argjson lead_time "$(secs_between "$first_commit_at" "$NOW")" \
      '. + [{pr: $pr, title: $title, labels: $labels, author: $author, author_type: $author_type,
             first_commit_at: $first_commit_at, ready_at: $ready_at, first_review_at: $first_review_at, merged_at: $merged_at,
             stages_seconds: {time_to_pr_ready: $time_to_pr_ready, review_time: $review_time, merge_time: $merge_time,
                              time_to_deploy: $time_to_deploy, deploy_time: $deploy_time},
             lead_time_seconds: $lead_time}]' <<<"$CHANGES")"
  done
done

# 4. Remediation: a rollback, a revert PR or a hotfix-labelled PR marks the PREVIOUS deploy as a failed change.
REMEDIATION=false; RECOVERY_SECONDS=null
if [[ "$ROLLBACK" == true || "$REVERT" == true || "$HOTFIX" == true ]]; then
  REMEDIATION=true
  [[ -n "$PREV_FINISHED_AT" ]] && RECOVERY_SECONDS="$(secs_between "$PREV_FINISHED_AT" "$NOW")"
fi

# The Coralogix "Dora Metrics" extension reads GitHub workflow_run-shaped fields under $d.github and counts every
# completed run as a deployment. Give the deployment record (only) that shape so the extension and the custom
# dashboards read the same source. Lead time starts at the first commit of the earliest PR in the deploy.
LEAD_FROM="$(jq -r '[.[].first_commit_at | select(. != null and . != "")] | min // empty' <<<"$CHANGES")"
[[ -z "$LEAD_FROM" ]] && LEAD_FROM="$(gh_api "/repos/${REPO}/commits/${SHA}" | jq -r '.commit.author.date // empty' || true)"

DEPLOY="$(jq -n --arg service "$SERVICE" --arg team "$TEAM" --arg project_path "$PROJECT_PATH" --arg env "$DEPLOY_ENV" \
  --arg lead_from "$LEAD_FROM" \
  --arg version "$VERSION" --arg sha "$SHA" --arg repo "$REPO" --arg run_url "$RUN_URL" --arg outcome "$DEPLOY_STATUS" \
  --arg started_at "$DEPLOY_STARTED_AT" --arg finished_at "$NOW" --arg previous_sha "$PREV_SHA" --arg compare "$COMPARE_STATUS" \
  --argjson rollback "$ROLLBACK" --argjson revert "$REVERT" --argjson hotfix "$HOTFIX" --argjson remediation "$REMEDIATION" \
  --argjson recovery_seconds "$RECOVERY_SECONDS" --argjson truncated "$TRUNCATED" --argjson commits "$COMMITS" --argjson changes "$CHANGES" \
  '{dora: {event_type: "deployment", service: $service, team: $team, project_path: $project_path, env: $env,
           version: $version, sha: $sha, repo: $repo, run_url: $run_url, outcome: $outcome,
           started_at: $started_at, finished_at: $finished_at, previous_sha: $previous_sha, compare: $compare,
           batch_size: ($commits | length), pr_count: ($changes | length),
           ai_assisted_commits: ([$commits[] | select(.ai_trailer)] | length),
           rollback: $rollback, revert: $revert, hotfix: $hotfix,
           remediation: $remediation, remediates_sha: (if $remediation then $previous_sha else null end),
           recovery_seconds: $recovery_seconds, truncated: $truncated},
   github: {repository: {name: ($repo | split("/")[1])},
            workflow_run: {status: "completed", conclusion: (if $outcome == "success" then "success" else "failure" end),
                           head_commit: {timestamp: (if $lead_from == "" then null else $lead_from end)},
                           repository: {name: ($repo | split("/")[1])},
                           name: $service, html_url: $run_url, head_sha: $sha}}}')"

# One change record per PR so lead time and its stage breakdown are plain per-row fields.
RECORDS="$(jq -c --argjson d "$DEPLOY" --argjson changes "$CHANGES" -n '
  [$d] + [ $changes[] | {dora: ({event_type: "change"} + ($d.dora | {service, team, project_path, env, version, sha, repo, run_url, outcome}) + .)} ]')"

send() {  # Coralogix REST singles: an array of {applicationName, subsystemName, severity, text}
  jq -c --arg app "$APP" --arg sub "$SUB" '[.[] | {applicationName: $app, subsystemName: $sub, severity: 3, text: (. | tojson)}]' <<<"$RECORDS"
}

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  jq '.' <<<"$RECORDS"; exit 0
fi

# Only a successful deploy counts as a deployment and moves the deploy tag.
send | curl -fsS -X POST "$CX_LOGS_URL" -H "Content-Type: application/json" -H "Authorization: Bearer ${CX_API_KEY}" --data-binary @- >/dev/null
echo "Sent 1 deployment + $(jq 'length' <<<"$CHANGES") change record(s) for ${SERVICE} ${VERSION} (${DEPLOY_STATUS})."

# APM deployment marker (ops-events API). Needs its own key with the OpsEvents preset; skipped if not set.
# service.name and environment must equal the APM service.name and deployment.environment.name.
if [[ -n "${CX_OPS_EVENTS_URL:-}" && -n "${CX_OPS_EVENTS_KEY:-}" ]]; then
  result="PIPELINE_RESULT_STATUS_SUCCESS"; [[ "$DEPLOY_STATUS" != success ]] && result="PIPELINE_RESULT_STATUS_FAILURE"
  jq -n --arg ts "$NOW" --arg svc "$SERVICE" --arg env "$DEPLOY_ENV" --arg v "$VERSION" --arg repo "$REPO" \
        --arg sha "$SHA" --arg run_id "${GITHUB_RUN_ID:-0}" --arg run_url "$RUN_URL" --arg result "$result" \
        --arg pipeline "${GITHUB_WORKFLOW:-deploy}" --arg ref "${GITHUB_REF_NAME:-main}" \
    '{opsEvent: {timestamp: $ts, description: "\($svc) \($v) deployed to \($env)",
      attributes: {service: {name: $svc}, environment: $env},
      cdEvent: {system: "CD_SYSTEM_GITHUB",
        pipeline: {name: $pipeline, run: {id: $run_id, url: $run_url}, result: {status: $result}},
        vcs: {system: "VCS_SYSTEM_GITHUB", type: "VCS_REF_TYPE_BRANCH",
              repository: {name: $repo, url: "https://github.com/\($repo)"}, ref: {head: {name: $ref, revision: $sha}}}}}}' \
  | curl -fsS -X POST "$CX_OPS_EVENTS_URL" -H "Content-Type: application/json" -H "Authorization: Bearer ${CX_OPS_EVENTS_KEY}" --data-binary @- >/dev/null \
  && echo "Sent APM deployment marker." || echo "::warning::APM deployment marker not sent (check the OpsEvents key)."
fi

# The tag marks the newest commit deployed. A rollback (older commit) leaves it in place, so the next
# forward deploy does not count the rolled-back pull requests a second time.
if [[ "$DEPLOY_STATUS" == success && "$COMPARE_STATUS" == behind ]]; then
  echo "Rollback: deploy tag ${TAG} stays on ${PREV_SHA:0:12}."
elif [[ "$DEPLOY_STATUS" == success ]]; then
  tag_obj="$(gh_api "/repos/${REPO}/git/tags" -X POST -d "$(jq -n --arg tag "$TAG" --arg sha "$SHA" --arg fin "$NOW" --arg v "$VERSION" \
      '{tag: $tag, object: $sha, type: "commit", message: ({finished_at: $fin, version: $v} | tojson)}')" | jq -r '.sha')"
  if gh_api "/repos/${REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
    gh_api "/repos/${REPO}/git/refs/tags/${TAG}" -X PATCH -d "{\"sha\":\"${tag_obj}\",\"force\":true}" >/dev/null
  else
    gh_api "/repos/${REPO}/git/refs" -X POST -d "{\"ref\":\"refs/tags/${TAG}\",\"sha\":\"${tag_obj}\"}" >/dev/null
  fi
fi
