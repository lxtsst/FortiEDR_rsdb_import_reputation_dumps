<div align="center">

<h1>FortiEDR RSDB Reputation更新包导入工具</h1>

<p>面向Air-Gap与离线RSDB的安全导入工作流</p>

<p>
  <img alt="FortiEDR RSDB" src="https://img.shields.io/badge/FortiEDR-RSDB%20Reputation-E8002D?logo=fortinet&amp;logoColor=white">
  <img alt="Air-gapped workflow" src="https://img.shields.io/badge/Workflow-Air--gapped-0969DA">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-1A7F37">
</p>

<p><a href="README.en.md">English</a> · <a href="#快速开始">快速开始</a> · <a href="#日志与状态">日志与状态</a></p>

</div>

本项目提供一个带保护机制的Shell脚本，用于将FortiEDR Reputation更新包导入Air-Gap或离线部署的RSDB服务器。运维人员在联网环境下载更新包后，只需将文件原样复制到RSDB服务器的`/tmp`目录即可。

> [!CAUTION]
> 本工具是运维辅助脚本，不是Fortinet官方产品组件。请先在测试RSDB上验证，再用于生产环境。

## 功能概览

| 能力 | 作用 |
| --- | --- |
| 📦 包管理 | 自动发现完整包、周包和日包，并按安全顺序处理。 |
| 🧭 连续链保护 | 导入前检查缺包、回补包和缺失分片，避免将不连续更新交给原厂CLI。 |
| 🛡️ 覆盖与重复保护 | 结合RSDB的真实metadata与本地状态，避免无意义的重复导入。 |
| 🧾 可审计执行 | 为每次原厂导入保留独立日志，并记录已处理文件。 |
| 💡 无包提示 | `/tmp`为空时，根据数据库游标生成低重叠的下载建议。 |

## 包类型与命名规范

更新包必须直接位于`/tmp`，并保留原始文件名。脚本仅识别以下格式：

| 类型 | 文件名格式 | 用途 |
| --- | --- | --- |
| 完整包（`full`） | `reputation-full-YYYY-MM-DD-part_part_N.zip` | 新建或空RSDB的初始化基线。 |
| 周包（`week`） | `reputation-week-YYYY-MM-DD-part_part_N.zip` | 覆盖一个完整的增量时间段。 |
| 日包（`day`） | `reputation-day-YYYY-MM-DD-part_part_N.zip` | 补齐周包之间或最后不足七天的日期尾段。 |

> [!IMPORTANT]
> 新建或已清空的 RSDB：`/tmp`中必须只放一套完整、同一日期的完整包，再放后续增量包。不要把历史完整包快照与首次初始化包混放。

## 运行要求

- 使用`root`用户在RSDB服务器上执行。
- 已安装并可调用`reputationdb`命令。
- 系统具备`bash`、`find`、`sort`、`stat`、`flock`、`mount`、`findmnt`和`df`等标准Linux工具。
- 脚本会使用`/tmp/rsdb_ramwork`作为`tmpfs`工作目录；单个包需要至少“包文件大小 + 1 GiB”的可用内存空间。
- 根分区和RocksDB所在文件系统需要保留足够空间。

> [!NOTE]
> 上述`tmpfs`检查仅基于压缩包大小，无法预测原厂工具的解压临时空间和RocksDB增长量。导入大型完整包前，请按FortiEDR版本及最大包大小预留额外内存和磁盘空间。

## 快速开始

```mermaid
flowchart LR
    A["在联网环境下载更新包"] --> B["原样复制到RSDB的/tmp"]
    B --> C["执行dry-run检查计划"]
    C --> D{"计划与覆盖链正常？"}
    D -->|是| E["正式导入并保留日志"]
    D -->|否| F["按提示补齐包或仅导入安全前缀"]

    classDef source fill:#0969DA,color:#FFFFFF,stroke:#0969DA;
    classDef check fill:#8250DF,color:#FFFFFF,stroke:#8250DF;
    classDef go fill:#1A7F37,color:#FFFFFF,stroke:#1A7F37;
    classDef stop fill:#CF222E,color:#FFFFFF,stroke:#CF222E;
    class A,B source;
    class C,D check;
    class E go;
    class F stop;
```

1. 上传主脚本，并先执行只读预览：

   ```bash
   chmod 700 /tmp/rsdb_import_reputation_dumps.sh
   /tmp/rsdb_import_reputation_dumps.sh --dry-run
   ```

2. 确认计划后执行正式导入，并保留一份汇总日志：

   ```bash
   set -o pipefail
   /tmp/rsdb_import_reputation_dumps.sh 2>&1 | tee "/var/log/reputationdb/import_runner/import_$(date '+%Y%m%d_%H%M%S').log"
   ```

> [!TIP]
> 常规更新不要直接执行`reputationdb load-dump`。主脚本额外提供排序、连续链验证、覆盖判断、状态记录和日志保护。

## 导入决策规则

