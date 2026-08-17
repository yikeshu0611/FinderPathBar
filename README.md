# FinderPathBar

macOS 菜单栏 Finder 地址栏工具：贴近当前 Finder 窗口显示路径，并提供新建文件、重命名、收藏夹等快捷操作。

## 下载

请到本仓库的 [Releases](https://github.com/yikeshu0611/FinderPathBar/releases) 页面下载最新 `.dmg`。

## 安装

1. 打开 DMG，将 `FinderPathBar.app` 拖到「应用程序」
2. 首次运行若被拦截：系统设置 → 隐私与安全性 → 仍要打开
3. 授予 **辅助功能**（以及按提示的自动化）权限

## 使用提示

- 打开 Finder 后，地址栏会附着在窗口上方
- `⌘L` 编辑路径，`F2` 重命名，第 2 行按钮可新建文件夹 / 指定后缀文件
- 设置中可自定义 6 个「新建类型」按钮的后缀

## 开发

源码在 `FinderPathBar/`。打包：

```bash
cd FinderPathBar && ./build.sh
```

产物：`dist/FinderPathBar-<version>.dmg`
