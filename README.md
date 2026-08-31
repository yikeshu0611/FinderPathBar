# NewFinder

独立的 macOS 文件管理器（菜单栏常驻），界面类似 Chrome 标签页 + Finder 路径栏，可接管系统 Finder 的「打开文件夹 / 在 Finder 中显示」。

> 本仓库：**[FinderPathBar](https://github.com/yikeshu0611/FinderPathBar)** · 应用名：**NewFinder** · macOS 13+（Apple Silicon / Intel）

## 下载

在 [Releases](https://github.com/yikeshu0611/FinderPathBar/releases) 下载最新 `NewFinder-x.x.x.dmg`，拖入「应用程序」即可。

**当前版本：1.1.1**

## 主要功能

### 界面与导航
- **Chrome 式标签页**：多标签浏览、关闭、三击标签分离为新窗口
- **路径栏**：面包屑分段导航（点击 `>` 展开子目录菜单）、⌘L 编辑路径并补全
- **访问历史**：路径栏下拉，快速回到最近访问目录
- **复制路径**：路径栏按钮或 **⌘⇧C**
- **列表视图**：异步加载大文件夹、图标缓存、列排序

### 文件操作
- 打开、重命名（F2）、拷贝 / 剪切 / 粘贴、移到废纸篓
- **快捷新建**：可自定义多种类型（dir、txt、ppt、xlsx、docx、R、py 等，**大小写保留**）
- xlsx / docx / pptx 为有效 Office 空白模板
- 新建后自动选中并进入重命名

### 收藏夹
- 路径栏星标收藏当前目录
- 工具栏收藏夹分组（**按住拖动排序**），点击展开书签列表
- 支持多分组、右键重命名 / 删除

### Finder 接管（可选）
- 菜单栏图标常驻（不占 Dock）
- 拦截系统 Finder：打开文件夹、Chrome「在文件夹中显示」等转到 NewFinder
- 退出 UI 后 **Watch 后台** 仍在：点击 Dock Finder 时自动拉起
- NF 已运行时点击 Finder **只前置窗口**，不重复开 Desktop 标签
- 首次需在 **系统设置 → 隐私与安全性 → 自动化** 允许控制 Finder

### 设置
- 登录时启动、是否拦截 Finder
- **自定义新建类型**（可添加多项，最多 40 个）
- **检查更新**：从 GitHub Releases 检测并下载最新 DMG
- 书签与收藏夹顺序持久化

## 构建

```bash
./build.sh
open build/NewFinder.app
```

产物：`dist/NewFinder-1.1.1.dmg`

## 快捷键

| 快捷键 | 作用 |
|--------|------|
| ⌘L | 编辑路径 |
| ⌘⇧C | 复制路径 |
| ⌘↑ | 上层文件夹 |
| ⌘[ / ⌘] | 后退 / 前进 |
| ⌘N | 新建窗口 |
| ⌘T | 新建标签页 |
| ⇧⌘N | 新建文件夹 |
| F2 | 重命名 |
| ⌘. | 显示 / 隐藏隐藏文件 |
| ⌘W | 关闭标签或窗口 |

## 系统要求

- macOS 13.0 或更高
- Finder 拦截需要「自动化」权限

## 许可证

Copyright © 2026 ZhangJing. All rights reserved.
