const { describe, it, before, after, beforeEach } = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const { gunzipSync } = require('node:zlib')

const deploymentCreate = {
  insertId: '0d6f4c1e-7a51-4d38-9a51-6c0f3c1f0a01',
  logName: 'projects/acme-prod/logs/cloudaudit.googleapis.com%2Factivity',
  protoPayload: {
    '@type': 'type.googleapis.com/google.cloud.audit.AuditLog',
    authenticationInfo: { principalEmail: 'dev@acme.io' },
    methodName: 'io.k8s.apps.v1.deployments.create',
    resourceName: 'apps/v1/namespaces/default/deployments/web',
    serviceName: 'k8s.io',
  },
  resource: {
    type: 'k8s_cluster',
    labels: {
      project_id: 'acme-prod',
      location: 'us-central1',
      cluster_name: 'web-cluster',
    },
  },
  timestamp: '2026-10-20T10:00:00.000000Z',
}

const secretRead = {
  insertId: '5b2e9f3a-1c44-4e7b-8f0d-2a6b9e4c7d02',
  logName: 'projects/acme-prod/logs/cloudaudit.googleapis.com%2Factivity',
  protoPayload: {
    '@type': 'type.googleapis.com/google.cloud.audit.AuditLog',
    authenticationInfo: { principalEmail: 'ci@acme-prod.iam.gserviceaccount.com' },
    methodName: 'io.k8s.core.v1.secrets.get',
    resourceName: 'core/v1/namespaces/payments/secrets/db-password',
    serviceName: 'k8s.io',
  },
  resource: {
    type: 'k8s_cluster',
    labels: {
      project_id: 'acme-prod',
      location: 'europe-west1-b',
      cluster_name: 'payments',
    },
  },
  timestamp: '2026-10-20T10:00:01.000000Z',
}

const TOPIC = 'projects/acme-prod/topics/streamsec-gke-audit-logs'
const BUCKET = 'acme-gke-logs'
const OBJECT_NAME =
  'cloudaudit.googleapis.com/activity/2026/10/20/10:00:00_10:59:59_S0.json'

const toBase64 = text => Buffer.from(text, 'utf-8').toString('base64')
const decodeRecords = batch =>
  JSON.parse(gunzipSync(Buffer.from(batch.records, 'base64')).toString())

// One local server stands in for both the Stream Security collection API and
// the Cloud Storage JSON API (through STORAGE_EMULATOR_HOST)
const apiBatches = []
const bucketObjects = new Map()
let fakeServer

const handleFakeRequest = (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  if (req.method === 'POST' && url.pathname === '/api/v1/collection/gke-audit') {
    let body = ''
    req.on('data', chunk => (body += chunk))
    req.on('end', () => {
      apiBatches.push(JSON.parse(body))
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end('{"successful":true}')
    })
    return
  }
  const objectPath = url.pathname.match(/\/b\/([^/]+)\/o\/([^/]+)$/)
  if (req.method === 'GET' && objectPath) {
    const key = `${decodeURIComponent(objectPath[1])}/${decodeURIComponent(objectPath[2])}`
    if (bucketObjects.has(key) && url.searchParams.get('alt') === 'media') {
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' })
      res.end(bucketObjects.get(key))
      return
    }
  }
  res.writeHead(404, { 'Content-Type': 'application/json' })
  res.end('{"error":{"code":404,"message":"Not Found"}}')
}

let gkeLogs
let getTestServer

