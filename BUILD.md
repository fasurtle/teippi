# teippi 编译说明

## 关于本 fork

本目录是 [fasurtle/teippi](https://github.com/fasurtle/teippi) 的 git submodule，
用于 StarCraft 1.16.1 的 MPQDraft 插件，功能是移除单位数量上限（支持 8000+ 单位）
并优化单位搜索性能。

### 相对上游的修改

| 文件 | 修改内容 | 原因 |
|------|----------|------|
| `src/unitsearch.cpp` | `ChangeUnitPosition_Finish()` 改为全数组排序 | Bug fix：原版在乱序数组上做二分搜索，8000+单位同帧大量死亡时触发 `is_sorted` 断言崩溃（全图核弹场景） |
| `src/console/types.h` | 加 `#include <cstdint>`；`Iterator` 不再继承弃用的 `std::iterator`，改用 `using` 类型别名；加 `operator--`；`std::intptr_t` → `std::ptrdiff_t` | GCC 13 编译兼容性 |
| `src/gcc13_compat.h` | 新建（强制预 include `<cstdint>/<cstdio>/<string>/<stdexcept>`） | GCC 13 不再隐式传递这些 include |
| `dlltool.def` / `mingw.def` | 新建 | MinGW 链接用的导出定义文件 |

---

## 编译方法

### 工具要求

| 工具 | 版本 | 说明 |
|------|------|------|
| MSYS2 | 任意 | 提供 MinGW32 工具链 |
| MinGW32 GCC | 13.x（MSYS2 提供） | **必须是 i686（32-bit）**，不能用 ucrt64/mingw64 |
| dlltool | 随 MinGW32 GCC 附带 | 生成正确的导出符号表 |

> **为什么不用 MSVC？**
> 项目原 `.vcxproj` 要求 VS 2015（v140 工具集）和 Windows SDK 8.1，
> 现代 VS 2022/2025 的工具集版本不匹配，MSBuild 无法自动重定向。
> MinGW GCC 编译路径更稳定。
>
> **为什么不用 waf？**
> 项目自带的 `waf` 是 1.8.5 版，依赖 Python 的 `imp` 模块，
> 该模块在 Python 3.12+ 中已被移除，waf 无法运行。

### 安装 MinGW32 GCC

```powershell
# 在 MSYS2 shell 或 PowerShell 中运行
F:\Program Files\msys64\usr\bin\pacman.exe -S mingw-w64-i686-gcc --noconfirm
```

安装后确认编译器路径（默认）：
```
F:\Program Files\msys64\mingw32\bin\g++.exe
```

### 运行编译脚本

```powershell
cd games\sc1\utils\thirdparty\teippi
.\build.ps1
```

编译产物：`build_release\teippi.qdp`

---

## 编译注意事项

### 1. 必须从 `src/` 目录内编译（不能用 `-I src`）

**不要**：
```bash
g++ -Isrc src/ai.cpp ...
```

**要**：
```bash
cd src && g++ ai.cpp ...
```

原因：MinGW32 的 GCC 内部头文件链 `limits.h → syslimits.h` 使用 `#include_next`，
该指令不区分 `<>` 和 `""`，会沿 `-iquote` 路径继续搜索，导致找到
teippi 自己的 `src/limits.h` 替代系统的 `<limits.h>`，产生循环 include 错误。
从 `src/` 目录内编译，`""` 相对路径自然定位，不需要额外的 `-I` 参数。

### 2. 需要强制 include gcc13_compat.h

GCC 13 不再通过标准库头文件隐式传递 `<string>`、`<cstdio>` 等，
直接添加 `-include gcc13_compat.h` 补全缺失 include。

### 3. 导出符号必须用 dlltool 处理

**不能**用 `--export-all-symbols`，因为 MinGW 会把 stdcall 函数
导出为 `GetMPQDraftPlugin@4`（含 `@4` 后缀），而 MPQDraft 用
`GetProcAddress("GetMPQDraftPlugin")`（不含 `@4`）查找，导致插件无法被识别。

正确做法：用 `dlltool -d dlltool.def -e exports.o` 生成导出 stub，
再与其他 .o 文件一起链接，`dlltool.def` 里明确指定无 `@4` 的导出名。

### 4. 必须静态链接 MinGW 运行库

用 `-static` 把 `libstdc++`、`libgcc`、`libwinpthread` 静态打进 DLL，
否则目标机器（运行 StarCraft 的机器）上找不到这些 MinGW 运行库，
`LoadLibrary` 失败，插件无法加载。

最终依赖只保留 Windows 内置的：`KERNEL32.dll`、`msvcrt.dll`、`USER32.dll`。

---

## 输出文件使用

将 `build_release/teippi.qdp` 复制到：
- MPQDraft 的 plugins 目录，或
- StarCraft 游戏目录（视 MPQDraft 配置而定）

插件在 MPQDraft 插件列表中显示为 **Limits v 1.0.2**。
