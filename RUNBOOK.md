# Detailed Operational Runbook: Observe and Secure a Multi-Agent System

This runbook provides the exact commands, expected outputs, and verification steps executed during the lab.

---

## Environment Setup

Set your project variables before running any commands in Cloud Shell:

```bash
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export LOCATION="us-central1"

echo "Project ID:     ${PROJECT_ID}"
echo "Project Number: ${PROJECT_NUMBER}"
echo "Location:       ${LOCATION}"
```

---

## Task 1. Enable the Observability and Discovery APIs

Ensure the required observability, telemetry, App Hub, and Agent Registry APIs are enabled:

```bash
gcloud services enable \
  telemetry.googleapis.com \
  cloudtrace.googleapis.com \
  observability.googleapis.com \
  apphub.googleapis.com \
  agentregistry.googleapis.com \
  discoveryengine.googleapis.com \
  cloudasset.googleapis.com \
  --project="${PROJECT_ID}"
```

---

## Task 2. Export Traces to Cloud Trace

### 2.1 Verify Agent Instrumentation and Exporter Code

1. **Check `pyproject.toml`** in `~/agents/salesforce-agent/pyproject.toml`:
   ```toml
   dependencies = [
       "google-adk[gcp,otel-gcp]>=2.0.0,<3.0.0",
       "a2a-sdk[http-server]~=0.3.22",
       "opentelemetry-instrumentation-google-genai>=0.1.0,<1.0.0",
       ...
   ]
   ```
   The `otel-gcp` extra pulls in `opentelemetry-instrumentation-google-genai`, which emits the `call_llm` and GenAI spans.

2. **Check `app/app_utils/telemetry.py`** in `~/agents/salesforce-agent/app/app_utils/telemetry.py`:
   ```python
   credentials, project_id = google.auth.default()
   otel_hooks = get_gcp_exporters(
       enable_cloud_tracing=True,
       enable_cloud_metrics=False,
       enable_cloud_logging=True,
       google_auth=(credentials, project_id),
   )
   otel_resource = get_gcp_resource(project_id)
   maybe_set_otel_providers(
       otel_hooks_to_setup=[otel_hooks],
       otel_resource=otel_resource,
   )
   ```
   `enable_cloud_tracing=True` points the OpenTelemetry exporter at the Telemetry OTLP API (`telemetry.googleapis.com`).

### 2.2 Grant the Cloud Telemetry Traces Writer Role

Grant `roles/telemetry.tracesWriter` to the service account used by `salesforce-agent` on Cloud Run (the Compute Engine default service account):

```bash
export SF_SA=$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format='value(spec.template.spec.serviceAccountName)')

# Fallback to Compute Engine default SA if empty
export SF_SA=${SF_SA:-"${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"}

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/telemetry.tracesWriter"
```

### 2.3 Generate Traffic So the System Emits Traces

1. **Find the `github_agent` Reasoning Engine URL** (without `:query`):
   ```bash
   export RE_NAME=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
     | jq -r '.reasoningEngines[] | select(.displayName=="github-agent") | .name')
   export RE_ID=$(basename "${RE_NAME}")
   export GITHUB_AGENT_URL="https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines/${RE_ID}"
   echo "GitHub Agent URL: ${GITHUB_AGENT_URL}"
   ```

2. **Query `github_agent` using `agents-cli run`**:
   ```bash
   agents-cli run \
     --url "${GITHUB_AGENT_URL}" \
     --mode adk \
     --app-name app \
     "What repositories or issues can you search?"
   ```

3. **Query `salesforce-agent` using `agents-cli run`** (to emit traces from Cloud Run as well):
   ```bash
   export SF_URL=$(gcloud run services describe salesforce-agent \
     --region="${LOCATION}" \
     --project="${PROJECT_ID}" \
     --format='value(status.url)')

   agents-cli run \
     --url "${SF_URL}" \
     --mode adk \
     --app-name app \
     "Search Salesforce documents for security policies"
   ```

### 2.4 Confirm the Traces Landed in Cloud Trace

- Open **Google Cloud Console > Monitoring > Trace explorer**.
- Set the time-range filter to **Last 1 hour** and filter by span name `call_llm` or `invoke_agent`.
- Inspect the waterfall view (`invocation` -> `invoke_agent` -> `call_llm` / `execute_tool`).

---

## Task 3. Confirm the Agent Runtime Agents Are Already Discovered

### 3.1 List Auto-Discovered Agents in Agent Registry

```bash
gcloud alpha agent-registry agents list \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format="table(displayName)"
```

**Expected Output:**
```text
DISPLAY_NAME
Workspace Agent
github-agent
```

### 3.2 Confirm App Hub Classifies the Reasoning Engine as `AGENT`

```bash
export TOKEN=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://apphub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/discoveredWorkloads" \
  | jq -r '.discoveredWorkloads[] | "\(.workloadProperties.functionalType.type // "-")\t\(.workloadReference.uri)"'
```

**Expected Output:**
```text
AGENT	//aiplatform.googleapis.com/projects/171520868025/locations/us-central1/reasoningEngines/6050078399878135808
```

---

## Task 4. Register the Cloud Run Agent (`salesforce-agent`)

### 4.1 Grant the Discovery Engine Service Agent Invoker Access

1. **Create the Discovery Engine service identity**:
   ```bash
   gcloud beta services identity create \
     --service=discoveryengine.googleapis.com \
     --project="${PROJECT_ID}"
   ```

