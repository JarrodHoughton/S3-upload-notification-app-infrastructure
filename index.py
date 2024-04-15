import json
import boto3
import uuid
from datetime import datetime
import os

s3_client = boto3.client('s3')
dynamodb_client = boto3.client('dynamodb')

dynamodb_table_name = os.environ.get('dynamo_db_table')


def lambda_handler(event, context):
    try:
        s3_record = event['Records'][0]['s3']
        bucket_name = s3_record['bucket']['name']
        object_key = s3_record['object']['key']
        file_size = s3_record['object']['size']
        file_name = object_key.split('/')[-1]
        uploader = event['Records'][0]['userIdentity']['principalId']

        account_id = context.invoked_function_arn.split(":")[4]

        detail = {
            "bucket": {
                "name": bucket_name
            },
            "object": {
                "etag": s3_record['object']['eTag'],
                "key": object_key,
                "sequencer": s3_record['object']['sequencer'],
                "size": file_size,
                "version-id": s3_record['object'].get('versionId', '')
            }
        }

        save_metadata_to_dynamodb(
            account_id, detail, file_name, file_size, uploader)
        return {
            'statusCode': 200,
            'body': json.dumps('Metadata saved to DynamoDB and SNS notification sent')
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }


def save_metadata_to_dynamodb(account_id, detail, file_name, file_size, uploader):
    item_id = str(uuid.uuid4())
    timestamp = str(datetime.utcnow())

    dynamodb_item = {
        'Id': {'S': item_id},
        'Account': {'S': account_id},
        'Detail': {'S': json.dumps(detail)},
        'FileName': {'S': file_name},
        'FileSize': {'N': str(file_size)},
        'Uploader': {'S': uploader},
        'Timestamp': {'S': timestamp}
    }

    dynamodb_client.put_item(
        TableName=dynamodb_table_name,
        Item=dynamodb_item
    )
