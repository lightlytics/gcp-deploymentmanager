class GKELogsBatch {
  constructor(gkeLogsBatchSerialized, resourceIds, recordCount) {
    return {
      records: gkeLogsBatchSerialized,
      recordCount,
      resource_ids: resourceIds,
      isCompressed: true,
    }
  }
}

module.exports = {
  GKELogsBatch,
}
