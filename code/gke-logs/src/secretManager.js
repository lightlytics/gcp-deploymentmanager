const { SecretManagerServiceClient } = require('@google-cloud/secret-manager')

const secretCache = new Map()
const DEFAULT_TTL_MS = 60 * 60 * 1000

async function getSecretValue(secretName) {
  const cached = secretCache.get(secretName)
  if (cached && cached.expiresAt > Date.now()) {
    console.log(`Using cached secret for ${secretName}`)
    return cached.value
  }

  console.log(`Retrieving secret ${secretName} from Secret Manager`)
  const client = new SecretManagerServiceClient()
  const [version] = await client.accessSecretVersion({
    name: secretName,
  })
  const secretValue = version.payload.data.toString()

  secretCache.set(secretName, {
    value: secretValue,
    expiresAt: Date.now() + DEFAULT_TTL_MS,
  })

  return secretValue
}

module.exports = {
  getSecretValue,
}
