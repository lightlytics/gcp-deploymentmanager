const { Storage } = require('@google-cloud/storage')
const { gzipSync } = require('node:zlib')
const storage = new Storage()
const { RestClient } = require('./restClient')

const StorageGKELogsCollection = async (event, context) => {
  const bucketName = event.bucket
  const fileName = event.name

  console.log(`Processing file: ${fileName} from bucket: ${bucketName}`)

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
    console.log('No logs to process')
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
    console.log(
      `Sent ${logCount} GKE records and got: `,
      response,
    )
  } catch (err) {
    console.error(`Error sending log data: ${err.message || err}`)
    if (err.response) {
      console.error(`Response status: ${err.response.status}, data: ${JSON.stringify(err.response.data)}`)
    }
  }
}

module.exports = {
  StorageGKELogsCollection,
  processGKELogFile,
}