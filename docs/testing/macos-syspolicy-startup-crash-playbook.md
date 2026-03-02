# macOS 测试宿主“启动即死”排障手册（syspolicyd/Gatekeeper）

## 适用场景

本手册用于识别并处理以下问题：
- `xcodebuild test` 发起后，测试宿主进程几乎立刻退出。
- 测试还没进入用例执行阶段就报错结束。
- 同一套测试在代码无明显变化时突然大面积“全挂”。

## 典型症状（强特征）

当出现以下任意组合时，应优先判断为系统策略问题，而非业务逻辑问题：

1. `xcodebuild`/`.xcresult` 中出现：
- `Early unexpected exit, operation never finished bootstrapping`
- `Test crashed with signal kill before establishing connection`
- `IDELaunchServicesLauncher ... childPID > 0`

2. 系统统一日志出现（关键）：
- `OS_REASON_EXEC | Gatekeeper policy (Malware) blocked execution`
- 目标通常是测试宿主 App（如 `com.developerchen.voiddisplay`）

## 快速确认命令

```bash
/usr/bin/log show --style compact --last 30m \
  --predicate 'eventMessage CONTAINS[c] "Gatekeeper policy (Malware) blocked execution" OR eventMessage CONTAINS[c] "OS_REASON_EXEC"'
```

如果输出中包含 `Gatekeeper policy (Malware) blocked execution`，基本可确认是系统策略拦截导致的“启动即死”。

## 标准处置（第一优先）

检测到上述特征后，应立即提示用户执行：

```bash
sudo killall syspolicyd
```

然后重新执行测试命令（建议先跑一个小用例验证宿主可启动，再跑全量）。

## 建议的排障顺序

1. 先看 `xcodebuild` 报错是否属于“未完成 bootstrapping”类。
2. 立即查统一日志确认是否有 `Gatekeeper policy (Malware) blocked execution`。
3. 命中后，第一时间提示用户执行 `sudo killall syspolicyd`。
4. 重新运行最小测试目标确认宿主可启动。
5. 宿主恢复后再看真实失败用例（避免把系统问题误判为代码回归）。

## 与代码问题的区分

- 系统策略问题：进程在测试握手前被杀，通常几乎所有测试无法正常开始。
- 代码问题：宿主可启动并进入用例，失败会集中在少量具体断言/超时上。

## 团队约定（避免再次踩坑）

当代理/开发者看到“启动即死 + OS_REASON_EXEC/Gatekeeper”特征时：

1. 不要先大改业务代码。
2. 先明确告知用户这是系统策略拦截症状。
3. 立即建议执行 `sudo killall syspolicyd` 再复测。
4. 仅在宿主恢复后，再进入代码层面的失败分析。

## 测试启动策略（避免“0 tests executed”假绿）

1. 本项目本地默认不要附带 `-testPlan VoidDisplay`，优先使用：

```bash
xcodebuild test \
  -project VoidDisplay.xcodeproj \
  -scheme VoidDisplay \
  -destination 'platform=macOS' \
  -skip-testing:VoidDisplayUITests
```

2. 每次跑完必须校验 `.xcresult` 里的 `totalTestCount`，确保真实执行了测试：

```bash
xcrun xcresulttool get test-results summary --path <path-to-xcresult>
```

3. 若 `totalTestCount` 为 `0`，该次结果视为无效，必须调整命令后重跑。
