const functions = require('@google-cloud/functions-framework')
const {RestClient} = require('./restClient')

functions.cloudEvent('streamsec-audit-logs-collector', async (cloudEvent) => {
  const message = Buffer.from(cloudEvent.data.message.data, 'base64').toString()
  const data = JSON.parse(message)

  try {
    const httpClient = new RestClient({apiPath: 'collection'})
    const response = await httpClient.postAuditEvent(data)
    console.log(`Sent log and got response ${response?.data} (${response?.status})`)
  } catch (error) {
    console.error(`Error sending log data (${error?.code || error?.response?.statusCode})`)
  }
})