2. **Grant `roles/run.invoker` on the `salesforce-agent` Cloud Run service**:
   ```bash
   gcloud run services add-iam-policy-binding salesforce-agent \
     --region="${LOCATION}" \
     --project="${PROJECT_ID}" \
     --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
     --role="roles/run.invoker"
   ```

### 4.2 Fetch the A2A Agent Card and Register `salesforce-agent` in Agent Registry

1. **Download the A2A agent card**:
   ```bash
   export SF_URL=$(gcloud run services describe salesforce-agent \
     --region="${LOCATION}" \
     --project="${PROJECT_ID}" \
     --format='value(status.url)')
   export ID_TOKEN=$(gcloud auth print-identity-token)

   curl -s -H "Authorization: Bearer ${ID_TOKEN}" \
     "${SF_URL}/a2a/app/.well-known/agent-card.json" -o salesforce_card.json
   ```

2. **Register the service in Agent Registry**:
   ```bash
   gcloud alpha agent-registry services create salesforce-agent \
     --location="${LOCATION}" \
     --project="${PROJECT_ID}" \
     --agent-spec-type=a2a-agent-card \
     --agent-spec-content=salesforce_card.json
   ```

3. **Verify registration**:
   ```bash
   gcloud alpha agent-registry agents list \
     --location="${LOCATION}" \
     --project="${PROJECT_ID}" \
     --format="table(displayName)"
   ```
   **Expected Output:**
   ```text
   DISPLAY_NAME
   Workspace Agent
   salesforce_agent
   github-agent
   ```

---

## Task 5. Register the GitHub MCP Server (`github-mcp`)

### 5.1 Create the MCP Server Service in Agent Registry

```bash
gcloud alpha agent-registry services create github-mcp \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC"
```

### 5.2 Confirm the MCP Server Is Registered

```bash
gcloud alpha agent-registry mcp-servers list \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}"
```

**Expected Output:**
```yaml
---
attributes:
  agentregistry.googleapis.com/system/RuntimeReference:
    uri: //agentregistry.googleapis.com/projects/171520868025/locations/us-central1/services/github-mcp
interfaces:
- protocolBinding: JSONRPC
  url: https://api.githubcopilot.com/mcp/
mcpServerId: urn:mcp:projects-171520868025:projects:171520868025:locations:us-central1:agentregistry:services:github-mcp
name: projects/.../locations/us-central1/mcpServers/agentregistry-...
```

---

## Task 6. View the Agent Topology Graph

1. In the Google Cloud Console, navigate to **Agent Platform > Agent Registry**.
2. On the **Agents** tab, click **`github-agent`**.
3. Select the **Topology** tab.
4. Observe the unified topology showing agents across both **Agent Runtime** (`github_agent`) and **Cloud Run** (`salesforce_agent`), plus the edge to the **GitHub MCP Server**.

---

## Task 7 & Task 8. Inspect Excessive Permissions in SCC AI Protection & Policy Analyzer

1. Navigate to **Agent Platform > Agents > Security** (`https://console.cloud.google.com/agent-platform/security`).
2. Locate the over-privileged `salesforce_agent` under **Agents with excessive permissions** (caused by `roles/editor` on its service account).
3. Open **IAM & Admin > Policy Analyzer**:
   - Click **Create custom query**.
   - Scope: current project (`${PROJECT_ID}`).
   - Parameter 1: **Principal** -> `serviceAccount:${SF_SA}`.
   - Under **Advanced options**, check **List resources within resource(s) matching your query**, then click **Analyze > Run query**.
   - Review the broad project-wide access granted by `roles/editor`.

---

## Task 9. Fix It and Verify Least Privilege

### 9.1 Ensure Required Narrow Roles Are Granted

Before removing `roles/editor`, ensure all four narrow operational roles required by `salesforce-agent` are bound to `${SF_SA}`:

```bash
export SF_SA=$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format='value(spec.template.spec.serviceAccountName)')

for ROLE in \
  roles/aiplatform.user \
  roles/telemetry.tracesWriter \
  roles/logging.logWriter \
  roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SF_SA}" \
    --role="${ROLE}"
done
```

### 9.2 Remove the Broad `roles/editor` Role

```bash
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/editor"
```

### 9.3 Verify Least Privilege in the Live IAM Policy

1. **List all remaining roles on `${SF_SA}`**:
   ```bash
   gcloud projects get-iam-policy "${PROJECT_ID}" \
     --flatten="bindings[].members" \
     --filter="bindings.members:${SF_SA}" \
     --format="value(bindings.role)"
   ```
   **Expected Output:**
   ```text
   roles/aiplatform.user
   roles/cloudtrace.agent
   roles/logging.logWriter
   roles/telemetry.tracesWriter
   ```

2. **Confirm `roles/editor` is completely removed (returns empty)**:
   ```bash
   gcloud projects get-iam-policy "${PROJECT_ID}" \
     --flatten="bindings[].members" \
     --filter="bindings.members:${SF_SA} AND bindings.role:roles/editor" \
     --format="value(bindings.role)"
   ```

---

## Task 10. (Optional) Trigger and View an Agent's Runtime Attacks

1. In **Agent Platform > Security**, locate the **AI threats** widget.
2. Follow the [Test Agent Platform Threat Detection documentation](https://cloud.google.com/security-command-center/docs/test-agent-engine-threat-detection) to deploy a temporary test agent that executes a benign EICAR test binary.
3. Inspect the resulting finding (`Execution: Added Malicious Binary Executed`) in **Security Command Center > Findings**.