const invoke = async (target, { headers = {}, body }) => {
  const server = getTestServer(target)
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  try {
    return await fetch(`http://127.0.0.1:${server.address().port}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body),
      // a callback style handler never responds, fail instead of hanging
      signal: AbortSignal.timeout(5000),
    })
  } finally {
    server.closeAllConnections()
    await new Promise(resolve => server.close(resolve))
  }
}

before(async () => {
  fakeServer = http.createServer(handleFakeRequest)
  await new Promise(resolve => fakeServer.listen(0, '127.0.0.1', resolve))
  const fakeUrl = `http://127.0.0.1:${fakeServer.address().port}`

  process.env.NODE_ENV = 'production'
  process.env.API_URL = fakeUrl
  process.env.API_TOKEN = 'test-token'
  process.env.STORAGE_EMULATOR_HOST = fakeUrl
  delete process.env.SECRET_NAME

  gkeLogs = require('../src/index')
  ;({ getTestServer } = require('@google-cloud/functions-framework/testing'))
})

after(async () => {
  fakeServer.closeAllConnections()
  await new Promise(resolve => fakeServer.close(resolve))
})

beforeEach(() => {
  apiBatches.length = 0
})

describe('PubSubGKELogsCollection', () => {
  const assertSentDeploymentCreate = () => {
    assert.equal(apiBatches.length, 1)
    assert.equal(apiBatches[0].recordCount, 1)
    assert.equal(apiBatches[0].isCompressed, true)
    assert.deepEqual(apiBatches[0].resource_ids, [
      'projects/acme-prod/locations/us-central1/clusters/web-cluster',
    ])
    assert.deepEqual(decodeRecords(apiBatches[0]), [deploymentCreate])
  }

  it('sends the log entry of a 2nd gen CloudEvent', async () => {
    const res = await invoke('PubSubGKELogsCollection', {
      headers: {
        'ce-specversion': '1.0',
        'ce-id': '11111111111',
        'ce-source': `//pubsub.googleapis.com/${TOPIC}`,
        'ce-type': 'google.cloud.pubsub.topic.v1.messagePublished',
        'ce-time': '2026-10-20T10:00:02.000Z',
      },
      body: {
        message: {
          data: toBase64(JSON.stringify(deploymentCreate)),
          attributes: {
            'logging.googleapis.com/timestamp': deploymentCreate.timestamp,
          },
          messageId: '11111111111',
          publishTime: '2026-10-20T10:00:02.000Z',
        },
        subscription:
          'projects/acme-prod/subscriptions/eventarc-us-central1-stream-sec-gke-logs-pubsub-123-sub-456',
      },
    })

    assert.ok(res.ok, `status ${res.status}`)
    assertSentDeploymentCreate()
  })

  it('sends the log entry of a 1st gen background event', async () => {
    const res = await invoke('PubSubGKELogsCollection', {
      body: {
        context: {
          eventId: '22222222222',
          timestamp: '2026-10-20T10:00:02.000Z',
          eventType: 'google.pubsub.topic.publish',
          resource: {
            service: 'pubsub.googleapis.com',
            name: TOPIC,
            type: 'type.googleapis.com/google.pubsub.v1.PubsubMessage',
          },
        },
        data: {
          '@type': 'type.googleapis.com/google.pubsub.v1.PubsubMessage',
          attributes: {
            'logging.googleapis.com/timestamp': deploymentCreate.timestamp,
          },
          data: toBase64(JSON.stringify(deploymentCreate)),
        },
      },
    })

    assert.ok(res.ok, `status ${res.status}`)
    assertSentDeploymentCreate()
  })

  it('sends the log entry when called with 1st gen (message, context) arguments', async () => {
    await gkeLogs.PubSubGKELogsCollection(
      {
        '@type': 'type.googleapis.com/google.pubsub.v1.PubsubMessage',
        attributes: {},
        data: toBase64(JSON.stringify(deploymentCreate)),
      },
      {
        eventId: '33333333333',
        timestamp: '2026-10-20T10:00:02.000Z',
        eventType: 'google.pubsub.topic.publish',
        resource: { service: 'pubsub.googleapis.com', name: TOPIC },
      },
    )

    assertSentDeploymentCreate()
  })

  it('acknowledges a malformed message without sending it', async t => {
    const consoleError = t.mock.method(console, 'error', () => {})

    const res = await invoke('PubSubGKELogsCollection', {
      headers: {
        'ce-specversion': '1.0',
        'ce-id': '44444444444',
        'ce-source': `//pubsub.googleapis.com/${TOPIC}`,
        'ce-type': 'google.cloud.pubsub.topic.v1.messagePublished',
      },
      body: {
        message: { data: toBase64('{"insertId": "trunc'), messageId: '44444444444' },
        subscription: 'projects/acme-prod/subscriptions/eventarc-sub',
      },
    })

    assert.ok(res.ok, `status ${res.status}`)
    assert.equal(apiBatches.length, 0)
    assert.equal(consoleError.mock.callCount(), 1)
  })
})

describe('StorageGKELogsCollection', () => {
  before(() => {
    bucketObjects.set(
      `${BUCKET}/${OBJECT_NAME}`,
      `${JSON.stringify(deploymentCreate)}\n${JSON.stringify(secretRead)}\n`,
    )
  })

  const storageObject = {
    kind: 'storage#object',
    id: `${BUCKET}/${OBJECT_NAME}/1760954400000000`,
    bucket: BUCKET,
    name: OBJECT_NAME,
    contentType: 'application/json',
    size: '1024',
    timeCreated: '2026-10-20T11:00:00.000Z',
    updated: '2026-10-20T11:00:00.000Z',
  }

  const assertSentWholeFile = () => {
    assert.equal(apiBatches.length, 1)
    assert.equal(apiBatches[0].recordCount, 2)
    assert.deepEqual(apiBatches[0].resource_ids, [
      'projects/acme-prod/locations/us-central1/clusters/web-cluster',
      'projects/acme-prod/locations/europe-west1-b/clusters/payments',
    ])
    assert.deepEqual(decodeRecords(apiBatches[0]), [deploymentCreate, secretRead])
  }

  it('sends every entry of the file of a 2nd gen CloudEvent', async () => {
    const res = await invoke('StorageGKELogsCollection', {
      headers: {
        'ce-specversion': '1.0',
        'ce-id': '55555555555',
        'ce-source': `//storage.googleapis.com/projects/_/buckets/${BUCKET}`,
        'ce-subject': `objects/${OBJECT_NAME}`,
        'ce-type': 'google.cloud.storage.object.v1.finalized',
        'ce-time': '2026-10-20T11:00:00.000Z',
      },
      body: storageObject,
    })

    assert.ok(res.ok, `status ${res.status}`)
    assertSentWholeFile()
  })

  it('sends every entry of the file of a 1st gen background event', async () => {
    const res = await invoke('StorageGKELogsCollection', {
      body: {
        context: {
          eventId: '66666666666',
          timestamp: '2026-10-20T11:00:00.000Z',
          eventType: 'google.storage.object.finalize',
          resource: {
            service: 'storage.googleapis.com',
            name: `projects/_/buckets/${BUCKET}/objects/${OBJECT_NAME}`,
            type: 'storage#object',
          },
        },
        data: storageObject,
      },
    })

    assert.ok(res.ok, `status ${res.status}`)
    assertSentWholeFile()
  })

  it('sends every entry when called with 1st gen (object, context) arguments', async () => {
    await gkeLogs.StorageGKELogsCollection(storageObject, {
      eventId: '77777777777',
      timestamp: '2026-10-20T11:00:00.000Z',
      eventType: 'google.storage.object.finalize',
      resource: {
        service: 'storage.googleapis.com',
        name: `projects/_/buckets/${BUCKET}/objects/${OBJECT_NAME}`,
      },
    })

    assertSentWholeFile()
  })
})
