# Explore Deployment Manager 

## Overview 

This is a walkthrough for integrating GCP project to Stream Security.
This walkthrough assumes that you are familiar with YAML syntax and are comfortable running commands in a Linux terminal. 

### Select a project

Select a Google Cloud project to use for this tutorial.

<walkthrough-project-setup></walkthrough-project-setup>

## Setup

Every command requires a project ID. Set a default project ID so you do not need to provide it every time. 

```sh  
gcloud config set project <walkthrough-project-id/> 
```

Enable the deployment manager API

<walkthrough-enable-apis apis="deploymentmanager.googleapis.com"></walkthrough-enable-apis>


Because you will be creating IAM resources, you need to have the necessary permissions for the service account being used by Deployment Manager. For that we will create a custom role and assign it to the default GCP API service account in the project.
These permissions will only be used by the deployment manager to create resources in the project and will not be used by the Stream Security integration.

```sh
gcloud iam roles create StreamsecCustomRole --project <walkthrough-project-id> --file deployment-manager-custom-role.yaml
```

```sh
gcloud projects add-iam-policy-binding <walkthrough-project-id> --member=serviceAccount:$(gcloud projects describe <walkthrough-project-id> --format='value(projectNumber)')@cloudservices.gserviceaccount.com --role=projects/<walkthrough-project-id>/roles/StreamsecCustomRole
```

## Enable Necessary APIs

Enable the rest of the necessary APIs, which you will need for the integration.
<walkthrough-enable-apis apis="cloudresourcemanager.googleapis.com"></walkthrough-enable-apis>
<walkthrough-enable-apis apis="cloudfunctions.googleapis.com"></walkthrough-enable-apis>
<walkthrough-enable-apis apis="pubsub.googleapis.com"></walkthrough-enable-apis>
<walkthrough-enable-apis apis="cloudbuild.googleapis.com"></walkthrough-enable-apis>
<walkthrough-enable-apis apis="admin.googleapis.com"></walkthrough-enable-apis>
<walkthrough-enable-apis apis="logging.googleapis.com"></walkthrough-enable-apis>

Manually create the needed service account for cloud logging if not already created.

```sh
gcloud beta services identity create --service=logging.googleapis.com --project <walkthrough-project-id>
```

## Create the deployment
* You can copy the commmand from Stream Security integration wizard.
* You can change the region by adding region:{{ REGION }} to the properties (default: us-central1).

```sh
gcloud deployment-manager deployments create stream-security --template init.jinja --properties apiUrl:{{ API_URL }},apiToken:{{ API_TOKEN }}
```

### ⚠️ Troubleshoot ⚠️

* service account does not exist error: please update the deployment after you see this error. (replace 'create' with 'update' in the command)
* custom role is in deleted state: happens if you deleted the deployment and recreated it. You need to create the deployment with a different name


## Verify the deployment
Go back to the Stream Security console and verify that the deployment was successful.
If the deployment was successful, you should see status "Pending" or "Connected"