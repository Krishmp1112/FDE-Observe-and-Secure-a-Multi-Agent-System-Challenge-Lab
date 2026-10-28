#!/usr/bin/env bash
# ==============================================================================
# Automated Solution Script: Observe and Secure a Multi-Agent System
# ==============================================================================
set -euo pipefail

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export LOCATION="${LOCATION:-us-central1}"

echo "=================================================================="
echo "Project ID:     ${PROJECT_ID}"
echo "Project Number: ${PROJECT_NUMBER}"
echo "Location:       ${LOCATION}"
echo "=================================================================="

# ------------------------------------------------------------------------------
# Task 1: Enable Observability & Discovery APIs
# ------------------------------------------------------------------------------
echo "[Task 1] Enabling required Google Cloud APIs..."
gcloud services enable \
  telemetry.googleapis.com \
  cloudtrace.googleapis.com \
  observability.googleapis.com \
  apphub.googleapis.com \
  agentregistry.googleapis.com \
  discoveryengine.googleapis.com \
  cloudasset.googleapis.com \
  --project="${PROJECT_ID}"

# ------------------------------------------------------------------------------
# Task 2: Grant Trace Writer Role & Generate Trace Traffic
# ------------------------------------------------------------------------------
echo "[Task 2] Granting roles/telemetry.tracesWriter to salesforce-agent service account..."
export SF_SA=$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format='value(spec.template.spec.serviceAccountName)')
export SF_SA=${SF_SA:-"${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"}

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/telemetry.tracesWriter" \
  --quiet > /dev/null

echo "[Task 2] Discovering github_agent Reasoning Engine URL..."
export RE_NAME=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
  | jq -r '.reasoningEngines[] | select(.displayName=="github-agent") | .name')
export RE_ID=$(basename "${RE_NAME}")
export GITHUB_AGENT_URL="https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines/${RE_ID}"

echo "[Task 2] Querying github_agent and salesforce-agent to emit traces..."
agents-cli run \
  --url "${GITHUB_AGENT_URL}" \
  --mode adk \
  --app-name app \
  "What repositories or issues can you search?" || true

export SF_URL=$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format='value(status.url)')

agents-cli run \
  --url "${SF_URL}" \
  --mode adk \
  --app-name app \
  "Search Salesforce documents for security policies" || true

# ------------------------------------------------------------------------------
# Task 3: Confirm Agent Runtime Auto-Discovery
# ------------------------------------------------------------------------------
echo "[Task 3] Listing auto-discovered agents in Agent Registry..."
gcloud alpha agent-registry agents list \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format="table(displayName)"

echo "[Task 3] Verifying App Hub functionalType classification..."
export TOKEN=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://apphub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/discoveredWorkloads" \
  | jq -r '.discoveredWorkloads[] | "\(.workloadProperties.functionalType.type // "-")\t\(.workloadReference.uri)"'

# ------------------------------------------------------------------------------
# Task 4: Register the Cloud Run Agent (salesforce-agent)
# ------------------------------------------------------------------------------
echo "[Task 4] Creating Discovery Engine service identity and granting roles/run.invoker..."
gcloud beta services identity create \
  --service=discoveryengine.googleapis.com \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --quiet > /dev/null

echo "[Task 4] Downloading salesforce_card.json and registering salesforce-agent..."
export ID_TOKEN=$(gcloud auth print-identity-token)
curl -s -H "Authorization: Bearer ${ID_TOKEN}" \
  "${SF_URL}/a2a/app/.well-known/agent-card.json" -o salesforce_card.json

gcloud alpha agent-registry services create salesforce-agent \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content=salesforce_card.json || true

# ------------------------------------------------------------------------------
# Task 5: Register the GitHub MCP Server (github-mcp)
# ------------------------------------------------------------------------------
echo "[Task 5] Registering github-mcp in Agent Registry..."
gcloud alpha agent-registry services create github-mcp \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC" || true

gcloud alpha agent-registry mcp-servers list \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}"

# ------------------------------------------------------------------------------
# Task 9: Remediate Over-Privileged Service Account to Least Privilege
# ------------------------------------------------------------------------------
echo "[Task 9] Ensuring narrow least-privilege roles are bound to ${SF_SA}..."
for ROLE in \
  roles/aiplatform.user \
  roles/telemetry.tracesWriter \
  roles/logging.logWriter \
  roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SF_SA}" \
    --role="${ROLE}" \
    --quiet > /dev/null
done

echo "[Task 9] Removing broad roles/editor role from ${SF_SA}..."
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/editor" \
  --quiet > /dev/null || true

echo "[Task 9] Active roles for ${SF_SA}:"
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:${SF_SA}" \
  --format="value(bindings.role)"

echo "=================================================================="
echo "All tasks completed successfully!"
echo "=================================================================="
