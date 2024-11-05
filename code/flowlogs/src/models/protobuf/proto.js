const protobuf = require('protobufjs')
const protoFilePath = './src/models/protobuf/collection.proto'

let pbRoot
let flowLogsMsgProto
let flowLogsBatchProto
let FlowLogsDeviceTypeEnum
let FlowLogActionEnum

const loadProtobuf = () => {
  if (!pbRoot) {
    pbRoot = protobuf.loadSync(protoFilePath)
    flowLogsMsgProto = pbRoot.lookupType('collection.VpcFlowLog')
    flowLogsBatchProto = pbRoot.lookupType('collection.VpcFlowLogs')
    FlowLogsDeviceTypeEnum = pbRoot.lookupEnum('collection.FlowLogsDeviceType')
    FlowLogActionEnum = pbRoot.lookupEnum('collection.FlowLogAction')
  }

  return {
    flowLogsMsgProto,
    flowLogsBatchProto,
    FlowLogsDeviceTypeEnum,
    FlowLogActionEnum,
  }
}

loadProtobuf()

module.exports = {
  flowLogsBatchProto,
  FlowLogsDeviceTypeEnum,
  FlowLogActionEnum,
  flowLogsMsgProto,
}
