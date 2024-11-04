class FlowLogsBatch {
  constructor(flowLogsSerializedBatch, recordCount) {
    return {
      flowLogRecords: flowLogsSerializedBatch,
      recordCount,
      isCompressed: true,
    }
  }
}

module.exports = {
  FlowLogsBatch,
}
