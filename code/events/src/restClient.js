const axios = require('axios')
const config = require('config')
const { getSecretValue } = require('./secretManager')

// The Stream Security URL with https:// when no scheme is given, and without
// trailing slashes. The token travels in a header, so plain http is refused
// except to a local test server. The host is read from the parsed URL:
// http://localhost@remote.example is remote.example.
function formatUrl(url) {
  const withScheme = /^https?:\/\//i.test(url) ? url : `https://${url}`
  const { protocol, hostname } = new URL(withScheme)
  if (protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(hostname)) {
    throw new Error('API_URL must use https')
  }
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
      timeout: 5 * 1000,
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json;q=0.5, text/plain;q=0.1',
      },
    })

    // Set authentication token - from Secret Manager or config
    if (process.env.SECRET_NAME) {
      this.tokenLoadedPromise = getSecretValue(process.env.SECRET_NAME)
        .then(token => {
          this.client.defaults.headers.common[this.tokenHeader] = token
        })
        .catch(err => {
          console.error('Failed to get API token from Secret Manager:', err)
        })
    } else if (config.has('apiToken')) {
      this.client.defaults.headers.common[this.tokenHeader] = config.get('apiToken')
      this.tokenLoadedPromise = Promise.resolve()
    } else {
      throw new Error('No authentication token available, specify SECRET_NAME or apiToken in env')
    }
  }

  async postAuditEvent(event) {
    if (!event) {
      throw new Error(
        'postAuditEvent: missing event parameter. Cannot send empty event',
      )
    }
    const resp = await this._requestHandler('gcp-audit-log', event)
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
}
