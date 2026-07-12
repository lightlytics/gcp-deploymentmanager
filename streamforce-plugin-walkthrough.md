# Deploy a StreamForce plugin to Google Cloud

This walkthrough deploys a Stream Security **StreamForce custom plugin** as a
private Cloud Run service in your project. The service is IAM-gated
(`--no-allow-unauthenticated`) and only the Stream Security service account is
granted permission to invoke it.

## Select a project

<walkthrough-project-setup></walkthrough-project-setup>

```sh
gcloud config set project <walkthrough-project-id/>
```

## Enable the required APIs

The deploy source-builds a container (Cloud Build) and runs it on Cloud Run.

<walkthrough-enable-apis apis="run.googleapis.com,cloudbuild.googleapis.com,artifactregistry.googleapis.com"></walkthrough-enable-apis>

## Run the deploy command

Copy the command from the Stream Security plugin wizard and paste it into the
terminal. It already contains your plugin id, artifact URL, callback token,
service account, and environment values.

```sh
bash streamforce-plugin-deploy.sh \
  --plugin-id {{ PLUGIN_ID }} \
  --region {{ REGION }} \
  --artifact-url {{ ARTIFACT_URL }} \
  --plugin-token {{ PLUGIN_TOKEN }} \
  --platform-url {{ PLATFORM_URL }} \
  --sa-email {{ SA_EMAIL }} \
  --env '{{ PLUGIN_ENV_JSON }}'
```

The script will:

1. Download the plugin package.
2. Deploy a **private** Cloud Run service (`sfplugin-<id>`).
3. Grant the Stream Security service account `roles/run.invoker`.
4. Report the service URL back to Stream Security.

## Verify

Go back to the Stream Security console. The plugin flips to **Active** once its
tools are reachable — its operations then appear as tools under
**Custom Plugins** in the agent builder.
