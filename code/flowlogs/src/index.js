const { Storage } = require('@google-cloud/storage')
const { flowLogsBatchProto, FlowLogsDeviceTypeEnum } = require('./models/protobuf/proto')
const { gzipSync } = require('node:zlib')
const storage = new Storage()
const { RestClient } = require('./restClient')
const { parseFlowlog } = require('./flowlogs/flowlogParser')

const processVPCFlowLogs = async (contentString) => {
  const httpClient = new RestClient({ apiPath: 'collection/flowlogs' })
  const logs = []
  contentString.split('\n').forEach(line => {
    if (line) {
      try {
        const log = parseFlowlog(JSON.parse(line))
        logs.push(log)
      } catch (e) {
        console.error('Error parsing line:', line, e)
      }
    }
  })

  if (!logs) {
    console.info('No logs found in the file')
    return
  }

  const accountId = logs[0].interfaceId
  const flowsBatch = {
    accountIdString: accountId,
    deviceType: FlowLogsDeviceTypeEnum.values.GCP_FLOW_LOGS,
    vpcId: logs[0].vpcId,
    logs,
  }

  const err = flowLogsBatchProto.verify(flowsBatch)
  if (err) {
    console.error(`Error with the proto format: `, err)
    return
  }

  const msg = flowLogsBatchProto.create(flowsBatch)

  const protoBatch = gzipSync(flowLogsBatchProto.encode(msg).finish())
    .toString('base64')

  try {
    const response = await httpClient.postFlowLogsBatch(
      protoBatch,
      accountId,
      flowsBatch.logs.length,
    )
    console.log(
      `Sent ${flowsBatch.logs.length} flow records and got: `,
      response,
    )
  } catch (error) {
    console.error(`Error sending log data:`, error)
  }
}

const StorageFlowlogsCollection = async (event, context) => {
  const bucketName = event.bucket
  const fileName = event.name

  console.log(`Processing file: ${fileName} from bucket: ${bucketName}`)

  try {
    const bucket = storage.bucket(bucketName)
    const file = bucket.file(fileName)

    // TODO: validate its a gcp flow logs file

    const [contents] = await file.download()
    const contentString = contents.toString('utf-8')

    await processVPCFlowLogs(contentString)
  } catch (error) {
    console.error(`Error processing file ${fileName}:`, error)
  }
}

module.exports = {
  processVPCFlowLogs,
  StorageFlowlogsCollection,
}