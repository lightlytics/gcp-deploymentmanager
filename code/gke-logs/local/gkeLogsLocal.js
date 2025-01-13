const {processGKELogFile} = require('../src/index.js')
const fs = require('fs')
const path = require('path');

(async function gkeLogsCollectorLocalRun() {
  console.log(`Running GKE Logs Collection Lambda Local - ENV: ${process.env.NODE_ENV}`)

  const mocksDir = './mocks'

  fs.readdir(mocksDir, (err, files) => {
    if (err) {
      return console.error('Unable to scan directory:', err)
    }

    files.forEach(file => {
      const filePath = path.join(mocksDir, file)
      fs.readFile(filePath, 'utf8', async (err, data) => {
        if (err) {
          return console.error('Unable to read file:', err)
        }

        try {
          await processGKELogFile(data)
        } catch (e) {
          console.error('Error processing K8s Logs:', e)
        }
      })
    })
  })
})()