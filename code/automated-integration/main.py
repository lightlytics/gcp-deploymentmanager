import base64
import json
import os
import requests
import logging
from google.cloud.config import Deployment, ConfigClient
from cloudevents.http import CloudEvent
import functions_framework
# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@functions_framework.cloud_event
def handle_project_event(cloud_event: CloudEvent) -> None:
    """
    Cloud Run function that handles GCP project creation/deletion events and triggers infrastructure manager deployment updates.
    Args:
        event (dict): The event payload.
        context (google.cloud.functions.Context): Metadata for the event.
    """
    try:
        logger.info("Starting project event handler")
        logger.info(f"Received event: {cloud_event}")
        
        # Get the deployment details from environment variables
        deployment_name = os.environ.get('INFRA_MANAGER_DEPLOYMENT_NAME')
        
        logger.info(f"Deployment Name: {deployment_name}")
        
        if not deployment_name:
            error_msg = "INFRA_MANAGER_DEPLOYMENT_NAME environment variable is not set"
            logger.error(error_msg)
            raise ValueError(error_msg)

        # Initialize Infrastructure Manager client
        logger.info("Initializing Config client")
        client = ConfigClient()

        # Get the current deployment
        logger.info(f"Getting deployment: {deployment_name}")
        
        deployment = client.get_deployment(
            name=deployment_name
        )
        logger.info(f"Successfully retrieved deployment: {deployment.name}")

        # Get the current deployment configuration
        deployment_config = deployment.terraform_blueprint
        logger.info("Retrieved deployment configuration")
        logger.info(f"Deployment configuration: {deployment_config}")

        # Update the deployment with the same configuration
        logger.info("Updating deployment with current configuration")
        client.update_deployment(
            deployment=Deployment(
                name=deployment_name,
                terraform_blueprint=deployment_config
            )
        )

        logger.info(f"Successfully triggered update for deployment {deployment_name}")

    except Exception as e:
        logger.error(f"Error updating deployment: {str(e)}", exc_info=True)
        raise e
