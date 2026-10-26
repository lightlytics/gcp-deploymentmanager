const functions = require('@google-cloud/functions-framework')
const { Storage } = require('@google-cloud/storage')
const { promisify } = require('node:util')
// off the event loop, which serves every waiting invocation
const gzip = promisify(require('node:zlib').gzip)
const storage = new Storage()
const { RestClient } = require('./restClient')

// The collection API publishes the records of a request as one Kafka message,
// limited to about 1 MB
const MAX_RECORDS_LENGTH = 900 * 1024
// A batch is sent once its entries reach this much text, which bounds the memory
// it holds. Gzip usually brings it well under MAX_RECORDS_LENGTH.
const MAX_BATCH_LENGTH = 4 * 1024 * 1024
// How long an entry waits for its batch without BATCH_MAX_WAIT_MS, and at most,
// well within the function's timeout
const DEFAULT_WAIT_MS = 2 * 1000
const MAX_WAIT_MS = 30 * 1000

// Handlers take a single argument: with more than one, the functions framework
// treats a CloudEvent handler as callback style and the invocation never ends.
// 2nd gen passes a CloudEvent, 1st gen passes the event data (context unused).

// Reads the file line by line, so that its size does not matter
const StorageGKELogsCollection = async event => {
  const { bucket: bucketName, name: fileName } = event.data?.bucket
    ? event.data
    : event

  try {
    const stream = storage.bucket(bucketName).file(fileName).createReadStream()
    await sendLines(linesOf(stream), fileName)
  } catch (error) {
    console.error(`Error processing file ${fileName}: ${error.message}`)
  }
}

// Each message carries a single log entry published by the Log Router sink.
// Errors are logged and swallowed so the message is acked and never retried
const PubSubGKELogsCollection = async event => {
  const message = event.data?.message ?? event

  let entry
  try {
    entry = toEntry(Buffer.from(message.data, 'base64').toString('utf-8'))
  } catch (error) {
    console.error(`Error processing Pub/Sub message: ${error.message}`)
    return
  }
  await sendBatched(entry)
}

const processGKELogFile = async (contentString) => {
  await sendLines(contentString.split('\n'), 'the file')
}

// A log entry as sent: its JSON text, kept as is, and the cluster it comes from
const toEntry = text => {
  const { labels } = JSON.parse(text).resource
  return {
    text,
    resourceId: `projects/${labels.project_id}/locations/${labels.location}/clusters/${labels.cluster_name}`,
  }
}

// Yields the lines of a text stream as they arrive
async function* linesOf(stream) {
  let rest = ''
  for await (const chunk of stream.setEncoding('utf8')) {
    const lines = (rest + chunk).split('\n')
    rest = lines.pop()
    yield* lines
  }
  yield rest
}

// Sends the log entries among the lines in batches of up to MAX_BATCH_LENGTH.
// Lines that are not log entries are skipped and counted.
const sendLines = async (lines, source) => {
  let entries = []
  let length = 0
  let skipped = 0
  try {
    for await (const line of lines) {
      if (!line.trim()) {
        continue
      }
      try {
        entries.push(toEntry(line))
      } catch {
        skipped++
        continue
      }
      length += line.length
      if (length >= MAX_BATCH_LENGTH) {
        await sendGKELogs(entries)
        entries = []
        length = 0
      }
    }
  } finally {
    // what was read before an error is still sent
    if (entries.length > 0) {
      await sendGKELogs(entries)
    }
    if (skipped > 0) {
      console.error(`Skipped ${skipped} lines of ${source} that are not GKE audit log entries`)
    }
  }
}

// With BATCH_SIZE above 1, entries that arrive while others wait are sent in one
// request: once BATCH_SIZE entries or MAX_BATCH_LENGTH of them wait, or
// BATCH_MAX_WAIT_MS after the first. Each invocation ends when its batch is sent.
// That needs an instance that runs many invocations at once (2nd gen
// --concurrency): with one at a time, waiting only delays, so unset, every entry
// is sent on its own.
let waiting = null

const sendBatched = entry => {
  const batchSize = Number(process.env.BATCH_SIZE) || 1
  if (!waiting) {
    const maxWaitMs = Math.min(Number(process.env.BATCH_MAX_WAIT_MS) || DEFAULT_WAIT_MS, MAX_WAIT_MS)
    waiting = { entries: [], length: 0 }
    waiting.sent = new Promise(resolve => (waiting.release = resolve))
    waiting.timer = setTimeout(sendWaiting, maxWaitMs)
  }
  const batch = waiting
  batch.entries.push(entry)
  batch.length += entry.text.length
  if (batch.entries.length >= batchSize || batch.length >= MAX_BATCH_LENGTH) {
    sendWaiting()
  }
  return batch.sent
}

const sendWaiting = () => {
  const batch = waiting
  waiting = null
  clearTimeout(batch.timer)
  sendGKELogs(batch.entries)
    .catch(error => console.error(`Error sending log data: ${error.message}`))
    .finally(batch.release)
}

// Sends the entries gzipped, halving the batch until each request fits. A batch
// that cannot be sent is logged and dropped.
const sendGKELogs = async entries => {
  const records = (await gzip(`[${entries.map(entry => entry.text).join(',')}]`)).toString('base64')
  if (records.length > MAX_RECORDS_LENGTH && entries.length > 1) {
    const half = Math.ceil(entries.length / 2)
    await sendGKELogs(entries.slice(0, half))
    await sendGKELogs(entries.slice(half))
    return
  }

  try {
    const httpClient = new RestClient({ apiPath: 'collection' })
    await httpClient.postGKEBatch(
      records,
      [...new Set(entries.map(entry => entry.resourceId))],
      entries.length,
    )
  } catch (error) {
    console.error(`Could not send ${entries.length} GKE audit log entries to Stream Security: ${error.message}`)
  }
}

functions.cloudEvent('StorageGKELogsCollection', StorageGKELogsCollection)
functions.cloudEvent('PubSubGKELogsCollection', PubSubGKELogsCollection)

module.exports = {
  StorageGKELogsCollection,
  PubSubGKELogsCollection,
  processGKELogFile,
}
