const { SecretManagerServiceClient } = require('@google-cloud/secret-manager')

const secretCache = new Map()
const DEFAULT_TTL_MS = 60 * 60 * 1000

async function getSecretValue(secretName) {
  const cached = secretCache.get(secretName)
  if (cached && cached.expiresAt > Date.now()) {
    return cached.value
  }

  try {
    // Check if this is a regional secret (contains /locations/)
    const isRegional = secretName.includes('/locations/')
    
    let client
    if (isRegional) {
      // Extract region from secret name
      const regionMatch = secretName.match(/\/locations\/([^\/]+)\//)
      if (!regionMatch) {
        throw new Error('Invalid regional secret format. Expected: projects/*/locations/*/secrets/*/versions/*')
      }
      const region = regionMatch[1]
      client = new SecretManagerServiceClient({
        apiEndpoint: `secretmanager.${region}.rep.googleapis.com`
      })
    } else {
      client = new SecretManagerServiceClient()
    }

    const [version] = await client.accessSecretVersion({
      name: secretName,
    })
    const secretValue = version.payload.data.toString()

    secretCache.set(secretName, {
      value: secretValue,
      expiresAt: Date.now() + DEFAULT_TTL_MS
    })

    return secretValue
  } catch (error) {
    console.error(`Error retrieving secret ${secretName} from Secret Manager:`, error)
    throw error
  }
}

module.exports = {
  getSecretValue,
}
