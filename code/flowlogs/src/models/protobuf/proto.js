const protobuf = require('protobufjs')
const protoFilePath = './src/models/protobuf/collection.proto'

let pbRoot
let flowLogsBatchProto
let FlowLogsDeviceTypeEnum

const loadProtobuf = () => {
  if (!pbRoot) {
    pbRoot = protobuf.loadSync(protoFilePath)
    flowLogsBatchProto = pbRoot.lookupType('collection.VpcFlowLogs')
    FlowLogsDeviceTypeEnum = pbRoot.lookupEnum('collection.FlowLogsDeviceType')
  }

  return {
    flowLogsBatchProto,
    FlowLogsDeviceTypeEnum,
  }
}

loadProtobuf()

module.exports = {
  flowLogsBatchProto,
  FlowLogsDeviceTypeEnum,
}
