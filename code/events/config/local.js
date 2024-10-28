// this is not a best practice for apps to use local.js with node-config but since it's a lambda and there is no such thing as "local"...
module.exports = {
  apiUrl: process.env.API_URL || 'http://localhost:4242',
  apiToken:
    process.env.API_TOKEN || '',
}
