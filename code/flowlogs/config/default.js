const isLocalMode =
  ['', 'local', 'dev'].includes(process.env.NODE_ENV) || !process.env.NODE_ENV

module.exports = {
  batchSize: process.env.BATCH_SIZE || 4000,
  apiUrl: process.env.API_URL,
  apiToken: process.env.API_TOKEN,
  apiVersion: process.env.API_VERISON || 'v1',
  streamSecurityTokenHeader: 'X-Lightlytics-Token',
  isLocalMode,
  // set by jest
  isTestMode: process.env.NODE_ENV === 'test',
}
