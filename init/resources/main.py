import base64
import json
import os
import requests
import google.auth


def get_project_id():
    credentials, project_id = google.auth.default()
    return project_id

def process_log_event(event, context):
    """
    Triggered by a Pub/Sub message.
    Args:
         event (dict): The Pub/Sub message event.
         context (google.cloud.functions.Context): Metadata for the event.
    """

    try:
        print(f"received the first message from deployment manager")
        print(f"API_URL: {os.environ['API_URL']}, API_TOKEN: {os.environ['API_TOKEN']}, SERVICE_ACCOUNT_EMAIL: {os.environ['SERVICE_ACCOUNT_EMAIL']}")
        response = requests.post(
            f"https://{os.environ['API_URL'].replace('https://', '')}/gcp/account-acknowledge",
            headers={
                "Authorization": f"Bearer {os.environ['API_TOKEN']}",
                "Content-Type": "application/json"
            },
            json={
                "project_id": get_project_id(),
                "client_email": os.environ['SERVICE_ACCOUNT_EMAIL'],
                "private_key": os.environ['SERVICE_ACCOUNT_KEY'],
                "account_type": "GCP"
            }
        )
        if response.status_code != 200:
            print(f"Error: {response.text}")
            raise Exception(f"Error: {response.text}")
    except Exception as e:
        print(f"Error: {e}")
        raise e
    