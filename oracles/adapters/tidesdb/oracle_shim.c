#include "tidesdb.h"
#include "tidesdb_version.h"

#include <stdint.h>
#include <string.h>

#define FLYOLOGY_TIDESDB_SHA "23a67a6531bc6c0b537d3696758c7879586dcfce"

const char *flyology_tidesdb_expected_sha(void) { return FLYOLOGY_TIDESDB_SHA; }

const char *flyology_tidesdb_header_version(void) { return TIDESDB_VERSION; }

int flyology_tidesdb_open(const char *path, tidesdb_t **database) {
  if (path == NULL || path[0] == '\0' || database == NULL)
    return TDB_ERR_INVALID_ARGS;

  tidesdb_config_t config = tidesdb_default_config();
  config.db_path = (char *)path;
  config.num_flush_threads = 2;
  config.num_compaction_threads = 1;
  config.log_level = TDB_LOG_NONE;
  config.block_cache_size = 8U * 1024U * 1024U;
  config.max_open_sstables = 64;
  config.log_to_file = 0;
  config.log_truncation_at = 0;
  config.max_memory_usage = 64U * 1024U * 1024U;
  config.unified_memtable = 1;
  config.unified_memtable_write_buffer_size = 8U * 1024U * 1024U;
  config.unified_memtable_skip_list_max_level = 12;
  config.unified_memtable_skip_list_probability = 0.25F;
  config.unified_memtable_sync_mode = TDB_SYNC_FULL;
  config.unified_memtable_sync_interval_us = 0;
  config.object_store = NULL;
  config.object_store_config = NULL;
  config.max_concurrent_flushes = 2;
  config.finish_compactions_on_close = 1;
  return tidesdb_open(&config, database);
}

int flyology_tidesdb_create_column_family(tidesdb_t *database,
                                          const char *name) {
  if (database == NULL || name == NULL || name[0] == '\0')
    return TDB_ERR_INVALID_ARGS;

  tidesdb_column_family_config_t config =
      tidesdb_default_column_family_config();
  config.write_buffer_size = 4U * 1024U * 1024U;
  config.compression_algorithm = TDB_COMPRESS_NONE;
  config.sync_mode = TDB_SYNC_FULL;
  config.sync_interval_us = 0;
  config.default_isolation_level = TDB_ISOLATION_SNAPSHOT;
  config.min_disk_space = 0;
  config.l0_queue_stall_threshold = 8;
  config.object_prefetch_compaction = 0;
  (void)strncpy(config.comparator_name, "memcmp",
                sizeof(config.comparator_name) - 1U);
  config.comparator_name[sizeof(config.comparator_name) - 1U] = '\0';
  return tidesdb_create_column_family(database, name, &config);
}
