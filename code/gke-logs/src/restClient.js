const axios = require('axios')
const config = require('config')
const { GKELogsBatch } = require('./models/gke')
const { getSecretValue } = require('./secretManager')

// The Stream Security URL with https:// when no scheme is given, and without
// trailing slashes
function formatUrl(url) {
  const withScheme = /^https?:\/\//.test(url) ? url : `https://${url}`
  return withScheme.replace(/\/+$/, '')
}

class RestClient {
  constructor(options) {
    this.apiUrl = config.get('apiUrl')
    // assert(this.apiUrl, 'Missing API_URL env var')
    this.apiVersion = config.get('apiVersion')
    if (!options.apiPath) {
      throw new Error('missing api path')
    }
    this.tokenHeader = config.get('streamSecurityTokenHeader')

    try {
      this.baseApiUrl = new URL(
        `${formatUrl(this.apiUrl)}/api/${this.apiVersion}/${options.apiPath}/`,
      )
    } catch (e) {
      throw new Error(`wrong API url - error: ${e}`)
    }

    this.client = axios.create({
      baseURL: this.baseApiUrl.toString(),
      // a batch can be close to 1 MB
      timeout: 15 * 1000,
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json;q=0.5, text/plain;q=0.1',
      },
    })

    // Set authentication token - from Secret Manager or config
    if (process.env.SECRET_NAME) {
      // Without the token every request fails, so a request waits for it and
      // fails with this error instead of being sent without it
      this.tokenLoadedPromise = getSecretValue(process.env.SECRET_NAME)
        .then(token => {
          this.client.defaults.headers.common[this.tokenHeader] = token
        })
        .catch(err => {
          throw new Error(`Could not read the collection token from ${process.env.SECRET_NAME}: ${err.message}`)
        })
      // handled by the request that waits for it
      this.tokenLoadedPromise.catch(() => {})
    } else if (config.has('apiToken')) {
      this.client.defaults.headers.common[this.tokenHeader] = config.get('apiToken')
      this.tokenLoadedPromise = Promise.resolve()
    } else {
      throw new Error('No authentication token available, specify SECRET_NAME or apiToken in env')
    }
  }

  async postGKEBatch(gkeLogsBatchSerialized, resourceIds, recordCount = 0) {
    if (!gkeLogsBatchSerialized) {
      throw new Error(
        'Missing the required parameter \'gkeLogsBatchSerialized\' when calling postKubernetesBatch',
      )
    }
    const resp = await this._requestHandler(
      'gke-audit',
      new GKELogsBatch(gkeLogsBatchSerialized, resourceIds, recordCount),
    )
    return resp.body
  }

  /**
   * Invokes the REST service using the supplied settings and parameters.
   * @param {String} path The URL path to invoke (auth prefixed by base url)
   * @param {Object} data The value to pass as the request body.
   * @returns {Object}
   */
  async _requestHandler(path, data) {
    await this.tokenLoadedPromise

    let resp
    try {
      resp = await this.client.post(path, data)
    } catch (e) {
      // An axios error holds the request, token header included, so only its
      // message and the response body go on
      const body = e?.response?.data
      const detail = body ? ` - ${(typeof body === 'string' ? body : JSON.stringify(body)).slice(0, 300)}` : ''
      throw new Error(`${e.message}${detail}`)
    }
    return { body: resp.data, statusCode: resp.status }
  }
}

module.exports = {
  RestClient,
  formatUrl,
}
