const {flowLogsMsgProto, FlowLogActionEnum} = require('../models/protobuf/proto')
const {Timestamp} = require('google-protobuf/google/protobuf/timestamp_pb')
const ianaProtocols = require('../models/iana.json')

const getProtocolName = (protocolCode) => {
  return ianaProtocols[protocolCode] || 'UNKNOWN'
}

exports.parseFlowlog = log => {
  const vpcFlowLog = flowLogsMsgProto.create()

  const vpcId = log.jsonPayload.src_vpc?.vpc_name || log.jsonPayload.dest_vpc?.vpc_name
  const instanceId = log.jsonPayload.src_instance?.vm_name || log.jsonPayload.dest_instance?.vm_name
  const instanceZone = log.jsonPayload.src_instance?.zone || log.jsonPayload.dest_instance?.zone

  vpcFlowLog.interfaceId = log.resource.labels.project_id // Used to store account_id as string
  vpcFlowLog.region = log.resource.labels.location
  vpcFlowLog.vpcId = `https://www.googleapis.com/compute/v1/projects/${vpcFlowLog.interfaceId}/global/networks/${vpcId}`
  vpcFlowLog.instanceId = `https://www.googleapis.com/compute/v1/projects/${vpcFlowLog.interfaceId}/zones/${instanceZone}/instances/${instanceId}`
  vpcFlowLog.subnetId = log.resource.labels.subnetwork_id
  vpcFlowLog.srcaddr = log.jsonPayload.connection.src_ip
  vpcFlowLog.srcport = log.jsonPayload.connection.src_port
  vpcFlowLog.dstaddr = log.jsonPayload.connection.dest_ip
  vpcFlowLog.dstport = log.jsonPayload.connection.dest_port

  vpcFlowLog.protocol = {
    protocol: getProtocolName(log.jsonPayload.connection.protocol),
    protocolCode: log.jsonPayload.connection.protocol,
  }

  vpcFlowLog.packets = Number(log.jsonPayload.packets_sent) || 0
  vpcFlowLog.bytes = Number(log.jsonPayload.bytes_sent) || 0


  const startTime = new Timestamp()
  startTime.fromDate(new Date(log.jsonPayload.start_time))
  vpcFlowLog.start = startTime.toObject()


  const endTime = new Timestamp()
  endTime.fromDate(new Date(log.jsonPayload.end_time))
  vpcFlowLog.endTime = endTime.toObject()


  // At the moment GCP Flowlogs do not include disposition field, but they do have it in Firewall logs
  // https://cloud.google.com/firewall/docs/firewall-rules-logging
  // We default to ACCEPT
  vpcFlowLog.action = log.jsonPayload.connection.disposition === 'DENIED' ?
    FlowLogActionEnum.REJECT :
    FlowLogActionEnum.ACCEPT
  vpcFlowLog.tcpFlags = 0 // At the moment TCP flags are not supported in GCP Flowlogs

  return vpcFlowLog
}