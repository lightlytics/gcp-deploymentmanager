const { SecretManagerServiceClient } = require('@google-cloud/secret-manager')

async function getSecretValue(secretName) {
  const client = new SecretManagerServiceClient()
  const [version] = await client.accessSecretVersion({
    name: secretName,
  })
  return version.payload.data.toString()
}

module.exports = {
  getSecretValue,
}
