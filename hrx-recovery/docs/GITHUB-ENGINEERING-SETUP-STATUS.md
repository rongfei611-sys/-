# GitHub研发组织落地记录

日期：2026-11-19

## 已完成

- 创建独立分支 `governance/ai-rd-team-20261119`，基于 `recovery/hrx-20261117`。
- 在 `hrx-recovery/engineering/` 建立九个专业责任目录：architecture、frontend、backend、data、security、testing、devops、business、quality-delivery。
- 新增团队治理制度、RACI、研发工作流、分支保护目标和PR模板。
- 新增GitHub Actions隔离验证工作流：Node 22.12、Java 21、PostgreSQL 16；运行项目现有 `scripts/verify-isolated.sh`，该脚本执行前端测试/生产构建、后端Maven验证、隔离数据库迁移与恢复演练。
- 新增CODEOWNERS临时映射，只引用已验证的仓库Owner `@rongfei611-sys`；没有虚构GitHub Team或成员。

## 尚未生效/待验证

- Branch Protection尚未在GitHub服务器端启用：当前连接读取保护接口返回403 `Resource not accessible by integration`，连接没有管理分支保护的API权限。已提供管理员脚本 `scripts/github/apply-branch-protection.sh`，但脚本未执行，不能声称保护规则已生效。
- CI工作流文件已提交到本开发分支；只有合并PR到受支持的目标分支或在该分支手动运行后，才能取得真实Actions运行结果。文件存在不等于CI通过。
- 当前仓库为个人账号仓库，专业组是代码目录和职责分工，不是GitHub Organization Teams。若要建立GitHub Team，需要先有Organization；当前未创建组织或虚构团队。
- 本仓库的活跃源码是Recovery 0.7独立恢复工程，不是本地交付的V19.6.10源码。此次治理变更不把V19.6.10混入Recovery 0.7，也不更改main。

## 目标检查命令

- 前端/后端/数据库：`PGBIN=/usr/lib/postgresql/16/bin bash scripts/verify-isolated.sh`
- 分支保护应用：`GH_TOKEN=... scripts/github/apply-branch-protection.sh`（仅本机安全环境；不将令牌写入仓库）
- Actions运行：GitHub → Actions → HRX Recovery CI；记录run URL、结论和artifact。
