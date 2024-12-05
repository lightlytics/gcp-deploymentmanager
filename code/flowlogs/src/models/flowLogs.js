class FlowLogsBatch {
  constructor(flowLogsSerializedBatch, accountId, recordCount) {
    return {
      flowLogRecords: flowLogsSerializedBatch,
      recordCount,
      accountId,
      isCompressed: true,
    }
  }
}

module.exports = {
  FlowLogsBatch,
}
