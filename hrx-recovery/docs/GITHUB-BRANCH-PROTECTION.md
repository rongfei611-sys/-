# GitHub分支保护目标与当前状态

目标仓库：`rongfei611-sys/-`  
当前活跃源码分支：`recovery/hrx-20261117`  
治理PR分支：`governance/ai-rd-team-20261119`

## 目标规则

对活跃分支 `recovery/hrx-20261117`：
- Require a pull request before merging。
- Require status check：首次CI成功后，以Actions显示的精确名称 `Isolated verification` 为准。
- Require branches to be up to date。
- Require conversation resolution。
- Dismiss stale approvals。
- 禁止force push和删除分支。
- 不允许绕过规则（包括管理员）。
- 当前个人仓库没有已验证的第二位审查人；先不设置1个必需批准数，避免单人仓库锁死。组织化后再要求至少1名非作者审批，并启用Code Owner审查。

对 `main`：
- 当前只有3字节初始README，不是HRX源码主线。
- 不将main标记为Recovery或V19.6.10正式主线。
- 在确定主线迁移策略前，不把Recovery分支自动合并到main。

## 当前执行结果

- GitHub仓库元数据显示当前账号对仓库有admin权限。
- 但当前GitHub连接读取 `/branches/main/protection` 返回HTTP 403：`Resource not accessible by integration`。
- 当前可用GitHub连接提供分支/文件/PR写入能力，但未提供Branch Protection/Repository Rulesets管理写入能力。
- 因此，规则尚未在GitHub服务器端启用；本文件和脚本不是已生效的保护规则证明。

## 管理员应用方式

使用具备该仓库Administration: write权限的GitHub管理员凭据，在仓库Settings → Branches中为 `recovery/hrx-20261117` 配置上述规则。不要把PAT提交到仓库、Issue或聊天。配置后重新读取Branch Protection API或Settings截图，确认required status check精确名称和规则状态。

自动化脚本位于 `scripts/github/apply-branch-protection.sh`。它要求环境变量 `GH_TOKEN`，仅在本机执行，不会写入令牌；执行前先确认仓库和分支名称。
