# 工具脚本

## render_shot.dart.txt

把界面渲染成 PNG 供人工查看。macOS 上应用窗口可能落在另一个桌面空间导致
截屏不可靠，这是可重复的替代方案。

用法：临时改名为 `test/render_shot_test.dart` 后运行

```bash
flutter test test/render_shot_test.dart --dart-define=SHOT_DIR=/tmp/shots
```

注意：`flutter test` 使用不含中文字形的测试字体，导出图中汉字会显示为方块。
它用于核对布局、间距与配色；文字内容由 `test/app_smoke_test.dart` 断言。
不放在 test/ 目录是因为它耗时且不做断言，不适合进 CI。
