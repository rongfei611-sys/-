# HRX-OS研发团队RACI矩阵

角色：CA=首席架构师/GPT-6；SA=系统架构；FE=前端；BE=后端；DE=数据工程；SE=安全工程；QA=测试工程；DO=DevOps；BX=业务专家；QD=统一质量验收交付中心。

| 工作事项 | CA | SA | FE | BE | DE | SE | QA | DO | BX | QD |
|---|---|---|---|---|---|---|---|---|---|---|
| 需求范围与优先级 | A | R | I | I | I | C | C | I | R | C |
| 领域模型/API契约 | A | R | C | R | C | C | C | I | C | I |
| 前端交互与页面 | A | C | R | C | I | C | C | I | C | I |
| 后端业务规则/API | A | C | C | R | C | C | C | I | C | I |
| 数据模型/Flyway/RLS | A | C | I | C | R | C | C | I | C | I |
| OIDC/RBAC/SoD | A | C | C | R | C | R | C | C | C | I |
| 测试策略与自动化 | A | C | C | C | C | C | R | C | C | C |
| CI/CD与运行环境 | A | I | C | C | C | C | C | R | I | C |
| 业务场景验收 | C | C | C | C | I | C | R | I | A | C |
| 发布门禁与交付 | A | C | I | I | C | C | R | R | C | R |

说明：
- A=最终负责，R=执行负责，C=协商，I=知会。
- GPT-6承担架构统筹，不代替企业业务Owner、身份管理员或法定审批人。
- 当前GitHub为个人仓库，实际可执行的GitHub账号Owner只有已验证的 `@rongfei611-sys`；其他专业组为项目责任角色，待企业人员/组织团队建立后再映射。
- 安全、数据库、审批和质量放行不得由同一人/同一AI角色越权代办；实际生产SoD以企业授权矩阵为准。
