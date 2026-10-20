const { describe, it, beforeEach, afterEach } = require('node:test')
const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

// bash on Windows (Git Bash) reads forward slashes reliably
const posix = p => p.replace(/\\/g, '/')

const SCRIPT = posix(path.join(__dirname, '..', 'setup-realtime.sh'))
const FAKES = path.join(__dirname, 'fakes')
const SERVICE_ACCOUNT = 'streamsec-gke-audit@acme-prod.iam.gserviceaccount.com'
const INSTALL = ['--project', 'acme-prod', '--api-url', 'https://acme.streamsec.io', '--yes']
const TOKEN = { STREAMSEC_COLLECTION_TOKEN: 'collection-token-123' }

let sandbox

beforeEach(() => {
  sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'setup-realtime-'))
})

afterEach(() => {
  fs.rmSync(sandbox, { recursive: true, force: true })
})

// Runs the script with fake gcloud and curl, stdin closed (not interactive)
const run = (args, env = {}) => {
  const log = path.join(sandbox, 'calls.log')
  fs.rmSync(log, { force: true })
  const result = spawnSync('bash', [SCRIPT, ...args], {
    encoding: 'utf8',
    input: '',
    env: {
      ...process.env,
      PATH: `${FAKES}${path.delimiter}${process.env.PATH}`,
      FAKE_LOG: posix(log),
      FAKE_STATE: posix(path.join(sandbox, 'state')),
      STREAMSEC_COLLECTION_TOKEN: '',
      ...env,
    },
  })
  const calls = fs.existsSync(log)
    ? fs.readFileSync(log, 'utf8').trim().split('\n')
    : []
  return { ...result, calls }
}

const gcloudCalls = calls => calls.filter(c => !c.startsWith('curl '))
const callsTo = (calls, command) => calls.filter(c => c.startsWith(command))
const stateFile = rel => path.join(sandbox, 'state', rel)
const preCreate = rel => {
  fs.mkdirSync(path.dirname(stateFile(rel)), { recursive: true })
  fs.writeFileSync(stateFile(rel), '')
}

