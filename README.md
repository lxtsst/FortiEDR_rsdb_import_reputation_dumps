#FortiEDR RSDB Reputation Dump 自动导入脚本使用说明

中文 | [English](README.en.md)

## 脚本位置

RSDB 服务器上的脚本路径：

```bash
/tmp/rsdb_import_reputation_dumps.sh
```

该脚本用于自动导入 `/tmp` 目录下的 FortiEDR Reputation dump zip 文件。

## 脚本功能

- 自动发现 `/tmp` 下的以下文件：
  - `reputation-full-*-part_part_*.zip`
  - `reputation-week-*-part_part_*.zip`
  - `reputation-day-*-part_part_*.zip`
- 自动按顺序导入：`full` -> `week` -> `day`。
- 同类型文件按日期和 part 编号排序导入。
- 使用 `/tmp/rsdb_ramwork` 作为 `tmpfs` 内存工作目录，避免大 full 包签名校验超时。
- 防止重复导入，判断依据包括：
  - `/var/lib/reputationdb/import_state/imported_dumps.tsv`
  - `/var/log/reputationdb/cli/reputationdb.log*`
- 成功导入后记录文件名、大小、sha256、路径和时间。
- 自动清理 `/tmp` 下超过 15 天且已确认导入成功的 dump zip 文件。
- 如果已有 `reputationdb load-dump` 进程在运行，脚本会退出，避免并发导入。

## 重要注意事项

- 必须使用 `root` 用户运行。
- 不要在已有导入任务运行时再次启动脚本。
- 如果 RocksDB 被重建、清空或从备份恢复，需要检查或清理状态文件：

```bash
/var/lib/reputationdb/import_state/imported_dumps.tsv
```

否则脚本可能会根据旧状态跳过某些文件，但这些数据实际已经不在 RocksDB 中。

脚本运行时可能提示 `reputationDBServer --server` 正在运行。这个服务是 RSDB 常驻服务，通常可以继续导入。只有在导入失败并出现 RocksDB `LOCK` 错误时，才考虑停止服务后重试。

## 推荐使用流程

1. 将 dump zip 文件上传到 RSDB 的 `/tmp` 目录。

2. 确认当前没有导入任务正在运行：

```bash
ps -eo pid,etime,pcpu,pmem,args | grep "reputationdb load-dump" | grep -v grep || true
```

3. 先使用 dry-run 查看导入计划：

```bash
/tmp/rsdb_import_reputation_dumps.sh --dry-run
```

重点检查：

- full、week、day 的导入顺序是否正确；
- 已导入的文件是否显示为 `SKIP`；
- 待导入的新文件是否显示为 `IMPORT`；
- 是否有旧文件清理提示；
- 是否有空间不足或 part 缺失提示。

4. 确认计划无误后正式执行：

```bash
/tmp/rsdb_import_reputation_dumps.sh
```

也可以只导入某一种类型：

```bash
/tmp/rsdb_import_reputation_dumps.sh --type full
/tmp/rsdb_import_reputation_dumps.sh --type week
/tmp/rsdb_import_reputation_dumps.sh --type day
```

## 运行状态检查

查看当前是否有导入进程：

```bash
ps -eo pid,etime,pcpu,pmem,args | grep "reputationdb load-dump" | grep -v grep || true
```

查看 Reputation DB CLI 详细日志：

```bash
tail -f /var/log/reputationdb/cli/reputationdb.log
```

查看脚本为每个文件生成的独立日志：

```bash
ls -lh /var/log/reputationdb/import_runner/
tail -f /var/log/reputationdb/import_runner/*.log
```

查看内存工作目录空间和临时文件：

```bash
df -h /tmp/rsdb_ramwork
ls -lh /tmp/rsdb_ramwork
```

查看 RocksDB 数据目录大小和磁盘空间：

```bash
du -sh /var/lib/reputationdb/rocksdb_data
df -h /var/lib/reputationdb/rocksdb_data /
```

## 成功日志判断

成功导入时，`/var/log/reputationdb/cli/reputationdb.log` 中通常会出现：

```text
Metadata saved
Load dump successfully
```

导入过程中，常见的正常进度日志包括：

```text
LoadFile: Loading reputation file ...
Loaded 10000 hashes to save
Saving batch, Batch size: 10000
```

看到这些日志说明已经进入实际写库阶段。

## 常见失败情况

如果签名验证超时，日志可能出现：

```text
Signature verification failed: verification timed out after 5 minutes
```

脚本会输出明确失败提示，并清理 `/tmp/rsdb_ramwork` 中的临时 `data_reputation-*` 文件。清理后可以重新运行脚本重试。

如果已有导入任务正在运行，脚本会直接退出，不会启动第二个导入任务。

如果 `/tmp/rsdb_ramwork` 空间不足，脚本会在导入前退出，并显示当前可用空间和需要的空间。

如果根分区或 RocksDB 所在文件系统剩余空间不足，脚本也会提前退出。

## 自动清理逻辑

每次脚本运行时会检查 `/tmp` 下超过 15 天的 dump zip 文件。

只会删除满足以下条件的文件：

- 文件名匹配 reputation dump 格式；
- 文件修改时间超过 15 天；
- 已确认成功导入过。

未确认导入成功的旧文件不会删除，脚本会输出类似：

```text
KEEP old dump not confirmed imported
```

dry-run 模式下不会真正删除文件，只会显示：

```text
DRY-RUN would delete old imported dump
```

## 状态文件说明

脚本会记录成功导入过的文件：

```bash
/var/lib/reputationdb/import_state/imported_dumps.tsv
```

记录内容包括：

- 导入时间；
- 文件名；
- 文件大小；
- sha256；
- 文件路径。

一般情况下不要手动修改该文件。只有在 RocksDB 重建、清空、回滚或从备份恢复后，才需要检查或清理它。

## 脚本校验

当前脚本 SHA256：

```text
3bd72aff9605b1b1d3d11da0f92956f2f3e1c6cbd14a89b13ed91c751c034661
```

在 RSDB 服务器上可以用以下命令校验：

```bash
sha256sum /tmp/rsdb_import_reputation_dumps.sh
```
