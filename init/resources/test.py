import base64
import json

def process_log_event(event, context):
    """
    Triggered by a Pub/Sub message.
    Args:
         event (dict): The Pub/Sub message event.
         context (google.cloud.functions.Context): Metadata for the event.
    """
    # Decode the Pub/Sub message
    pubsub_message = base64.b64decode(event['data']).decode('utf-8')
    
    # Parse the message (assuming it's in JSON format)
    try:
        log_event = json.loads(pubsub_message)
        # Perform an action based on the log event
        if 'severity' in log_event and log_event['severity'] == 'ERROR':
            handle_error(log_event)
        else:
            handle_info(log_event)
    except json.JSONDecodeError:
        print(f"Failed to decode message: {pubsub_message}")
    
def handle_error(log_event):
    # Your logic to handle error logs
    print(f"Error log event: {log_event}")
    
def handle_info(log_event):
    # Your logic to handle other types of logs
    print(f"Info log event: {log_event}")
