# FortiEDR RSDB Reputation Dump 导入工具

中文 | [English](README.en.md)

本项目提供一套带防护机制的 Shell 脚本，用于在 Air-Gap 或离线部署的
FortiEDR RSDB 服务器中导入 Reputation dump 更新包。适用于在联网环境下载
更新包后，再上传至 RSDB 服务器 `/tmp` 目录的运维场景。

> 本工具不是 Fortinet 官方产品组件。生产使用前，请先在测试 RSDB 上验证。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `rsdb_import_reputation_dumps.sh` | 常规 RSDB Reputation dump 安全导入脚本。 |

## 运行要求

- 必须以 `root` 用户在 RSDB 服务器上运行。
- 已安装且可正常调用 `reputationdb` CLI。
- 系统需要具备 `bash`、`find`、`sort`、`stat`、`flock`、`mount`、`findmnt`
  和 `df` 等标准 Linux 工具。
- 更新包必须直接放在 `/tmp` 中，并保持原始文件名格式：

  ```text
  reputation-full-YYYY-MM-DD-part_part_N.zip
  reputation-week-YYYY-MM-DD-part_part_N.zip
  reputation-day-YYYY-MM-DD-part_part_N.zip
  ```

- 脚本使用 `/tmp/rsdb_ramwork` 作为 `tmpfs` 工作目录；需要时会自动挂载，且
  要求存在足以容纳当前包大小加 1 GiB 的内存工作空间。

## 快速开始

将主脚本上传到 RSDB 服务器后，必须先执行 dry-run：

```bash
chmod 700 /tmp/rsdb_import_reputation_dumps.sh
/tmp/rsdb_import_reputation_dumps.sh --dry-run
```

确认计划正确后，执行正式导入：

```bash
/tmp/rsdb_import_reputation_dumps.sh
```

如需在单包日志之外保留一份完整终端日志：

```bash
set -o pipefail
/tmp/rsdb_import_reputation_dumps.sh 2>&1 | tee "/var/log/reputationdb/import_runner/import_$(date '+%Y%m%d_%H%M%S').log"
```

常规更新不要直接调用 `reputationdb load-dump`。主脚本提供了原厂 CLI 本身
没有的排序、覆盖判断、日志和状态保护。

## 脚本功能

### 更新包发现与排序

- 自动发现 `/tmp` 中匹配的 full、week 和 day 更新包。
- full 包始终优先处理。
- 其后的 week 与 day 包按日期排序；同一天时，week 包先于 day 包。
- 同一更新包的多个 part 按 part 编号递增导入。
- 如果某个必需 part 缺失且未被确认处理，脚本会停止。

### 重复包与覆盖判断

- 通过 `/var/lib/reputationdb/import_state/imported_dumps.tsv` 中匹配的文件名和
  文件大小跳过已处理包。
- 在生成计划前、以及每个包成功导入后，读取
  `reputationdb last-dump-metadata`。
- 以周包实际返回的 metadata `from/to` 范围为依据，跳过其覆盖的日包；此类
  跳过会写入 `metadata_coverage` 状态，避免未来游标继续推进后再次加载该文件。
- 不会仅因 metadata 日期更新就把所有更早文件视为已导入。
- 同名但大小不同的文件仍会作为新候选包交给产品校验。

### 连续更新链保护

在导入前，脚本从当前 RSDB metadata 游标开始验证增量更新链是否连续。它会检测：

- 下一个 week 或 day 包之前存在缺失时间段；
- 回补包早于当前已达到的游标；
- 某个更新包缺少 part。

预检查停止时，不会调用导入命令，也不会删除过期包。

正常交互运行遇到缺口时，可选择只导入缺口前已验证连续的前缀，或退出后补齐更新包。
也可以显式指定策略：

```bash
# 发现缺口后直接停止。
/tmp/rsdb_import_reputation_dumps.sh --on-coverage-gap abort

# 仅导入第一个缺口之前已验证连续的包。
/tmp/rsdb_import_reputation_dumps.sh --on-coverage-gap import-prefix

# 仅预览安全前缀，不执行导入。
/tmp/rsdb_import_reputation_dumps.sh --dry-run --on-coverage-gap import-prefix
```

### 计划状态说明

| 状态 | 含义 |
| --- | --- |
| `SKIP` | 文件已由匹配的状态记录或当前已验证的 metadata 覆盖范围处理。 |
| `IMPORT` | 文件满足条件，可以调用 `reputationdb load-dump`。 |
| `CHECK` | 同日期的 week 包会先执行，day 包需等待 RSDB 返回该周包的实际 metadata 范围后再决定是否跳过。 |

`CHECK` 不代表必然跳过，也不代表必然导入；最终以紧邻周包导入后 RSDB 返回的
实际 metadata 为准。

### 资源、并发与清理保护

- 检测到已有 `reputationdb load-dump` 进程时拒绝启动。
- 使用锁文件防止多个主脚本实例并发运行。
- 在导入前检查根分区、RocksDB 文件系统和 `tmpfs` 工作目录空间。
- 每个原厂导入命令均生成独立日志文件。
- 所有计划项处理完成后，仅删除超过 15 天且已确认处理的更新包；dry-run 只展示
  可能清理的文件，不会删除。
- 在安全条件下清理工作目录中的临时 `data_reputation-*` 文件。

## 参数

```text
--dry-run
    仅输出计划和检查结果；不调用 load-dump，也不删除过期更新包。

--type all|full|week|day
    仅发现指定类型的更新包。仅当所需的前置更新链已经存在于 RSDB 时使用。

--on-coverage-gap abort|prompt|import-prefix
    指定发现增量覆盖缺口时的行为。交互式正式运行默认使用 prompt。
```

## 日志与状态文件

| 路径 | 内容 |
| --- | --- |
| `/var/log/reputationdb/import_runner/` | 每个更新包的原厂命令输出，以及可选的 `tee` 汇总日志。 |
| `/var/lib/reputationdb/import_state/imported_dumps.tsv` | 成功导入包和被 metadata 覆盖日包的文件名、大小状态记录。 |
| `/tmp/rsdb_ramwork/` | 导入过程使用的内存工作目录。 |

常用检查命令：

```bash
ps -eo pid,etime,pcpu,pmem,args | grep 'reputationdb load-dump' | grep -v grep || true
tail -f /var/log/reputationdb/import_runner/*.log
reputationdb last-dump-metadata
```

脚本要求原厂命令具有成功结果，并在单包输出中包含成功标记；同时会识别
`db is missing update to use this dump`，停止导入并给出补包建议。

如果 RocksDB 被重建、清空、回滚或从备份恢复，应先检查并通常清理
`imported_dumps.tsv`。状态记录只对创建它的同一个数据库实例有效。

## 许可证

本项目使用 [MIT License](LICENSE) 发布。你可以在许可证允许的范围内使用、修改和
再分发；使用前请自行验证与 FortiEDR 版本及运维规范的兼容性。
