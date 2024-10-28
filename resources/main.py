import base64
import json
import os
import requests

def process_log_event(event, context):
    """
    Triggered by a Pub/Sub message.
    Args:
         event (dict): The Pub/Sub message event.
         context (google.cloud.functions.Context): Metadata for the event.
    """

    try:
        print(f"received deployment finished event from deployment manager")
        
        os.environ['SERVICE_ACCOUNT_KEY'] = base64.b64decode(os.environ['SERVICE_ACCOUNT_KEY']).decode('utf-8')
        service_account_json = json.loads(os.environ['SERVICE_ACCOUNT_KEY'])
        
        
        response = requests.post(
            f"https://{os.environ['API_URL'].replace('https://', '')}/gcp/account-acknowledge",
            headers={
                "Authorization": f"Bearer {os.environ['API_TOKEN']}",
                "Content-Type": "application/json"
            },
            json={
                "project_id": service_account_json.get('project_id'),
                "client_email": service_account_json.get('client_email'),
                "private_key": service_account_json.get('private_key'),
                "account_type": "GCP"
            }
        )
        if response.status_code != 200:
            print(f"Error: {response.text}")
            raise Exception(f"Error: {response.text}")
    except Exception as e:
        print(f"Error: {e}")
        raise e
    