describe('setup-realtime.sh install', () => {
  it('stores the collection token in a new global secret', () => {
    const { status, stderr } = run(INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    assert.equal(
      fs.readFileSync(stateFile('secret/streamsec-gke-logs-token'), 'utf8'),
      'collection-token-123',
    )
  })

  it('creates a dedicated service account that can read only that secret', () => {
    const { status, stderr, calls } = run(INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    assert.equal(callsTo(calls, 'iam service-accounts create streamsec-gke-audit ').length, 1)
    const [grant] = callsTo(calls, 'secrets add-iam-policy-binding streamsec-gke-logs-token ')
    assert.match(grant, new RegExp(`--member serviceAccount:${SERVICE_ACCOUNT}( |$)`))
    assert.match(grant, /--role roles\/secretmanager\.secretAccessor/)
  })

  it('creates the sink with the audit filter and lets it publish to the topic', () => {
    const { status, stderr, calls } = run(INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    assert.equal(callsTo(calls, 'pubsub topics create streamsec-gke-audit-logs ').length, 1)
    const [sink] = callsTo(calls, 'logging sinks create streamsec-gke-audit-logs-pubsub ')
    assert.match(sink, / pubsub\.googleapis\.com\/projects\/acme-prod\/topics\/streamsec-gke-audit-logs /)
    assert.match(sink, /resource\.type="k8s_cluster"/)
    assert.match(sink, /-protoPayload\.authenticationInfo\.principalEmail=~"system:"/)
    assert.doesNotMatch(sink, /cluster_name/)
    const [publisher] = callsTo(calls, 'pubsub topics add-iam-policy-binding streamsec-gke-audit-logs ')
    assert.match(publisher, /--member serviceAccount:service-123456789012@gcp-sa-logging\.iam\.gserviceaccount\.com/)
    assert.match(publisher, /--role roles\/pubsub\.publisher/)
  })

  it('deploys the function as the service account and lets only it invoke the function', () => {
    const { status, stderr, calls } = run(INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    const [deploy] = callsTo(calls, 'functions deploy stream-sec-gke-logs-pubsub ')
    assert.match(deploy, /--gen2/)
    assert.match(deploy, /--region us-central1/)
    assert.match(deploy, /--trigger-topic streamsec-gke-audit-logs/)
    assert.match(deploy, /--entry-point PubSubGKELogsCollection/)
    assert.match(deploy, /--source gs:\/\/streamsec-production-public-artifacts\/gcp-gke-logs-collection\.zip/)
    assert.match(deploy, new RegExp(`--service-account ${SERVICE_ACCOUNT}`))
    assert.match(deploy, new RegExp(`--trigger-service-account ${SERVICE_ACCOUNT}`))
    assert.match(
      deploy,
      /--set-env-vars API_URL=https:\/\/acme\.streamsec\.io,SECRET_NAME=projects\/acme-prod\/secrets\/streamsec-gke-logs-token\/versions\/latest/,
    )
    const [invoker] = callsTo(calls, 'functions add-invoker-policy-binding stream-sec-gke-logs-pubsub ')
    assert.match(invoker, new RegExp(`--member serviceAccount:${SERVICE_ACCOUNT}`))
  })

  it('reuses an existing secret without asking for a token', () => {
    preCreate('secret/streamsec-gke-logs-token')

    const { status, stderr, calls } = run(INSTALL)

    assert.equal(status, 0, stderr)
    assert.equal(callsTo(calls, 'secrets create').length, 0)
  })

  it('stops when the secret is missing and no token is given', () => {
    const { status, stderr, calls } = run(INSTALL)

    assert.notEqual(status, 0)
    assert.match(stderr, /STREAMSEC_COLLECTION_TOKEN/)
    assert.equal(callsTo(calls, 'secrets create').length, 0)
  })

  it('updates the sink and creates nothing twice when run again', () => {
    run(INSTALL, TOKEN)

    const { status, stderr, calls } = run(INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    const creates = gcloudCalls(calls).filter(c => / create /.test(` ${c} `))
    assert.deepEqual(creates, [])
    assert.equal(callsTo(calls, 'logging sinks update streamsec-gke-audit-logs-pubsub ').length, 1)
    assert.equal(callsTo(calls, 'functions deploy stream-sec-gke-logs-pubsub ').length, 1)
  })

  it('limits the sink to the clusters given with --cluster', () => {
    const { status, stderr, calls } = run(
      [...INSTALL, '--cluster', 'payments', '--cluster', 'web'],
      TOKEN,
    )

    assert.equal(status, 0, stderr)
    const [sink] = callsTo(calls, 'logging sinks create ')
    assert.match(
      sink,
      /\(resource\.labels\.cluster_name="payments" OR resource\.labels\.cluster_name="web"\)/,
    )
  })

  it('uses the regional secret with --secret-location', () => {
    const { status, stderr, calls } = run([...INSTALL, '--secret-location', 'europe-west1'], TOKEN)

    assert.equal(status, 0, stderr)
    const [create] = callsTo(calls, 'secrets create ')
    assert.match(create, /--location europe-west1/)
    assert.doesNotMatch(create, /--replication-policy/)
    assert.match(callsTo(calls, 'secrets add-iam-policy-binding ')[0], /--location europe-west1/)
    assert.match(
      callsTo(calls, 'functions deploy ')[0],
      /SECRET_NAME=projects\/acme-prod\/locations\/europe-west1\/secrets\/streamsec-gke-logs-token\/versions\/latest/,
    )
  })

  it('deploys from the --source given', () => {
    const { status, stderr, calls } = run(
      [...INSTALL, '--source', 'gs://streamsec-public-artifacts/gcp-gke-logs-collection.zip'],
      TOKEN,
    )

    assert.equal(status, 0, stderr)
    assert.match(
      callsTo(calls, 'functions deploy ')[0],
      /--source gs:\/\/streamsec-public-artifacts\/gcp-gke-logs-collection\.zip/,
    )
  })

  it('stops before changing anything when a permission is missing', () => {
    const { status, stderr, calls } = run(INSTALL, {
      ...TOKEN,
      FAKE_DENIED: 'logging.sinks.create iam.serviceAccounts.actAs',
    })

    assert.notEqual(status, 0)
    assert.match(stderr, /logging\.sinks\.create.*roles\/logging\.configWriter/)
    assert.match(stderr, /iam\.serviceAccounts\.actAs.*roles\/iam\.serviceAccountUser/)
    const changes = gcloudCalls(calls).filter(c =>
      / (create|deploy|enable|update|delete|add-iam-policy-binding|add-invoker-policy-binding) /.test(` ${c} `),
    )
    assert.deepEqual(changes, [])
  })

  it('requires --project when it cannot prompt', () => {
    const { status, stderr, calls } = run(['--api-url', 'https://acme.streamsec.io', '--yes'], {
      ...TOKEN,
      FAKE_CONFIG_PROJECT: 'some-default-project',
    })

    assert.notEqual(status, 0)
    assert.match(stderr, /--project/)
    assert.equal(callsTo(calls, 'services enable').length, 0)
  })
})

describe('setup-realtime.sh --uninstall', () => {
  it('removes the sink, function, topic and service account but keeps the secret', () => {
    run(INSTALL, TOKEN)

    const { status, stderr } = run(['--project', 'acme-prod', '--uninstall', '--yes'])

    assert.equal(status, 0, stderr)
    assert.equal(fs.existsSync(stateFile('sink/streamsec-gke-audit-logs-pubsub')), false)
    assert.equal(fs.existsSync(stateFile('function/stream-sec-gke-logs-pubsub')), false)
    assert.equal(fs.existsSync(stateFile('topic/streamsec-gke-audit-logs')), false)
    assert.equal(fs.existsSync(stateFile(`service-account/${SERVICE_ACCOUNT}`)), false)
    assert.equal(fs.existsSync(stateFile('secret/streamsec-gke-logs-token')), true)
  })

  it('also deletes the secret with --delete-secret', () => {
    run(INSTALL, TOKEN)

    const { status, stderr } = run(['--project', 'acme-prod', '--uninstall', '--delete-secret', '--yes'])

    assert.equal(status, 0, stderr)
    assert.equal(fs.existsSync(stateFile('secret/streamsec-gke-logs-token')), false)
  })

  it('skips what is already gone', () => {
    const { status, stderr } = run(['--project', 'acme-prod', '--uninstall', '--yes'])

    assert.equal(status, 0, stderr)
  })
})
