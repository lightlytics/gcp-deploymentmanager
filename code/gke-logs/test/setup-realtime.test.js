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
    assert.match(sink, /-protoPayload\.methodName=~"events\.\(create\|update\|patch\)\$"/)
    assert.match(sink, /-protoPayload\.status\.code=16/)
    assert.match(
      sink,
      /-\(protoPayload\.authenticationInfo\.principalEmail="system:anonymous" AND protoPayload\.status\.code=7\)/,
    )
    assert.match(sink, /OR protoPayload\.status\.code=7\\n/)
    // health probes read these paths anonymously all the time, allowed by the default
    // system:public-info-viewer role
    assert.match(
      sink,
      /-\(protoPayload\.authenticationInfo\.principalEmail="system:anonymous" AND protoPayload\.resourceName=~"\^\(healthz\|livez\|readyz\|version\)\(\/\|\$\)"\)/,
    )
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
      /--set-env-vars API_URL=https:\/\/acme\.streamsec\.io,SECRET_NAME=projects\/acme-prod\/secrets\/streamsec-gke-logs-token\/versions\/latest,/,
    )
    const [invoker] = callsTo(calls, 'functions add-invoker-policy-binding stream-sec-gke-logs-pubsub ')
    assert.match(invoker, new RegExp(`--member serviceAccount:${SERVICE_ACCOUNT}`))
  })

  it('deploys the function to batch the entries that arrive together', () => {
    const { status, stderr, calls } = run(INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    const [deploy] = callsTo(calls, 'functions deploy ')
    assert.match(deploy, /,BATCH_SIZE=500,BATCH_MAX_WAIT_MS=2000( |$)/)
    // one instance has to run many invocations at once for them to share a batch
    assert.match(deploy, /--concurrency 1000( |$)/)
    assert.match(deploy, /--cpu 1( |$)/)
    assert.match(deploy, /--memory 1Gi( |$)/)
    // room for the wait and a slow send
    assert.match(deploy, /--timeout 120s( |$)/)
  })

  it('sends to the scheme and host of the URL given, as a URL copied from the browser has a path', () => {
    const { status, stderr, stdout, calls } = run(
      ['--project', 'acme-prod', '--api-url', 'acme.streamsec.io/w/6123d08a/activities/audit', '--yes'],
      TOKEN,
    )

    assert.equal(status, 0, stderr)
    assert.match(callsTo(calls, 'functions deploy ')[0], /--set-env-vars API_URL=https:\/\/acme\.streamsec\.io,/)
    assert.match(stdout, /sending to https:\/\/acme\.streamsec\.io\n/)
  })

  it('deploys with the batch size and wait given', () => {
    const { status, stderr, calls } = run(
      [...INSTALL, '--batch-size', '100', '--batch-max-wait-ms', '5000'],
      TOKEN,
    )

    assert.equal(status, 0, stderr)
    assert.match(callsTo(calls, 'functions deploy ')[0], /,BATCH_SIZE=100,BATCH_MAX_WAIT_MS=5000( |$)/)
  })

  it('rejects a batch size or wait it cannot use before calling gcloud', () => {
    const size = /--batch-size takes a whole number from 1 to 1000/
    const wait = /--batch-max-wait-ms takes a whole number from 1 to 30000/
    const cases = [
      [['--batch-size', '0'], size],
      [['--batch-size', '1001'], size],
      [['--batch-size', 'many'], size],
      [['--batch-max-wait-ms', '0'], wait],
      [['--batch-max-wait-ms', '30001'], wait],
    ]
    for (const [args, message] of cases) {
      const { status, stderr, calls } = run([...INSTALL, ...args], TOKEN)

      assert.notEqual(status, 0, args.join(' '))
      assert.match(stderr, message)
      assert.deepEqual(calls, [])
    }
  })

  it('retries a grant while the new service account propagates, without showing the transient error', () => {
    const { status, stdout, stderr, calls } = run(INSTALL, {
      ...TOKEN,
      FAKE_FLAKY: 'secrets add-iam-policy-binding',
    })

    assert.equal(status, 0, stderr)
    assert.equal(callsTo(calls, 'secrets add-iam-policy-binding ').length, 2)
    assert.equal(callsTo(calls, 'sleep ').length, 1)
    assert.match(stdout, /retrying/)
    assert.doesNotMatch(stderr, /does not exist/)
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

const ORG = '555000111'
const ORG_INSTALL = [
  '--organization', ORG, '--project', 'acme-security', '--api-url', 'https://acme.streamsec.io', '--yes',
]
const CLUSTERS_FOUND = {
  FAKE_CLUSTERS: [
    '//container.googleapis.com/projects/web-prod/zones/europe-west1-b/clusters/frontend',
    '//container.googleapis.com/projects/payments-prod/locations/us-central1/clusters/api',
  ].join(' '),
}
const permissionCheck = (calls, resource) =>
  callsTo(calls, 'curl ').find(c => c.includes(`/${resource}:testIamPermissions`))
const changes = calls => gcloudCalls(calls).filter(c =>
  / (create|deploy|enable|update|delete|add-iam-policy-binding|add-invoker-policy-binding) /.test(` ${c} `),
)

describe('setup-realtime.sh --organization', () => {
  it('routes every project in the organization to one topic and function in the host project', () => {
    const { status, stderr, calls } = run(ORG_INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    const [sink] = callsTo(calls, 'logging sinks create streamsec-gke-audit-logs-pubsub ')
    assert.match(sink, / pubsub\.googleapis\.com\/projects\/acme-security\/topics\/streamsec-gke-audit-logs /)
    assert.match(sink, new RegExp(`--organization ${ORG}( |$)`))
    assert.match(sink, /--include-children/)
    assert.doesNotMatch(sink, /--project /)
    assert.doesNotMatch(sink, /project_id/)
    const [publisher] = callsTo(calls, 'pubsub topics add-iam-policy-binding streamsec-gke-audit-logs ')
    assert.match(publisher, new RegExp(`--member serviceAccount:service-org-${ORG}@gcp-sa-logging\\.iam\\.gserviceaccount\\.com`))
    const [deploy] = callsTo(calls, 'functions deploy stream-sec-gke-logs-pubsub ')
    assert.match(deploy, /--project acme-security /)
    assert.match(deploy, /SECRET_NAME=projects\/acme-security\/secrets\/streamsec-gke-logs-token\/versions\/latest/)
    assert.match(callsTo(calls, 'services enable ')[0], /cloudasset\.googleapis\.com/)
  })

  it('checks the sink permissions on the organization and the rest on the host project', () => {
    const { status, stderr, calls } = run(ORG_INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    assert.match(permissionCheck(calls, `organizations/${ORG}`), /logging\.sinks\.create/)
    const projectCheck = permissionCheck(calls, 'projects/acme-security')
    assert.match(projectCheck, /cloudfunctions\.functions\.create/)
    assert.doesNotMatch(projectCheck, /logging\.sinks/)
  })

  it('stops before changing anything when a permission on the organization is missing', () => {
    const { status, stderr, calls } = run(ORG_INSTALL, { ...TOKEN, FAKE_DENIED: 'logging.sinks.create' })

    assert.notEqual(status, 0)
    assert.match(stderr, new RegExp(`missing these permissions on organization ${ORG}`))
    assert.match(stderr, /logging\.sinks\.create.*roles\/logging\.configWriter/)
    assert.deepEqual(changes(calls), [])
  })

  it('stops before changing anything when it cannot check the organization, as for a wrong ID', () => {
    const { status, stderr, calls } = run(ORG_INSTALL, { ...TOKEN, FAKE_CURL_ERROR: `organizations/${ORG}` })

    assert.notEqual(status, 0)
    assert.match(stderr, new RegExp(`Could not check permissions on organization ${ORG}`))
    assert.deepEqual(changes(calls), [])
  })

  it('replaces the per-project sink of the host project, which would send its events twice', () => {
    preCreate('sink/streamsec-gke-audit-logs-pubsub')

    const { status, stderr, stdout, calls } = run(ORG_INSTALL, TOKEN)

    assert.equal(status, 0, stderr)
    assert.match(stdout, /per-project sink streamsec-gke-audit-logs-pubsub in acme-security will be removed/i)
    assert.match(permissionCheck(calls, 'projects/acme-security'), /logging\.sinks\.delete/)
    assert.equal(fs.existsSync(stateFile('sink/streamsec-gke-audit-logs-pubsub')), false)
    assert.equal(fs.existsSync(stateFile(`sink/organizations/${ORG}/streamsec-gke-audit-logs-pubsub`)), true)
    // the organization sink is in place before the project's goes, so no event is missed
    assert.ok(
      calls.findIndex(c => c.startsWith('logging sinks create ')) <
        calls.findIndex(c => c.startsWith('logging sinks delete ')),
    )
  })

  it('puts the collector in the current gcloud project when --project is not given', () => {
    const { status, stderr, calls } = run(
      ['--organization', ORG, '--api-url', 'https://acme.streamsec.io', '--yes'],
      { ...TOKEN, FAKE_CONFIG_PROJECT: 'acme-security' },
    )

    assert.equal(status, 0, stderr)
    assert.match(callsTo(calls, 'functions deploy ')[0], /--project acme-security /)
  })

  it('requires --project when gcloud has no current project and it cannot prompt', () => {
    const { status, stderr, calls } = run(
      ['--organization', ORG, '--api-url', 'https://acme.streamsec.io', '--yes'],
      TOKEN,
    )

    assert.notEqual(status, 0)
    assert.match(stderr, /Pass --project \(the project that will hold the collector\)/)
    assert.deepEqual(changes(calls), [])
  })

  it('lists the GKE clusters it finds before changing anything', () => {
    const { status, stderr, stdout, calls } = run(ORG_INSTALL, { ...TOKEN, ...CLUSTERS_FOUND })

    assert.equal(status, 0, stderr)
    const search = callsTo(calls, 'asset search-all-resources ')[0]
    assert.match(search, new RegExp(`--scope organizations/${ORG}( |$)`))
    assert.match(search, /--asset-types container\.googleapis\.com\/Cluster/)
    assert.match(search, /--billing-project acme-security/)
    assert.match(stdout, /payments-prod: api \(us-central1\)\n.*web-prod: frontend \(europe-west1-b\)/)
    assert.ok(calls.indexOf(search) < calls.findIndex(c => c.startsWith('services enable')))
  })

  it('sets up anyway when it cannot list the clusters', () => {
    const { status, stderr, stdout, calls } = run(ORG_INSTALL, {
      ...TOKEN,
      FAKE_ASSET_ERROR: 'ERROR: (gcloud.asset.search-all-resources) PERMISSION_DENIED: denied',
    })

    assert.equal(status, 0, stderr)
    assert.match(stdout, /Could not list the clusters.*PERMISSION_DENIED/)
    assert.equal(callsTo(calls, 'functions deploy ').length, 1)
  })

  it('limits the sink and the cluster list to the projects given with --projects', () => {
    const { status, stderr, stdout, calls } = run(
      [...ORG_INSTALL, '--projects', 'payments-prod, web-staging,'],
      { ...TOKEN, ...CLUSTERS_FOUND },
    )

    assert.equal(status, 0, stderr)
    const [sink] = callsTo(calls, 'logging sinks create ')
    assert.match(
      sink,
      /\(resource\.labels\.project_id="payments-prod" OR resource\.labels\.project_id="web-staging"\)/,
    )
    assert.doesNotMatch(sink, /project_id="( |")/)
    assert.match(stdout, /payments-prod: api/)
    assert.doesNotMatch(stdout, /frontend/)
  })

  it('shows why when the organization sink cannot be created', () => {
    const { status, stderr } = run(ORG_INSTALL, { ...TOKEN, FAKE_FLAKY: 'logging sinks create' })

    assert.notEqual(status, 0)
    assert.match(stderr, /\(gcloud\.logging sinks create\) Status code: 400/)
  })

  it('uses a folder sink with --folder', () => {
    const { status, stderr, calls } = run(
      ['--folder', '777', '--project', 'acme-security', '--api-url', 'https://acme.streamsec.io', '--yes'],
      TOKEN,
    )

    assert.equal(status, 0, stderr)
    const [sink] = callsTo(calls, 'logging sinks create ')
    assert.match(sink, /--folder 777( |$)/)
    assert.match(sink, /--include-children/)
    assert.match(permissionCheck(calls, 'folders/777'), /logging\.sinks\.create/)
    assert.match(callsTo(calls, 'asset search-all-resources ')[0], /--scope folders\/777( |$)/)
  })

  it('rejects option combinations it cannot use before calling gcloud', () => {
    const cases = [
      [[...INSTALL, '--projects', 'payments-prod'], /--projects/],
      [[...ORG_INSTALL, '--folder', '777'], /--organization or --folder/],
      [['--organization', 'organizations/555', '--project', 'acme-security', '--yes'], /numeric/],
    ]
    for (const [args, message] of cases) {
      const { status, stderr, calls } = run(args, TOKEN)

      assert.notEqual(status, 0, args.join(' '))
      assert.match(stderr, message)
      assert.deepEqual(calls, [])
    }
  })

  it('removes the organization sink and the collector in the host project with --uninstall', () => {
    run(ORG_INSTALL, TOKEN)

    const { status, stderr, calls } = run(
      ['--organization', ORG, '--project', 'acme-security', '--uninstall', '--yes'],
    )

    assert.equal(status, 0, stderr)
    assert.match(permissionCheck(calls, `organizations/${ORG}`), /logging\.sinks\.delete/)
    assert.equal(fs.existsSync(stateFile(`sink/organizations/${ORG}/streamsec-gke-audit-logs-pubsub`)), false)
    assert.equal(fs.existsSync(stateFile('function/stream-sec-gke-logs-pubsub')), false)
    assert.equal(fs.existsSync(stateFile('topic/streamsec-gke-audit-logs')), false)
    assert.equal(
      fs.existsSync(stateFile('service-account/streamsec-gke-audit@acme-security.iam.gserviceaccount.com')),
      false,
    )
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
