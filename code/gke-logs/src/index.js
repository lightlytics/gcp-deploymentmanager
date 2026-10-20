const functions = require('@google-cloud/functions-framework')
const { Storage } = require('@google-cloud/storage')
const { gzipSync } = require('node:zlib')
const storage = new Storage()
const { RestClient } = require('./restClient')

// Handlers take a single argument: with more than one, the functions framework
// treats a CloudEvent handler as callback style and the invocation never ends.
// 2nd gen passes a CloudEvent, 1st gen passes the event data (context unused).

const StorageGKELogsCollection = async event => {
  const { bucket: bucketName, name: fileName } = event.data?.bucket
    ? event.data
    : event

  try {
    const bucket = storage.bucket(bucketName)
    const file = bucket.file(fileName)
    // TODO: validate its a gcp gke logs file
    const [contents] = await file.download()
    const contentString = contents.toString('utf-8')

    await processGKELogFile(contentString)

  } catch (error) {
    console.error(`Error processing file ${fileName}:`, error)
  }
}

// Each message carries a single log entry published by the Log Router sink.
// Errors are logged and swallowed so the message is acked and never retried
const PubSubGKELogsCollection = async event => {
  const message = event.data?.message ?? event

  try {
    const logEntry = Buffer.from(message.data, 'base64').toString('utf-8')
    await processGKELogFile(logEntry)
  } catch (error) {
    console.error('Error processing Pub/Sub message:', error)
  }
}

const processGKELogFile = async (contentString) => {
  let logsString = '['
  const resourceIds = {}
  let logCount = 0
  contentString.split('\n').forEach((line, index, array) => {
    if (line) {
      const log = JSON.parse(line)
      resourceIds[`projects/${log.resource.labels.project_id}/locations/${log.resource.labels.location}/clusters/${log.resource.labels.cluster_name}`] = ''
      logsString += line + ','
      logCount++
    }
  })
  logsString = logsString.slice(0, -1) + ']'

  if (logCount === 0) {
    return
  }

  const batchCompressed = gzipSync(logsString).toString('base64')
  const httpClient = new RestClient({ apiPath: 'collection' })

  try {
    const response = await httpClient.postGKEBatch(
      batchCompressed,
      Object.keys(resourceIds),
      logCount,
    )
  } catch (error) {
    console.error(`Error sending log data:`, error)
  }
}

functions.cloudEvent('StorageGKELogsCollection', StorageGKELogsCollection)
functions.cloudEvent('PubSubGKELogsCollection', PubSubGKELogsCollection)

module.exports = {
  StorageGKELogsCollection,
  PubSubGKELogsCollection,
  processGKELogFile,
}
