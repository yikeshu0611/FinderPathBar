# NewFinder

独立的 macOS 文件管理器（菜单栏常驻），界面类似 Chrome 标签页 + Finder 路径栏，可接管系统 Finder 的「打开文件夹 / 在 Finder 中显示」。

> 本仓库名称为 **FinderPathBar**，应用名为 **NewFinder**，面向 macOS 13+（Apple Silicon / Intel）。

## 下载

在 [Releases](https://github.com/yikeshu0611/FinderPathBar/releases) 页面下载最新 `NewFinder-x.x.x.dmg`，拖入「应用程序」即可。

**当前版本：1.1.0**

## 主要功能

### 界面与导航
- **Chrome 式标签页**：多标签浏览、关闭、三击标签分离为新窗口
- **路径栏**：面包屑分段导航（点击 `>` 展开子目录菜单）、⌘L 编辑路径并补全
- **访问历史**：路径栏左侧下拉，快速回到最近访问目录
- **复制路径**：路径栏按钮或 **⌘⇧C**（无选中项时复制当前目录，有选中时复制文件路径）
- **列表视图**：异步加载大文件夹、图标缓存、列排序

### 文件操作
- 打开、重命名（F2 / 菜单）、拷贝 / 剪切 / 粘贴、移到废纸篓
- **快捷新建**：工具栏 `New` 菜单（文件夹、txt、ppt、xlsx、docx、R、py 等，**大小写按设置保留**）
- xlsx / docx / pptx 使用有效 Office 空白模板，可直接用对应 App 打开
- 新建后自动选中并进入重命名

### 收藏夹
- 路径栏星标收藏当前目录
- 工具栏收藏夹按钮（可 **拖动排序**），点击展开书签列表
- 支持多收藏夹分组、右键重命名 / 删除分组

### Finder 接管（可选）
- 菜单栏图标常驻（不占 Dock）
- 开启「拦截系统 Finder」后，尽量将打开文件夹、Chrome「在文件夹中显示」等转到 NewFinder
- 退出 UI 后仍有 **Watch 后台进程**：点击 Dock Finder 时自动拉起 NewFinder
- 首次需在 **系统设置 → 隐私与安全性 → 自动化** 中允许 NewFinder 控制 Finder

### 设置
- 登录时启动、是否拦截 Finder
- **自定义新建类型**（可添加多项，最多 40 个；`dir` 表示文件夹）
- 书签与收藏夹顺序持久化

## 构建

```bash
cd NewFinder && ./build.sh
open build/NewFinder.app
```

产物：`dist/NewFinder-1.1.0.dmg`

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
- 拦截 Finder 功能需要「自动化」权限

## 许可证

Copyright © 2026 ZhangJing. All rights reserved.