### 排序与分片

- 完整包始终最先处理；其后按日期处理周包和日包。
- 同一天同时存在周包和日包时，周包在前；日包会等待周包导入后返回的实际metadata再决定是否跳过。
- 同一包的多个分片按分片编号递增导入；缺失分片且未被确认处理时，脚本停止。
- 数据库没有可读的 metadata游标时，脚本只接受“唯一完整包 + 空状态文件”的首次初始化条件。

### 计划状态

| 状态 | 含义 |
| --- | --- |
| `SKIP` | 文件已由匹配的状态记录或当前已验证的metadata覆盖范围处理。 |
| `IMPORT` | 文件满足条件，可以调用`reputationdb load-dump`。 |
| `CHECK` | 同日期周包先执行；日包等待周包返回实际 metadata范围后再决定。 |

### 重复与覆盖保护

- 脚本按文件名和文件大小检查`/var/lib/reputationdb/import_state/imported_dumps.tsv`，跳过已处理包。
- 生成计划前及每个包成功导入后，都会读取`reputationdb last-dump-metadata`。
- 周包导入后，脚本以其实际`from/to`范围判断并跳过已覆盖日包；此类跳过会记录为`metadata_coverage`状态，避免下次再加载同一文件。
- 不会仅因 metadata日期更晚，就认定所有较早文件均已处理；同名但大小不同的包仍会交给原厂校验。

### 连续更新链

脚本会从当前RSDB的metadata游标开始检查增量链，并在以下情况停止：

- 下一个周包或日包之前存在日期缺口；
- 回补包早于当前已达到的游标；
- 包的某个分片缺失；
- 新建/空库缺少完整包，或混有多个完整包日期；
- metadata不可读但状态文件仍有旧记录。

预检查停止时，不会调用导入命令，也不会删除过期包。交互式运行可选择仅导入第一个缺口之前已验证连续的安全前缀：

```bash
# 发现缺口后直接停止。
/tmp/rsdb_import_reputation_dumps.sh --on-coverage-gap abort

# 仅导入第一个缺口之前的安全前缀。
/tmp/rsdb_import_reputation_dumps.sh --on-coverage-gap import-prefix

# 只预览安全前缀。
/tmp/rsdb_import_reputation_dumps.sh --dry-run --on-coverage-gap import-prefix
```

> [!NOTE]
> 脚本不会在RSDB返回真实metadata前，假设更晚日期的周包能够覆盖较早日包的缺口。因此，复杂混合包场景会保持保守停止，而不会擅自重排导入顺序。

## `/tmp`中没有更新包时

脚本不会静默退出，而是读取`reputationdb last-dump-metadata`并给出下一步建议：

| 当前状态 | 脚本提示 |
| --- | --- |
| 数据库游标已到当前UTC日期 | 提示无需下载更新包。 |
| 数据库游标落后 | 从游标起每满七天推荐一个周包；最后不足七天推荐连续日包，并给出周包不可用时的日包兜底区间。 |
| 没有可读游标 | 不猜测增量日期；提示下载唯一完整的完整包。 |
| 有不规范 ZIP 文件 | 列出文件，并提示恢复原厂文件名。 |

下载建议基于包日期规则，并不查询Fortinet下载站。请确认对应日期包已发布后再下载；如果建议的周包不可用，请使用脚本列出的连续日包兜底区间，不能跳过日期。

## 参数

```text
--dry-run
    只输出计划与检查结果；不调用load-dump，也不删除过期更新包。

--type all|full|week|day
    只发现指定类型的包。仅当所需前置更新链已存在于RSDB时使用。

--on-coverage-gap abort|prompt|import-prefix
    指定发现增量缺口时的行为。交互式正式运行默认使用prompt。
```

## 日志与状态

| 路径 | 内容 |
| --- | --- |
| `/var/log/reputationdb/import_runner/` | 每个包的原厂命令输出，以及可选的`tee`汇总日志。 |
| `/var/lib/reputationdb/import_state/imported_dumps.tsv` | 已成功导入包和 metadata覆盖日包的文件名、大小与来源记录。 |
| `/tmp/rsdb_ramwork/` | 导入期间使用的内存工作目录。 |

常用检查命令：

```bash
ps -eo pid,etime,pcpu,pmem,args | grep 'reputationdb load-dump' | grep -v grep || true
tail -f /var/log/reputationdb/import_runner/*.log
reputationdb last-dump-metadata
```

原厂命令必须在单包日志中返回成功标记。脚本也会识别`db is missing update to use this dump`，停止导入并输出补包建议。

> [!WARNING]
> 如果 RocksDB 被重建、清空、回滚或从备份恢复，请先检查并通常清理`imported_dumps.tsv`。该状态文件只对创建它的同一个数据库实例有效。

## 许可证

本项目以[MIT License](LICENSE)发布。你可以在许可证允许的范围内使用、修改和再分发；使用前请确认与自身FortiEDR版本及运维规范兼容。
