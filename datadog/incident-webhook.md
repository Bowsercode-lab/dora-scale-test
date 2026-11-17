# Datadog Incident Management to Coralogix (webhook)

Datadog Incident Management and paging stay in Datadog. This sends each incident declaration and update to Coralogix as a log, so incidents can count toward change failure rate and recovery time per service.

## 1. Webhook (Datadog > Integrations > Webhooks > New)

| Field | Value |
|---|---|
| Name | `coralogix-incidents` |
| URL | `https://ingress.us2.coralogix.com/logs/v1/singles` |
| Payload type | Incident (required for incident notification rules) |
| Custom header | `{"Authorization": "Bearer <Coralogix Send-Your-Data key>"}` |
| Encode as form | off |

Payload (a JSON array, as the Coralogix singles API expects; `$INCIDENT_FIELDS` is the map of incident fields, where Datadog puts the services and teams):

```json
[
  {
    "applicationName": "cicd",
    "subsystemName": "incidents",
    "severity": 4,
    "text": {
      "incident": {
        "public_id": "$INCIDENT_PUBLIC_ID",
        "uuid": "$INCIDENT_UUID",
        "title": "$INCIDENT_TITLE",
        "status": "$INCIDENT_STATUS",
        "severity": "$INCIDENT_SEVERITY",
        "url": "$INCIDENT_URL",
        "commander": "$INCIDENT_COMMANDER",
        "customer_impact": "$INCIDENT_CUSTOMER_IMPACT",
        "fields": $INCIDENT_FIELDS
      },
      "source": "datadog-incident-management",
      "event_date": "$DATE"
    }
  }
]
```

## 2. Notification rule (Incidents > Settings > Notification Rules)

- Trigger: **Declared or attributes are updated**, and renotify on status changes.
- Recipient: `@webhook-coralogix-incidents`.
- Conditions: none (all incidents), or limit to the POC services.

Requires the Incident Notification Settings Write permission in Datadog.

## 3. Replay a sample in the lab (no Datadog needed)

```bash
curl -fsS -X POST https://ingress.us2.coralogix.com/logs/v1/singles \
  -H "Content-Type: application/json" -H "Authorization: Bearer $CX_API_KEY" \
  --data-binary @sample-incident.json
```

The services and teams keys inside `$INCIDENT_FIELDS` are not documented field by field. Check the first real payload in Coralogix Explore and adjust the incident queries (`scaffold/dora-lab/coralogix/dora-queries.md`) to the path you see.
