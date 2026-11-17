#!/usr/bin/env bash
# approval-watch.sh: report every deployment that is waiting on a human approval, with how long it
# has waited, so Coralogix can alert WHILE it waits (GitHub only reports job durations on completion).
# Env: GITHUB_REPOSITORY, GH_TOKEN (actions:read), CX_LOGS_URL, CX_API_KEY, optional DRY_RUN=1
set -euo pipefail
API="${GITHUB_API_URL:-https://api.github.com}"; REPO="$GITHUB_REPOSITORY"
gh_api() { curl -fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} "${API}$1"; }
NOW_EPOCH="$(date -u +%s)"
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s; }

RECORDS="[]"
for run in $(gh_api "/repos/${REPO}/actions/runs?status=waiting&per_page=100" | jq -r '.workflow_runs[].id'); do
  r="$(gh_api "/repos/${REPO}/actions/runs/${run}")"
  envs="$(gh_api "/repos/${REPO}/actions/runs/${run}/pending_deployments" | jq -c '[.[].environment.name]')"
  # One JSON object per line; read line by line because job names contain spaces ("deploy / deploy").
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    since="$(jq -r '.created_at' <<<"$job")"
    RECORDS="$(jq -c --argjson r "$r" --argjson job "$job" --argjson envs "$envs" --arg since "$since" \
      --argjson wait "$(( NOW_EPOCH - $(epoch "$since") ))" \
      '. + [{dora: {event_type: "approval_pending", repo: $r.repository.full_name, workflow: $r.name, job: $job.name,
              run_id: $r.id, run_url: $r.html_url, head_sha: $r.head_sha, environments: $envs,
              waiting_since: $since, wait_seconds: $wait, wait_hours: (($wait / 360 | floor) / 10)}}]' <<<"$RECORDS")"
  done < <(gh_api "/repos/${REPO}/actions/runs/${run}/jobs?filter=latest" | jq -c '.jobs[] | select(.status == "waiting") | {name, created_at}')
done

echo "$(jq 'length' <<<"$RECORDS") job(s) waiting for approval."
[[ "$(jq 'length' <<<"$RECORDS")" == 0 ]] && exit 0
if [[ "${DRY_RUN:-0}" == 1 ]]; then jq '.' <<<"$RECORDS"; exit 0; fi
jq -c '[.[] | {applicationName: "cicd", subsystemName: "approvals", severity: 4, text: (. | tojson)}]' <<<"$RECORDS" \
  | curl -fsS -X POST "$CX_LOGS_URL" -H "Content-Type: application/json" -H "Authorization: Bearer ${CX_API_KEY}" --data-binary @- >/dev/null
